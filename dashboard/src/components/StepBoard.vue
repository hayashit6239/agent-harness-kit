<script setup lang="ts">
import type { StepView, UnknownStatusWarning } from '../lib/derive';

const props = defineProps<{
  steps: StepView[];
  warnings: UnknownStatusWarning[];
  repoSlug: string | null;
}>();

function issueUrl(num: number): string {
  return `https://github.com/${props.repoSlug}/issues/${num}`;
}

function prUrl(num: number): string {
  return `https://github.com/${props.repoSlug}/pull/${num}`;
}

const WORKING = new Set(['starting review', 'starting review work']);
const READY = new Set(['ready for implementation', 'ready for merge']);
const TERMINAL = new Set(['closed issue', 'merged pr']);

function statusClass(status: string | null, known: boolean): string {
  if (status === null) return 'is-none';
  if (!known) return 'is-unknown';
  if (WORKING.has(status)) return 'is-working';
  if (READY.has(status)) return 'is-ready';
  if (TERMINAL.has(status)) return 'is-terminal';
  return 'is-waiting';
}
</script>

<template>
  <section class="board">
    <div v-if="warnings.length" class="board-warning">
      ⚠ 未知の status があります (schema 語彙外のためキャラ信号には数えません):
      <span v-for="w in warnings" :key="`${w.stepId}-${w.phase}`" class="warning-item">
        {{ w.stepId }} {{ w.phase }}: 「{{ w.status }}」
      </span>
    </div>

    <table>
      <thead>
        <tr>
          <th class="col-id">step</th>
          <th>内容</th>
          <th class="col-phase">issue フェーズ</th>
          <th class="col-phase">PR フェーズ</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="s in steps" :key="s.id" :class="{ celebrating: s.celebrating }">
          <td class="col-id">
            <span class="step-id">{{ s.id }}</span>
            <span v-if="s.kind" class="kind">{{ s.kind }}</span>
          </td>
          <td class="title">
            <span v-if="s.celebrating" class="party" title="ready for merge">🎉</span>
            {{ s.title ?? '' }}
          </td>
          <td class="col-phase">
            <span class="status" :class="statusClass(s.issue.status, s.issue.known)">
              <span v-if="!s.issue.known" title="schema 語彙にない status">⚠</span>
              {{ s.issue.status ?? '—' }}
            </span>
            <a
              v-if="s.issue.number !== null && repoSlug !== null"
              :href="issueUrl(s.issue.number)"
              target="_blank"
              rel="noreferrer"
            >#{{ s.issue.number }}</a>
            <span v-else-if="s.issue.number !== null" class="nolink" title="repo slug を導出できずリンク無効">#{{ s.issue.number }}</span>
          </td>
          <td class="col-phase">
            <span class="status" :class="statusClass(s.pr.status, s.pr.known)">
              <span v-if="!s.pr.known" title="schema 語彙にない status">⚠</span>
              {{ s.pr.status ?? '—' }}
            </span>
            <a
              v-if="s.pr.number !== null && repoSlug !== null"
              :href="prUrl(s.pr.number)"
              target="_blank"
              rel="noreferrer"
            >#{{ s.pr.number }}</a>
            <span v-else-if="s.pr.number !== null" class="nolink" title="repo slug を導出できずリンク無効">#{{ s.pr.number }}</span>
          </td>
        </tr>
        <tr v-if="steps.length === 0">
          <td colspan="4" class="empty">台帳に step がありません</td>
        </tr>
      </tbody>
    </table>
  </section>
</template>

<style scoped>
.board {
  background: #ffffff;
  border: 1px solid #d0d7de;
  border-radius: 10px;
  overflow: hidden;
}

.board-warning {
  padding: 8px 14px;
  background: #fff1e5;
  border-bottom: 1px solid #f0b37e;
  color: #7a3b00;
  font-size: 13px;
}

.warning-item {
  margin-left: 8px;
  font-weight: 600;
}

table {
  width: 100%;
  border-collapse: collapse;
  font-size: 14px;
}

th,
td {
  padding: 9px 12px;
  text-align: left;
  border-bottom: 1px solid #eaeef2;
  vertical-align: top;
}

th {
  background: #f6f8fa;
  color: #57606a;
  font-size: 12px;
  font-weight: 600;
}

tbody tr:last-child td {
  border-bottom: none;
}

.col-id {
  white-space: nowrap;
  width: 1%;
}

.col-phase {
  white-space: nowrap;
  width: 1%;
}

.step-id {
  font-weight: 700;
}

.kind {
  margin-left: 6px;
  padding: 1px 6px;
  border-radius: 10px;
  background: #eaeef2;
  color: #57606a;
  font-size: 11px;
}

.title {
  color: #24292f;
}

.status {
  display: inline-block;
  margin-right: 8px;
  padding: 1px 8px;
  border-radius: 12px;
  font-size: 12px;
  font-weight: 600;
}

.is-none {
  color: #8c959f;
}

.is-working {
  background: #ddf4ff;
  color: #0550ae;
}

.is-waiting {
  background: #fff8c5;
  color: #7d4e00;
}

.is-ready {
  background: #dafbe1;
  color: #116329;
}

.is-terminal {
  background: #eaeef2;
  color: #57606a;
}

.is-unknown {
  background: #ffebe9;
  color: #a40e26;
}

.nolink {
  color: #8c959f;
}

/* 祝いフラグの由来 step 行を強調 (合成規則 3) */
tr.celebrating td {
  background: #fff8e1;
}

tr.celebrating .title {
  font-weight: 600;
}

.party {
  margin-right: 4px;
}

.empty {
  color: #8c959f;
  text-align: center;
}
</style>
