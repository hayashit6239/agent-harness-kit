<script setup lang="ts">
import { computed } from 'vue';
import type { CharacterId, CharacterState, CharacterView } from '../lib/derive';
// ロールキャラのピクセルアート (issue #97 part3)。均一スレート bg を端 flood-fill color-key で透過済み
// (dashboard/scripts/make-transparent.py)。Vite が import を URL 文字列へ解決する (*.png は vite/client 型)。
import implementerImg from '../assets/chactor1.png';
import responderImg from '../assets/chactor2.png';
import prReviewerImg from '../assets/chactor3.png';
import issueReviewerImg from '../assets/chactor4.png';
// オフィス俯瞰の背景 1 枚絵 (issue #104)。author 提供のピクセルアート (488×339) をレイヤ0 背景に敷く。
// 焼き込みキャラ矩形は dashboard/scripts/clean-office-bg.py で木床パターンへ塗り潰し済み
// (ライブキャラとの二重表示を防ぐ・DoD③)。
import officeBgImg from '../assets/office.png';

/**
 * ピクセルオフィスステージ (issue #25 レイヤ4・DESIGN.md 第6章)。
 *
 * 方式 = 「1 枚絵の背景 + DOM オーバーレイ」(6.1):
 *   レイヤ0 背景 / レイヤ1 キャラスプライト / レイヤ2 名前チップ (キャラ下端追従) /
 *   レイヤ3 状態吹き出し (キャラ上端追従) / z-order は y 座標昇順 (下ほど手前)。
 * 座標系 (6.2) = 論理座標 (STAGE = 背景画像実寸 488×339) を % に射影し、外側コンテナに追従してスケール。
 * 素材 (6.3) = レイヤ0 背景に author 提供のオフィス俯瞰 1 枚絵 office.png を敷き (issue #104)、
 *   キャラは透過 PNG (<img image-rendering: pixelated>) を重ねる。座標系・チップ・吹き出しの
 *   ロジックは素材と独立 (背景差し替えでこのファイルの座標ロジックは不変)。
 *
 * 駆動源は既存の BoardState (characters / celebrate / escalate) のみ。
 * セッション直読みはしない (issue #25 決定事項 A案 — 台帳中心思想)。
 */

const props = defineProps<{
  characters: Record<CharacterId, CharacterView>;
  celebrate: boolean;
  /** 規則 4 (issue #12): need for human review の step が 1 つでもあれば true */
  escalate: boolean;
}>();

/** 論理座標系 (DESIGN.md 6.2)。背景 office.png の実寸 (488×339) に一致させ、
 *  % 射影した SPOTS が画像内のゾーンへ正確に乗るようにする (issue #104)。 */
const STAGE = { w: 488, h: 339 } as const;

interface Spot {
  x: number;
  y: number;
}

/**
 * オフィスの席割り (office_config 相当の宣言 — DESIGN.md 6.2)。issue #97 で 4 ロールへ拡張。
 * 座標は背景 office.png の実寸 488×339 系で実測 (issue #104)。アンカーは足元 (.sprite bottom)。
 * state → スポットの対応 (「BoardState 由来の配置」の実体):
 *   working = 自席 (実装者/対応者 = 左の制作デスク 2 台 / PR・Issue レビュー者 = 右のレビュー室テーブル)
 *   waiting = 自席の手前 (待ち仕事を取りに行く。画像に「受信箱前」ゾーンが無いため自席近傍へ寄せた)
 *   idle    = 中央下の空き床 (画像に「休憩ラウンジ」が無いため、焼き込み除去で空いた下部床へ分散)
 * dev 系 (実装者/対応者) は左、reviewer 系は右に固め、各 state 内で 4 体が重ならないよう分散
 * (最終的な微調整は手動目視スコープ)。
 */
const SPOTS: Record<CharacterId, Record<CharacterState, Spot>> = {
  implementer: {
    working: { x: 68, y: 170 },
    waiting: { x: 100, y: 205 },
    idle: { x: 110, y: 262 },
  },
  responder: {
    working: { x: 176, y: 170 },
    waiting: { x: 185, y: 210 },
    idle: { x: 205, y: 280 },
  },
  'pr-reviewer': {
    working: { x: 348, y: 152 },
    waiting: { x: 350, y: 196 },
    idle: { x: 352, y: 262 },
  },
  'issue-reviewer': {
    working: { x: 432, y: 152 },
    waiting: { x: 432, y: 200 },
    idle: { x: 440, y: 280 },
  },
};

