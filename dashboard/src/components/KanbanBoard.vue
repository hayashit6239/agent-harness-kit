<script setup lang="ts">
/**
 * カンバンボード: issue フェーズ / PR フェーズの 2 レーン。
 * 列 = 作者指定の並び (deriveKanban の列順定数 ISSUE_COLUMN_ORDER / PR_COLUMN_ORDER が正)。
 * 空の flow 列も細く畳んで表示し、流れと「今どこが熱いか」を密度で見せる。
 * グルーピング・祝い列 (celebrating)・エスカレーション列 (escalating・issue #12)・
 * 列のロール (statusOwner) は derive 側の純関数 (vitest 対象) に委ね、
 * ここは表示と動き (列移動の演出) だけを担う。
 */
import { computed, ref, watch, TransitionGroup } from 'vue';
import type { KanbanCard, KanbanColumn, Phase, StepView, LedgerWarning } from '../lib/derive';
import { deriveKanban, statusOwner } from '../lib/derive';

const props = defineProps<{
  steps: StepView[];
  warnings: LedgerWarning[];
  repoSlug: string | null;
}>();

const kanban = computed(() => deriveKanban(props.steps));

// Issue 表記は 'Issue' (大文字始まり) に統一し、'PR' の略語表記と対称にする (issue #24 項目 1)。
// columnLabel() は台帳 schema の生 status 文字列をそのまま表示する別物のため対象外 (issue #24 決定)。
const LANE_TITLES: Record<Phase, string> = {
  issue: 'Issue フェーズ',
  pr: 'PR フェーズ',
};

/** 列ヘッダの表示名 (null = 未着手列 / unknown 列は固定名) */
function columnLabel(col: KanbanColumn): string {
  if (col.kind === 'unknown') return 'unknown';
  return col.status ?? '未着手';
}

/** 警告文中で phase を指す表記 (LANE_TITLES と大文字小文字を揃える: Issue / PR。issue #24 項目 1) */
function warningPhaseLabel(phase: Phase | null): string {
  if (phase === 'issue') return 'Issue';
  if (phase === 'pr') return 'PR';
  return '';
}

/** 警告バナー 1 件分の文言 (kind ごとに原因を言い分ける)。網羅は switch の返り値型で担保 */
function warningText(w: LedgerWarning): string {
  const phase = warningPhaseLabel(w.phase);
  switch (w.kind) {
    case 'duplicate-id':
      return `id 「${w.stepId}」が複数の step で重複しています (2 枚目以降は表示キーを別に振っています)`;
    case 'missing-phase':
      return `${w.stepId} ${phase}: オブジェクト欠落 (unknown 列に置いています)`;
    case 'missing-status':
      return `${w.stepId} ${phase}: status キー欠落 (unknown 列に置いています。未着手 = 明示 null と区別)`;
    case 'unknown-status':
      return `${w.stepId} ${phase}: 未知の status 「${w.status}」 (unknown 列に置いています)`;
  }
}

/**
 * unknown 列は空なら出さない (流れの列ではなく警告列のため)。flow / terminal は空でも表示。
 * PR レーンの implementation-ready 列は表示側フィルタで常に隠す (issue #24 項目 2・決定事項:
 * derive.ts の PR_COLUMN_ORDER / derive.test.ts の enum 一致テストは変更しない。表示層のみで隠す。
 * 該当 step は fail-soft で単純に非表示 (現状 0 件・実害なしと issue 側で確認済み))。
 */
function visibleColumns(phase: Phase, columns: KanbanColumn[]): KanbanColumn[] {
  return columns.filter((c) => {
    if (phase === 'pr' && c.status === 'implementation-ready') return false;
    return c.kind !== 'unknown' || c.cards.length > 0;
  });
}

/**
 * 列の色 = その status のボールを持つロール (statusOwner は信号表から導出・テスト済み)。
 * キャラカード側と同じ色言語で「どの列 = 誰の仕事か」を読めるようにする。
 */
