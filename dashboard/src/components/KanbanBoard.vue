<script setup lang="ts">
/**
 * カンバンボード: issue フェーズ / PR フェーズの 2 レーン。
 * 列 = status の遷移順 (空の列も表示して流れを見せる)。カード = step (両レーンに 1 枚ずつ)。
 * グルーピングは deriveKanban (純関数・vitest 対象) に委ね、ここは表示だけを担う。
 */
import { computed } from 'vue';
import type { KanbanCard, KanbanColumn, Phase, StepView, UnknownStatusWarning } from '../lib/derive';
import { deriveKanban } from '../lib/derive';

const props = defineProps<{
  steps: StepView[];
  warnings: UnknownStatusWarning[];
  repoSlug: string | null;
}>();

const kanban = computed(() => deriveKanban(props.steps));

const LANE_TITLES: Record<Phase, string> = {
  issue: 'issue フェーズ',
  pr: 'PR フェーズ',
};

/** 列ヘッダの表示名 (null = 未着手列 / unknown 列は固定名) */
function columnLabel(col: KanbanColumn): string {
  if (col.kind === 'unknown') return 'unknown';
  return col.status ?? '未着手';
}

/** unknown 列は空なら出さない (流れの列ではなく警告列のため)。flow / terminal は空でも表示 */
function visibleColumns(columns: KanbanColumn[]): KanbanColumn[] {
  return columns.filter((c) => c.kind !== 'unknown' || c.cards.length > 0);
}

/** 祝い演出: ready for merge 列にカードがある = celebrate フラグ発火と同値 */
function isCelebrating(col: KanbanColumn): boolean {
  return col.status === 'ready for merge' && col.cards.length > 0;
}

function cardUrl(phase: Phase, card: KanbanCard): string {
  const path = phase === 'issue' ? 'issues' : 'pull';
  return `https://github.com/${props.repoSlug}/${path}/${card.number}`;
}
</script>

<template>
  <section class="kanban">
    <div v-if="warnings.length" class="kanban-warning">
      ⚠ 未知の status があります (schema 語彙外のため unknown 列に置いています):
      <span v-for="w in warnings" :key="`${w.stepId}-${w.phase}`" class="warning-item">
        {{ w.stepId }} {{ w.phase }}: 「{{ w.status }}」
      </span>
    </div>

    <p v-if="steps.length === 0" class="empty">台帳に step がありません</p>

    <div v-for="lane in [kanban.issue, kanban.pr]" :key="lane.phase" class="lane">
      <h2 class="lane-title">{{ LANE_TITLES[lane.phase] }}</h2>
      <div class="lane-scroll">
        <div class="columns">
          <div
            v-for="(col, i) in visibleColumns(lane.columns)"
            :key="`${col.kind}-${col.status ?? i}`"
            class="column"
            :class="[`kind-${col.kind}`, { celebrating: isCelebrating(col) }]"
          >
            <header class="column-head">
              <span class="column-name">
                <span v-if="col.kind === 'unknown'" title="schema 語彙にない status">⚠</span>
                <span v-if="isCelebrating(col)">🎉</span>
                {{ columnLabel(col) }}
              </span>
              <span class="count" :class="{ 'count-zero': col.cards.length === 0 }">{{ col.cards.length }}</span>
              <span v-if="col.kind === 'terminal'" class="terminal-mark">終端</span>
            </header>
            <div class="cards">
              <article v-for="card in col.cards" :key="card.stepId" class="card">
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
                <p v-if="col.kind === 'unknown'" class="raw-status">status: 「{{ card.status }}」</p>
              </article>
            </div>
          </div>
        </div>
      </div>
    </div>
  </section>
</template>

<style scoped>
.kanban {
  background: #ffffff;
  border: 1px solid #d0d7de;
  border-radius: 10px;
  padding: 14px;
}

.kanban-warning {
  margin: 0 0 12px;
  padding: 8px 14px;
  background: #fff1e5;
  border: 1px solid #f0b37e;
  border-radius: 8px;
  color: #7a3b00;
  font-size: 13px;
}

.warning-item {
  margin-left: 8px;
  font-weight: 600;
}

.empty {
  margin: 4px 2px;
  color: #8c959f;
  text-align: center;
}

.lane + .lane {
  margin-top: 18px;
  padding-top: 14px;
  border-top: 1px solid #eaeef2;
}

.lane-title {
  margin: 0 0 8px;
  font-size: 14px;
  font-weight: 700;
  color: #24292f;
}

/* レーンは横スクロール可 (列数が画面幅を超える場合) */
.lane-scroll {
  overflow-x: auto;
  padding-bottom: 4px;
}

.columns {
  display: flex;
  gap: 8px;
  align-items: stretch;
  min-width: max-content;
}

.column {
  flex: 0 0 132px;
  width: 132px;
  display: flex;
  flex-direction: column;
  background: #f6f8fa;
  border: 1px solid #eaeef2;
  border-radius: 8px;
  min-height: 88px;
}

.column-head {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 4px;
  padding: 6px 8px;
  border-bottom: 1px solid #eaeef2;
}

.column-name {
  font-size: 11px;
  font-weight: 600;
  color: #57606a;
  line-height: 1.3;
  overflow-wrap: anywhere;
}

.count {
  margin-left: auto;
  padding: 0 6px;
  border-radius: 10px;
  background: #d0d7de;
  color: #24292f;
  font-size: 11px;
  font-weight: 700;
}

.count-zero {
  background: transparent;
  color: #8c959f;
  font-weight: 400;
}

.terminal-mark {
  flex-basis: 100%;
  font-size: 10px;
  color: #8c959f;
}

.cards {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 6px;
  flex: 1;
}

.card {
  background: #ffffff;
  border: 1px solid #d0d7de;
  border-radius: 6px;
  padding: 6px 8px;
  box-shadow: 0 1px 0 rgba(31, 35, 40, 0.04);
}

.card-head {
  display: flex;
  align-items: center;
  gap: 5px;
  flex-wrap: wrap;
}

.step-id {
  font-size: 12px;
  font-weight: 700;
  color: #24292f;
}

.kind-badge {
  padding: 0 5px;
  border-radius: 8px;
  background: #eaeef2;
  color: #57606a;
  font-size: 10px;
}

.number {
  margin-left: auto;
  font-size: 11px;
}

.nolink {
  color: #8c959f;
}

/* title は 2 行で省略 (全文は title 属性で参照可) */
.card-title {
  margin: 4px 0 0;
  font-size: 11px;
  line-height: 1.4;
  color: #57606a;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.raw-status {
  margin: 4px 0 0;
  font-size: 10px;
  color: #a40e26;
  overflow-wrap: anywhere;
}

/* 終端列 (closed issue / merged pr) は控えめに */
.column.kind-terminal {
  background: #f0f2f5;
  border-style: dashed;
  opacity: 0.75;
}

/* 未知 status の警告列 (レーン右端) */
.column.kind-unknown {
  background: #fff5f5;
  border-color: #f5a3a3;
}

.column.kind-unknown .column-name {
  color: #a40e26;
}

/* 祝いフラグ発火時の ready for merge 列の強調 (合成規則 3 と同じ由来) */
.column.celebrating {
  background: #fff8e1;
  border-color: #d4a72c;
  box-shadow: 0 0 0 2px rgba(212, 167, 44, 0.25);
}

.column.celebrating .column-name {
  color: #7d4e00;
}
</style>