/** ロールの表示名 + ピクセルアート + working 吹き出しの一言 (identity は derive の CharacterId・issue #97) */
const CHARACTER_META: Record<CharacterId, { label: string; img: string; workingNote: string }> = {
  implementer: { label: '実装者', img: implementerImg, workingNote: 'カタカタ実装中…' },
  responder: { label: '対応者', img: responderImg, workingNote: '指摘に対応中…' },
  'pr-reviewer': { label: 'PR レビュー者', img: prReviewerImg, workingNote: 'PR をじっくりレビュー中…' },
  'issue-reviewer': { label: 'Issue レビュー者', img: issueReviewerImg, workingNote: 'Issue をじっくりレビュー中…' },
};

/** ステージ・舞台下リストで固定の描画順 (z-index は下記 actors で y 座標により別途決まる) */
const CHARACTER_ORDER = ['implementer', 'responder', 'pr-reviewer', 'issue-reviewer'] as const;

const STATE_LABEL: Record<CharacterState, string> = {
  working: '作業中',
  waiting: '待ち仕事あり',
  idle: '待機中',
};

const STATE_ICON: Record<CharacterState, string> = {
  working: '💭',
  waiting: '📬',
  idle: '💤',
};

const actors = computed(() =>
  CHARACTER_ORDER.map((id) => {
    const view = props.characters[id];
    const spot = SPOTS[id][view.state];
    return {
      id,
      view,
      meta: CHARACTER_META[id],
      spot,
      // 論理座標 → % 射影 (コンテナ幅に追従)。z-index は y 昇順 = 下にいるキャラほど手前 (6.1)。
      // チップ・吹き出しは actor 内の子要素なので親の z を継承する
      style: {
        left: `${((spot.x / STAGE.w) * 100).toFixed(2)}%`,
        top: `${((spot.y / STAGE.h) * 100).toFixed(2)}%`,
        zIndex: 100 + Math.round(spot.y),
      },
    };
  }),
);

/** 祝い紙吹雪 (index から決定論的に散らす)。色はデザイントークン (style.css) の参照 — hex の二重定義を避ける */
function pieceStyle(i: number): Record<string, string> {
  const colors = ['var(--gold)', 'var(--dev)', 'var(--rev)', 'var(--ok)', 'var(--merged)', 'var(--alert)', 'var(--text-hi)'];
  return {
    left: `${(i * 37) % 100}%`,
    backgroundColor: colors[i % colors.length]!,
    animationDelay: `${(i % 8) * 0.35}s`,
    animationDuration: `${2.4 + (i % 5) * 0.3}s`,
  };
}
</script>