function roleClass(phase: Phase, col: KanbanColumn): string {
  if (col.kind === 'unknown') return 'role-alert';
  const owner = statusOwner(phase, col.status);
  return owner === null ? 'role-none' : `role-${owner}`;
}

function cardUrl(phase: Phase, card: KanbanCard): string {
  const path = phase === 'issue' ? 'issues' : 'pull';
  return `https://github.com/${props.repoSlug}/${path}/${card.number}`;
}

/* --- 動き: ポーリングで status が変わったカードの移動先列を一拍ハイライト --- */

/** 列の同定キー (レーン内で status は一意。unknown 列は kind で区別) */
function columnKey(phase: Phase, col: KanbanColumn): string {
  return `${phase}:${col.kind}:${col.status ?? ''}`;
}

const flashing = ref<ReadonlySet<string>>(new Set());
const flashTimers = new Map<string, number>();

function isFlashing(phase: Phase, col: KanbanColumn): boolean {
  return flashing.value.has(columnKey(phase, col));
}

// 前回の「カード → 列」対応と比較し、列が変わったカードの移動先列を flash する。
// 初回 (prev = null) は比較しない (初回ロードは列の時差表示だけで十分)。
let prevPlacement: Map<string, string> | null = null;
watch(
  kanban,
  (view) => {
    const next = new Map<string, string>();
    const arrivals = new Set<string>();
    for (const lane of [view.issue, view.pr]) {
      for (const col of lane.columns) {
        const key = columnKey(lane.phase, col);
        // card.key で同定 (stepId だと重複 id 台帳で対応表が上書きされ移動検出が欠ける)
        for (const card of col.cards) next.set(`${lane.phase}:${card.key}`, key);
      }
    }
    if (prevPlacement !== null) {
      for (const [cardKey, colKey] of next) {
        const before = prevPlacement.get(cardKey);
        if (before !== undefined && before !== colKey) arrivals.add(colKey);
      }
    }
    prevPlacement = next;
    if (arrivals.size === 0) return;
    flashing.value = new Set([...flashing.value, ...arrivals]);
    for (const colKey of arrivals) {
      const old = flashTimers.get(colKey);
      if (old !== undefined) window.clearTimeout(old);
      flashTimers.set(
        colKey,
        window.setTimeout(() => {
          const rest = new Set(flashing.value);
          rest.delete(colKey);
          flashing.value = rest;
          flashTimers.delete(colKey);
        }, 1400),
      );
    }
  },
  { immediate: true },
);
</script>

