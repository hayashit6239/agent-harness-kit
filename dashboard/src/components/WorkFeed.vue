<script setup lang="ts">
import { computed } from 'vue';
import type { FeedItem } from '../lib/derive';

/**
 * 作業フィード (issue #25 レイヤ5・DESIGN.md 5.5)。
 * deriveFeed (レイヤ2) が timestamp 降順に束ねた FeedItem[] を消費して、
 * 相対 + 絶対タイムスタンプ付きのタイムラインを描画する。
 *
 * 新着は配列の先頭に来る (deriveFeed が降順ソート済み) — 先頭挿入の演出は
 * TransitionGroup が担う。相対時刻は「ポーリングごとに再計算」が要件のため、
 * now (親が /api/ledger 取得ごとに更新する fetchedAt) への依存で computed を毎回引き直す。
 */

const props = defineProps<{
  items: FeedItem[];
  /** 相対時刻の基準 (親のポーリングごとに更新される ISO 文字列。null なら描画時刻) */
  now: string | null;
}>();

const nowMs = computed(() => {
  const parsed = props.now === null ? Number.NaN : Date.parse(props.now);
  return Number.isNaN(parsed) ? Date.now() : parsed;
});

/** 相対時刻 (15秒前 / 3分前 / 2時間前 / 4日前)。未来向き・軽微なズレは「たった今」に丸める */
function relativeLabel(time: number | null, base: number): string {
  if (time === null) return '時刻不明';
  const diffSec = Math.floor((base - time) / 1000);
  if (diffSec < 10) return 'たった今';
  if (diffSec < 60) return `${diffSec}秒前`;
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)}分前`;
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}時間前`;
  return `${Math.floor(diffSec / 86400)}日前`;
}

/** 絶対時刻 (MM/DD HH:mm:ss)。time=null は台帳の生文字列があればそれを、無ければ — */
function absoluteLabel(item: FeedItem): string {
  if (item.time === null) return item.timestamp ?? '—';
  return new Date(item.time).toLocaleString('ja-JP', {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });
}

const rows = computed(() => {
  const base = nowMs.value; // now への依存でポーリングごとに全行の相対時刻を再計算する
  return props.items.map((item) => ({
    ...item,
    relative: relativeLabel(item.time, base),
    absolute: absoluteLabel(item),
  }));
});
</script>

<template>
  <section class="feed">
    <h2 class="feed-title">📋 作業フィード</h2>
    <TransitionGroup v-if="rows.length" tag="ul" name="feed" class="list">
      <li v-for="row in rows" :key="row.key" class="item">
        <span class="when" :title="row.absolute">{{ row.relative }}</span>
        <div class="entry">
          <p class="who">
            <strong class="author">{{ row.author }}</strong>
            <span class="role">{{ row.role }}</span>
            <span class="step mono" :title="row.stepTitle ?? undefined">{{ row.stepId }}</span>
          </p>
          <p class="body">{{ row.body || '(本文なし)' }}</p>
          <p class="abs mono">{{ row.absolute }}</p>
        </div>
      </li>
    </TransitionGroup>
    <!-- 空状態プレースホルダ (DoD ③) -->
    <p v-else class="empty">
      まだ作業レポートがありません — 台帳の <span class="mono">steps[].reports[]</span>
      に最初のレポートが書かれるとここに時系列で流れます
    </p>
  </section>
</template>

<style scoped>
.feed {
  padding: 14px 16px 16px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: var(--tray);
  box-shadow: inset 0 2px 12px rgba(0, 0, 0, 0.45);
}

.feed-title {
  margin: 0 0 10px;
  font-family: var(--font-mono);
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.18em;
  color: var(--text-lo);
}

.list {
  margin: 0;
  padding: 0;
  list-style: none;
  /* 縦帯列 (App.vue .feed-col) が 1 ビューポート内スクロールを所有するため、内部の固定キャップ
     (旧 max-height:420px) は外す (issue #97 🟡5)。列を持たない単体利用の保険として overflow-y は残す。 */
  overflow-y: auto;
}

.item {
  display: flex;
  gap: 8px;
  padding: 7px 2px;
  border-bottom: 1px solid var(--line);
}

.item:last-child {
  border-bottom: none;
}

.when {
  flex: none;
  width: 58px;
  font-family: var(--font-mono);
  font-variant-numeric: tabular-nums;
  font-size: 11px;
  color: var(--text-lo);
  line-height: 1.7;
}

.entry {
  min-width: 0;
}

.who {
  margin: 0;
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 6px;
  font-size: 12px;
}

.author {
  color: var(--text-hi);
  font-weight: 700;
}

.role {
  padding: 0 6px;
  border: 1px solid var(--line);
  border-radius: 999px;
  font-size: 10px;
  color: var(--text-lo);
}

.step {
  font-size: 10px;
  color: var(--rev);
}

.mono {
  font-family: var(--font-mono);
  font-variant-numeric: tabular-nums;
}

.body {
  margin: 2px 0 0;
  font-size: 12px;
  line-height: 1.55;
  color: var(--text);
  /* 長文は 3 行程度で省略 (DESIGN.md 5.5)。全文はタイムライン肥大を避けるため出さない */
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.abs {
  margin: 2px 0 0;
  font-size: 10px;
  color: var(--text-lo);
}

.empty {
  margin: 0;
  padding: 14px 4px;
  font-size: 12px;
  color: var(--text-lo);
}

/* 新着の先頭挿入モーション (DESIGN.md 5.5: opacity 0→1 + translateY(-4px)→0 200ms) */
.feed-enter-active {
  transition:
    opacity 0.2s ease,
    transform 0.2s ease;
}

.feed-enter-from {
  opacity: 0;
  transform: translateY(-4px);
}

.feed-leave-active {
  transition: opacity 0.15s ease;
}

.feed-leave-to {
  opacity: 0;
}
</style>