<template>
  <section class="stage" :class="{ 'is-celebrating': celebrate, 'is-escalating': escalate }">
    <p class="stage-tag">OFFICE</p>

    <!-- モニター風ベゼル額装 (DESIGN.md 5.6) の中に論理座標系のシーンを敷く -->
    <div class="bezel">
      <div class="scene" role="img" aria-label="AI オフィスの俯瞰図。実装者・対応者・PR レビュー者・Issue レビュー者の稼働状況をキャラクターで表示">
        <!-- レイヤ0: 背景 (office.png 1 枚絵。焼き込みキャラは塗り潰し済み — issue #104 / DESIGN.md 6.1/6.3) -->
        <img class="office-bg" :src="officeBgImg" alt="" aria-hidden="true" />

        <!-- 祝い: 紙吹雪 (celebrate は舞台全体の演出フラグ — 規則 3) -->
        <div v-if="celebrate" class="confetti" aria-hidden="true">
          <span v-for="i in 28" :key="i" class="piece" :style="pieceStyle(i)"></span>
        </div>

        <!-- エスカレーション: 承認待ちアラート吹き出し様式 (DESIGN.md 5.8・規則 4) -->
        <div v-if="escalate" class="alert-bubble" role="alert">
          <p class="alert-title">🚨 need for human review — 確認まち!</p>
          <p class="alert-body">停止条件に到達しました。人間の判断を待っています</p>
        </div>
        <div v-if="celebrate" class="celebrate-chip">🎉 ready for merge — merge は人間の出番です!</div>

        <!-- レイヤ1〜3: キャラ + 名前チップ + 状態吹き出し (配置は BoardState の state 由来) -->
        <div
          v-for="a in actors"
          :key="a.id"
          class="actor"
          :class="`state-${a.view.state}`"
          :style="a.style"
          :data-character="a.id"
          :data-x="a.spot.x"
          :data-y="a.spot.y"
        >
          <!-- レイヤ3: 状態吹き出し (キャラ上端に追従・下向きしっぽ付き) -->
          <div class="bubble">
            <p class="bubble-name">{{ a.meta.label }}</p>
            <p class="bubble-state">
              {{ STATE_ICON[a.view.state] }} {{ STATE_LABEL[a.view.state]
              }}<template v-if="a.view.state === 'working'"> — {{ a.meta.workingNote }}</template>
            </p>
            <!-- 吹き出しは 2 件まで要約 (全量は舞台下の割当リストが正) -->
            <p v-for="(task, i) in a.view.tasks.slice(0, 2)" :key="`${i}:${task}`" class="bubble-task">{{ task }}</p>
            <p v-if="a.view.tasks.length > 2" class="bubble-task bubble-more">…他 {{ a.view.tasks.length - 2 }} 件</p>
          </div>
          <!-- レイヤ1: スプライト (透過ピクセルアート PNG・issue #97 part3。image-rendering:pixelated + 共通表示高)。
               working 時は .state-working .face の work-bob (上下ゆれ) で動く = option B (手足フレームは follow-up) -->
          <div class="sprite">
            <img class="face" :src="a.meta.img" :alt="a.meta.label" />
            <span class="shadow" aria-hidden="true"></span>
          </div>
          <!-- レイヤ2: 名前チップ (キャラ足元に追従 — 5.8) -->
          <p class="name-chip">{{ a.meta.label }}</p>
        </div>
      </div>
    </div>

    <!-- 舞台下: 割当の全量 (吹き出しは 2 件までの要約のため、こちらが正) -->
    <div class="assignments">
      <article v-for="a in actors" :key="a.id" class="assign" :data-character="a.id">
        <h2 class="assign-name">
          <img class="assign-face" :src="a.meta.img" alt="" aria-hidden="true" />
          {{ a.meta.label }}
          <span class="assign-state" :class="`pill-${a.view.state}`">{{ STATE_LABEL[a.view.state] }}</span>
        </h2>
        <ul v-if="a.view.tasks.length" class="tasks">
          <!-- :key は index 併用 — 重複 id 台帳では同文の task が並びうる (文字列単独だと衝突) -->
          <li v-for="(task, i) in a.view.tasks" :key="`${i}:${task}`">{{ task }}</li>
        </ul>
        <p v-else class="tasks-empty">割当なし</p>
      </article>
    </div>
  </section>
</template>

<style scoped>
/*
 * ステージ層のパレット (DESIGN.md 3.2 / 3.3)。ページ全体は管制室ダークのままにし、
 * 「暗い枠の中に暖色のドット絵世界が窓のように開く」対比だけをこの component 内で作る。
 * (背景の木床/レンガ/家具の色は office.png へ焼き込み済み — issue #104。ここに残すのは
 *  DOM オーバーレイ = 吹き出し/チップ/アラート + ベゼル枠の色のみ)
 */
.stage {
  --stage-bezel: #17110b;
  --bubble-bg: rgba(22, 15, 9, 0.92);
  --bubble-name: #e4b96a;
  --alert-bg: #4e1712;
  --alert-border: #c3372e;
  --alert-title: #f2c063;
  /* キャラスプライトの共通表示高 (issue #97 🟡A)。元解像度がばらつく 4 体をこの高さへ揃える。手動調整可 */
  --sprite-h: 46px;

  position: relative;
  padding: 14px 16px 16px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background:
    radial-gradient(360px 160px at 50% -40px, rgba(64, 110, 190, 0.16), transparent 70%),
    var(--tray);
  box-shadow: inset 0 2px 12px rgba(0, 0, 0, 0.45);
}

.stage.is-celebrating {
  border-color: rgba(242, 201, 76, 0.55);
  box-shadow:
    inset 0 2px 12px rgba(0, 0, 0, 0.45),
    0 0 18px rgba(242, 201, 76, 0.18);
}

/* エスカレーションは祝いより優先 (両立時は警告色を前面に — 人間判断待ちの方が緊急度が高い) */
.stage.is-escalating {
  border-color: rgba(255, 123, 114, 0.55);
  box-shadow:
    inset 0 2px 12px rgba(0, 0, 0, 0.45),
    0 0 18px rgba(255, 123, 114, 0.22);
}

.stage-tag {
  margin: 0 0 10px;
  font-family: var(--font-mono);
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.32em;
  color: var(--text-lo);
}

/* --- ベゼル額装 (5.6) --- */
.bezel {
  padding: 8px;
  border-radius: 14px;
  background: var(--stage-bezel);
  box-shadow: 0 12px 28px rgba(0, 0, 0, 0.5);
}

/* --- シーン: 論理座標 488×339 (背景画像実寸) の窓。% 配置でコンテナ幅に追従スケール (6.2) --- */
.scene {
  position: relative;
  aspect-ratio: 488 / 339;
  width: 100%;
  overflow: hidden;
  border-radius: 8px;
  /* 背景 img の読込前・端数丸め時のフォールバック地色 (ベゼル暗色に馴染ませる) */
  background: var(--stage-bezel);
}

/* レイヤ0: オフィス俯瞰の背景 1 枚絵 (issue #104)。aspect-ratio が画像実比 488/339 と一致するので
   歪みなく敷き詰まる。整数倍でない拡大でも nearest-neighbor でドット感を保つ (DESIGN.md 6.4) */
.office-bg {
  position: absolute;
  inset: 0;
  z-index: 0;
  width: 100%;
  height: 100%;
  object-fit: cover;
  image-rendering: pixelated;
}

/* --- アクター (レイヤ1〜3 の親)。座標は % で追従、z は y 昇順 (script 側で採番) --- */
.actor {
  position: absolute;
  width: 0;
  height: 0;
  /* 状態変化でスポット間を移動する (7 章: 300ms 転移。座標遷移で歩行の代替) */
  transition:
    left 0.45s ease-in-out,
    top 0.45s ease-in-out;
}

/* レイヤ1: スプライト。アンカー = 足元 (actor の座標点) */
.sprite {
  position: absolute;
  bottom: 0;
  left: 50%;
  transform: translateX(-50%);
  display: flex;
  justify-content: center;
}

.face {
  position: relative;
  z-index: 1;
  display: block;
  /* 整数倍でない拡大でも nearest-neighbor でドット感を保つ (DESIGN.md 6.4)。元解像度は 4 体でばらつく
     (chactor4 は他の約半分) が、共通の表示高 --sprite-h で on-screen サイズを揃える
     (issue #97 🟡A の (b): 共通表示高 + width:auto で縦横比維持)。 */
  height: var(--sprite-h, 46px);
  width: auto;
  image-rendering: pixelated;
}

.shadow {
  position: absolute;
  bottom: -3px;
  left: 50%;
  transform: translateX(-50%);
  width: 30px;
  height: 7px;
  border-radius: 50%;
  background: rgba(0, 0, 0, 0.35);
}

.state-working .face {
  animation: work-bob 0.5s ease-in-out infinite alternate;
}

@keyframes work-bob {
  from {
    transform: translateY(0);
  }
  to {
    transform: translateY(-3px);
  }
}

.state-waiting .face {
  animation: waiting-breath 2.4s ease-in-out infinite;
}

@keyframes waiting-breath {
  0%,
  100% {
    transform: translateY(0);
  }
  50% {
    transform: translateY(-2px);
  }
}

.state-idle .face {
  filter: grayscale(0.65);
  opacity: 0.75;
}

/* レイヤ2: 名前チップ (足元の下・キャラ追従 — 5.8) */
.name-chip {
  position: absolute;
  top: 3px;
  left: 50%;
  transform: translateX(-50%);
  margin: 0;
  padding: 1px 6px;
  border-radius: 4px;
  background: var(--bubble-bg);
  color: #fff;
  font-family: var(--font-mono);
  font-size: 9px;
  white-space: nowrap;
}

/* レイヤ3: 状態吹き出し (キャラ上端・下向きしっぽ — 5.8)。
   bottom は絵文字時代の 36px から、透過ピクセルアート (--sprite-h 46px) の頭上を確実に越える高さへ引き上げ */
.bubble {
  position: absolute;
  bottom: 52px;
  left: 50%;
  transform: translateX(-50%);
  width: max-content;
  max-width: 148px;
  padding: 5px 8px 6px;
  border-radius: 6px;
  background: var(--bubble-bg);
  border: 1px solid rgba(228, 185, 106, 0.35);
  text-align: left;
}

.bubble::after {
  content: '';
  position: absolute;
  top: 100%;
  left: 50%;
  transform: translateX(-50%);
  border: 5px solid transparent;
  border-top-color: var(--bubble-bg);
}

.bubble-name {
  margin: 0;
  color: var(--bubble-name);
  font-size: 10px;
  font-weight: 700;
  line-height: 1.4;
}

.bubble-state {
  margin: 0;
  color: #f0e6d2;
  font-size: 10px;
  line-height: 1.45;
}

.bubble-task {
  margin: 2px 0 0;
  color: #b9a88c;
  font-family: var(--font-mono);
  font-size: 9px;
  line-height: 1.4;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 132px;
}

.bubble-more {
  color: #8f8069;
}

/* --- エスカレーション吹き出し (5.8 アラート様式・z は全キャラより上) --- */
.alert-bubble {
  position: absolute;
  z-index: 600;
  top: 20%;
  left: 50%;
  transform: translateX(-50%);
  max-width: 78%;
  padding: 6px 12px;
  border-radius: 6px;
  background: var(--alert-bg);
  border: 2px solid var(--alert-border);
  animation: alert-blink 1.5s ease-in-out infinite;
}

.alert-title {
  margin: 0;
  color: var(--alert-title);
  font-size: 11px;
  font-weight: 700;
}

.alert-body {
  margin: 2px 0 0;
  color: #f3cdc4;
  font-size: 10px;
}

@keyframes alert-blink {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.88;
  }
}

.celebrate-chip {
  position: absolute;
  z-index: 600;
  bottom: 4%;
  left: 50%;
  transform: translateX(-50%);
  padding: 3px 10px;
  border-radius: 999px;
  background: var(--gold-dim);
  border: 1px solid rgba(242, 201, 76, 0.6);
  color: var(--gold);
  font-size: 10px;
  font-weight: 700;
  white-space: nowrap;
}

/* --- 祝い: 紙吹雪 (キャラより手前・アラートより奥) --- */
.confetti {
  position: absolute;
  inset: 0;
  z-index: 550;
  pointer-events: none;
}

.piece {
  position: absolute;
  top: -12px;
  width: 6px;
  height: 10px;
  border-radius: 2px;
  opacity: 0;
  animation-name: confetti-fall;
  animation-timing-function: linear;
  animation-iteration-count: infinite;
}

@keyframes confetti-fall {
  0% {
    transform: translateY(-10%) rotate(0deg);
    opacity: 0;
  }
  10% {
    opacity: 0.95;
  }
  100% {
    transform: translateY(300px) rotate(680deg);
    opacity: 0.1;
  }
}

/* --- 舞台下の割当リスト (全量表示) --- */
.assignments {
  display: grid;
  grid-template-columns: 1fr;
  gap: 8px;
  margin-top: 12px;
}

.assign {
  --role: var(--text-lo);
  --role-dim: rgba(125, 138, 163, 0.12);
  padding: 8px 10px;
  border: 1px solid var(--line);
  border-left: 2px solid var(--role);
  border-radius: 8px;
  background: var(--panel);
}

/* キャラ 4 値 → 舞台下カードの色も colorGroup と同じ 2 色系へ写像 (issue #97 🟡2 と整合):
   実装者 + 対応者 = developer 系 (琥珀) / PR・Issue レビュー者 = reviewer 系 (青緑) */
.assign[data-character='implementer'],
.assign[data-character='responder'] {
  --role: var(--dev);
  --role-dim: var(--dev-dim);
}

.assign[data-character='pr-reviewer'],
.assign[data-character='issue-reviewer'] {
  --role: var(--rev);
  --role-dim: var(--rev-dim);
}

.assign-name {
  margin: 0;
  font-size: 12px;
  font-weight: 700;
  color: var(--role);
  display: flex;
  align-items: center;
  gap: 6px;
}

/* 舞台下リストのロール見出しに添える小さなピクセルアート (絵文字 face の置き換え・issue #97) */
.assign-face {
  height: 22px;
  width: auto;
  image-rendering: pixelated;
  flex: none;
}

.assign-state {
  margin-left: auto;
  padding: 1px 8px;
  border-radius: 10px;
  border: 1px solid transparent;
  font-size: 10px;
  font-weight: 700;
}

.pill-working {
  background: var(--role-dim);
  border-color: var(--role);
  color: var(--role);
}

.pill-waiting {
  border-color: var(--role);
  color: var(--role);
  opacity: 0.85;
}

.pill-idle {
  background: rgba(125, 138, 163, 0.12);
  color: var(--text-lo);
}

.tasks {
  margin: 6px 0 0;
  padding: 0;
  list-style: none;
  font-family: var(--font-mono);
  font-variant-numeric: tabular-nums;
  font-size: 11px;
  line-height: 1.5;
  color: var(--text);
}

.tasks li {
  padding: 2px 6px;
  border-left: 2px solid var(--role);
  margin-bottom: 2px;
  background: rgba(255, 255, 255, 0.02);
}

.tasks-empty {
  margin: 6px 0 0;
  font-size: 11px;
  color: var(--text-lo);
}
</style>