<template>
  <section class="kanban">
    <div v-if="warnings.length" class="kanban-warning" role="alert">
      ⚠ 台帳に注意が必要な step があります:
      <!-- :key は index — 重複 id 台帳では stepId+phase+kind の組でも衝突しうる。
           warnings は毎ポーリングで全再計算される静的リストなので index で十分 -->
      <span v-for="(w, i) in warnings" :key="i" class="warning-item">{{ warningText(w) }}</span>
    </div>

    <p v-if="steps.length === 0" class="empty">台帳に step がありません</p>

    <div
      v-for="(lane, laneIndex) in [kanban.issue, kanban.pr]"
      :key="lane.phase"
      class="lane"
      :style="{ '--lane-i': laneIndex }"
    >
      <header class="lane-head">
        <span class="lane-tag">{{ laneIndex === 0 ? 'LANE 01' : 'LANE 02' }}</span>
        <h2 class="lane-title">{{ LANE_TITLES[lane.phase] }}</h2>
      </header>
      <div class="lane-scroll">
        <div class="columns">
          <div
            v-for="(col, i) in visibleColumns(lane.phase, lane.columns)"
            :key="columnKey(lane.phase, col)"
            class="column"
            :class="[
              `kind-${col.kind}`,
              roleClass(lane.phase, col),
              { celebrating: col.celebrating, escalating: col.escalating, 'is-empty': col.cards.length === 0 },
            ]"
            :style="{ '--col-i': i }"
          >
            <!-- 移動先列の一拍ハイライト (v-if の出し入れで 1 回だけ光る) -->
            <div v-if="isFlashing(lane.phase, col)" class="flash-overlay" aria-hidden="true"></div>
            <header class="column-head">
              <span class="column-name" :title="columnLabel(col)">
                <span v-if="col.kind === 'unknown'" title="schema 語彙にない status">⚠</span>
                <span v-if="col.escalating">🚨</span>
                <span v-if="col.celebrating">🎉</span>
                {{ columnLabel(col) }}
              </span>
              <span class="count" :class="{ 'count-zero': col.cards.length === 0 }">{{ col.cards.length }}</span>
              <span v-if="col.kind === 'terminal'" class="terminal-mark">終端</span>
            </header>
            <TransitionGroup tag="div" name="card" class="cards">
              <!-- :key は card.key (重複 id 台帳でも一意な導出キー)。stepId 直だと衝突する -->
              <article v-for="card in col.cards" :key="card.key" class="card">
                <div class="card-head">
                  <span class="step-id">{{ card.stepId }}</span>
                  <span v-if="card.kind" class="kind-badge">{{ card.kind }}</span>
                  <a
                    v-if="card.number !== null && repoSlug !== null"
                    class="number"
                    :href="cardUrl(lane.phase, card)"
                    target="_blank"
                    rel="noreferrer"
                  >#{{ card.number }}</a>
                  <span
                    v-else-if="card.number !== null"
                    class="number nolink"
                    title="repo slug を導出できずリンク無効"
                  >#{{ card.number }}</span>
                </div>
                <p v-if="card.title" class="card-title" :title="card.title">{{ card.title }}</p>
                <p v-if="card.githubState" class="gh-state" :data-state="card.githubState">
                  <span class="gh-dot" aria-hidden="true"></span>{{ card.githubState }}
                </p>
                <p v-if="col.kind === 'unknown'" class="raw-status">
                  status: 「{{ card.status ?? '(オブジェクト欠落)' }}」
                </p>
              </article>
            </TransitionGroup>
          </div>
        </div>
      </div>
    </div>
  </section>
</template>

<style scoped>
.kanban-warning {
  margin: 0 0 14px;
  padding: 9px 14px;
  background: var(--alert-dim);
  border: 1px solid rgba(255, 123, 114, 0.4);
  border-left: 3px solid var(--alert);
  border-radius: 8px;
  color: #ffc9c4;
  font-size: 12px;
}

.warning-item {
  margin-left: 10px;
  font-weight: 600;
}

.empty {
  margin: 4px 2px;
  color: var(--text-lo);
  text-align: center;
}

/* レーン = 盆 (tray)。ページより一段沈めて、カードの浮きと対比させる */
.lane {
  background: var(--tray);
  border: 1px solid var(--line);
  border-radius: 14px;
  padding: 12px 14px 10px;
  box-shadow:
    inset 0 2px 12px rgba(0, 0, 0, 0.45),
    inset 0 -1px 0 rgba(255, 255, 255, 0.03);
}

.lane + .lane {
  margin-top: 16px;
}

.lane-head {
  display: flex;
  align-items: baseline;
  gap: 12px;
  margin: 0 2px 10px;
}

.lane-tag {
  font-family: var(--font-mono);
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.22em;
  color: var(--text-lo);
}

.lane-title {
  margin: 0;
  font-size: 15px;
  font-weight: 700;
  letter-spacing: 0.03em;
  color: var(--text-hi);
}

/* レーンは横スクロール可 (列数が画面幅を超える場合) */
.lane-scroll {
  overflow-x: auto;
  padding-bottom: 6px;
}

.columns {
  display: flex;
  gap: 8px;
  align-items: stretch;
  min-width: max-content;
}

/* ---- 列: ロールの色言語 (--role) を列ヘッダに乗せる ---- */

.column {
  --role: var(--text-lo);
  --role-dim: rgba(125, 138, 163, 0.12);
  /*
   * 列の高さは画面いっぱいに追従する (issue #24 項目 3・決定事項):
   *   画面いっぱい = ビューポート高 − (ヘッダ + レーンタグ + 上下 padding)
   * KanbanBoard.vue はこのコンポーネント単体で完結させる方針のため、App.vue 側の
   * 高さ 100% 伝播 (flexbox 案) ではなく calc(100vh - Npx) 案を採る (issue 側で両案は
   * 同格の選択肢として許容されている)。236px は App のヘッダ・レーン頭・余白の概算値で
   * 厳密な実測値ではない (手動確認で微調整可能な 1 箇所にまとめてある)。
   * 下限は旧固定値 264px を min-height として維持し、上限は設けない。
   * リサイズは 100vh の再評価だけで追従するため JS 再計算は不要。
   */
  --column-fill-height: calc(100vh - 236px);
  position: relative;
  flex: 0 0 158px;
  width: 158px;
  display: flex;
  flex-direction: column;
  background: var(--column);
  border: 1px solid var(--line);
  border-top: 2px solid var(--role);
  border-radius: 10px;
  /* カードが溢れたら列内の縦スクロールで見る (元の設計方針は変わらず、高さの基準だけ変更) */
  height: var(--column-fill-height);
  min-height: 264px;
  transition: flex-basis 0.35s ease, width 0.35s ease;
  /* 初回ロードの時差表示 (1 回だけ。以後は要素が保持されるので再発火しない) */
  animation: col-intro 0.5s cubic-bezier(0.22, 1, 0.36, 1) both;
  animation-delay: calc((var(--lane-i, 0) * 5 + var(--col-i, 0)) * 45ms);
}

@keyframes col-intro {
  from {
    opacity: 0;
    transform: translateY(10px);
  }
  to {
    opacity: 1;
    transform: none;
  }
}

.column.role-developer {
  --role: var(--dev);
  --role-dim: var(--dev-dim);
}

.column.role-reviewer {
  --role: var(--rev);
  --role-dim: var(--rev-dim);
}

.column.role-alert {
  --role: var(--alert);
  --role-dim: var(--alert-dim);
}

/* 祝いはロール色に優先して金 (規則 3 の演出) */
.column.celebrating {
  --role: var(--gold);
  --role-dim: var(--gold-dim);
  background: linear-gradient(180deg, rgba(242, 201, 76, 0.1), var(--column) 55%);
  box-shadow: 0 0 14px rgba(242, 201, 76, 0.22);
}

/* エスカレーションはロール色に優先して警告色 (規則 4 の演出。celebrating より後に定義し
   両立時は警告側を前面に — 人間判断待ちの方が緊急度が高い・issue #12) */
.column.escalating {
  --role: var(--alert);
  --role-dim: var(--alert-dim);
  background: linear-gradient(180deg, rgba(255, 123, 114, 0.12), var(--column) 55%);
  box-shadow: 0 0 14px rgba(255, 123, 114, 0.26);
}

/*
 * 空列は細いレールに畳む (ラベル縦書き) — 密度で「今どこが熱いか」を見せる。
 * 畳むのは幅のみ (issue #24 項目 3・決定事項): 高さは .column の height を上書きしないため
 * 画面いっぱいのまま伸びる。幅の畳みと高さの伸長は独立した挙動とする。
 */
.column.is-empty {
  flex-basis: 46px;
  width: 46px;
}

.column.is-empty .column-head {
  flex-direction: column;
  align-items: center;
  gap: 8px;
  border-bottom: none;
  height: 100%;
  padding: 10px 4px;
}

.column.is-empty .column-name {
  writing-mode: vertical-rl;
  overflow-wrap: normal;
  white-space: nowrap;
  text-overflow: ellipsis;
  flex: 1;
  min-height: 0;
  overflow: hidden;
}

.column.is-empty .count {
  margin-left: 0;
}

.column.is-empty .terminal-mark,
.column.is-empty .cards {
  display: none;
}

.column-head {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 4px;
  padding: 7px 9px;
  border-bottom: 1px solid var(--line);
}

.column-name {
  font-size: 12px;
  font-weight: 700;
  color: var(--role);
  line-height: 1.3;
  overflow-wrap: anywhere;
}

.count {
  margin-left: auto;
  padding: 0 7px;
  border-radius: 10px;
  background: var(--role-dim);
  color: var(--role);
  font-family: var(--font-mono);
  font-variant-numeric: tabular-nums;
  font-size: 12px;
  font-weight: 600;
}

.count-zero {
  background: transparent;
  color: var(--text-lo);
  font-weight: 400;
}

.terminal-mark {
  flex-basis: 100%;
  font-size: 12px;
  color: var(--text-lo);
}

.cards {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: 7px;
  padding: 7px;
  flex: 1;
  /* 固定高の列から溢れたカードは縦スクロール */
  min-height: 0;
  overflow-y: auto;
}

/* ---- カード: 盆の上に浮く実在感 ---- */

.card {
  background: var(--card);
  border: 1px solid rgba(148, 178, 255, 0.14);
  border-radius: 8px;
  padding: 7px 9px;
  box-shadow:
    0 3px 8px rgba(0, 0, 0, 0.45),
    inset 0 1px 0 rgba(255, 255, 255, 0.05);
}

/* status 変化による列間移動: 入りはすっと降りて、出は素早く消える */
.card-enter-active {
  transition: opacity 0.4s cubic-bezier(0.22, 1, 0.36, 1), transform 0.4s cubic-bezier(0.22, 1, 0.36, 1);
}

.card-enter-from {
  opacity: 0;
  transform: translateY(-10px) scale(0.97);
}

.card-leave-active {
  transition: opacity 0.22s ease, transform 0.22s ease;
  position: absolute;
  left: 7px;
  right: 7px;
}

.card-leave-to {
  opacity: 0;
  transform: scale(0.94);
}

.card-move {
  transition: transform 0.4s ease;
}

/* 移動先列の一拍ハイライト (flash-overlay の v-if 出し入れで 1 回再生) */
.flash-overlay {
  position: absolute;
  inset: -1px;
  z-index: 1;
  border: 2px solid var(--role);
  border-radius: 10px;
  background: var(--role-dim);
  pointer-events: none;
  animation: col-flash 1.3s ease-out both;
}

@keyframes col-flash {
  from {
    opacity: 1;
  }
  to {
    opacity: 0;
  }
}

.card-head {
  display: flex;
  align-items: center;
  gap: 5px;
  flex-wrap: wrap;
}

.step-id {
  font-family: var(--font-mono);
  font-variant-numeric: tabular-nums;
  font-size: 12px;
  font-weight: 600;
  color: var(--text-hi);
}

.kind-badge {
  padding: 0 6px;
  border-radius: 8px;
  background: rgba(124, 152, 205, 0.14);
  color: var(--text);
  font-size: 12px;
}

.number {
  margin-left: auto;
  font-family: var(--font-mono);
  font-variant-numeric: tabular-nums;
  font-size: 12px;
}

.nolink {
  color: var(--text-lo);
}

/* title は 2 行で省略 (全文は title 属性で参照可) */
.card-title {
  margin: 4px 0 0;
  font-size: 12px;
  line-height: 1.45;
  color: var(--text);
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

/* GitHub の実態 (open / closed / merged) の小さな計器表示 */
.gh-state {
  margin: 5px 0 0;
  display: flex;
  align-items: center;
  gap: 5px;
  font-family: var(--font-mono);
  font-size: 12px;
  color: var(--text-lo);
}

.gh-dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--text-lo);
  flex: none;
}

.gh-state[data-state='open'] .gh-dot {
  background: var(--ok);
}

.gh-state[data-state='merged'] .gh-dot {
  background: var(--merged);
}

.gh-state[data-state='closed'] .gh-dot {
  background: var(--alert);
}

.raw-status {
  margin: 4px 0 0;
  font-size: 12px;
  color: var(--alert);
  overflow-wrap: anywhere;
}

/* 終端列 (closed issue / merged pr) は無彩色で控えめに */
.column.kind-terminal {
  border-style: dashed;
  border-top-style: solid;
  opacity: 0.7;
}

/* 未知 status の警告列 (レーン右端) */
.column.kind-unknown {
  background: rgba(255, 123, 114, 0.06);
}
</style>
