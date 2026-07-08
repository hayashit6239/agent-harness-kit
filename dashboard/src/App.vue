<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue';
import CharacterStage from './components/CharacterStage.vue';
import StepBoard from './components/StepBoard.vue';
import { derive } from './lib/derive';
import type { Ledger, LedgerApiResponse } from './types';

/** ポーリング既定値 5 秒 (issue #9 決定事項。DoD ③「10 秒以内」= 5 秒 × 2 周期分) */
const POLL_INTERVAL_MS = 5000;

const ledger = ref<Ledger | null>(null);
const repoSlug = ref<string | null>(null);
const fetchedAt = ref<string | null>(null);
const errorMessage = ref<string | null>(null);

async function poll(): Promise<void> {
  try {
    const res = await fetch('/api/ledger');
    const body = (await res.json()) as LedgerApiResponse;
    if (body.ok) {
      ledger.value = body.ledger;
      repoSlug.value = body.repoSlug;
      fetchedAt.value = body.fetchedAt;
      errorMessage.value = null;
    } else {
      // エラー時: バナー表示 + 前回データがあれば表示継続。ポーリングは継続 (劣化動作)
      errorMessage.value = `${body.error.code}: ${body.error.message}`;
    }
  } catch {
    errorMessage.value = '台帳 API に接続できません (dev サーバの応答がありません)';
  }
}

let timer: number | undefined;
onMounted(() => {
  void poll();
  timer = window.setInterval(() => void poll(), POLL_INTERVAL_MS);
});
onUnmounted(() => {
  if (timer !== undefined) window.clearInterval(timer);
});

const board = computed(() => (ledger.value ? derive(ledger.value) : null));

function formatTime(iso: string): string {
  return new Date(iso).toLocaleTimeString('ja-JP');
}
</script>

<template>
  <div class="dashboard">
    <header class="header">
      <h1>進捗ダッシュボード</h1>
      <p v-if="ledger" class="meta">
        <strong>{{ ledger.project ?? '(project 名なし)' }}</strong>
        <span>台帳更新日: {{ ledger.updatedAt }}</span>
        <span v-if="fetchedAt">最終取得: {{ formatTime(fetchedAt) }}</span>
        <span v-if="repoSlug === null" class="degraded">GitHub リンク無効 (repo slug を導出できず)</span>
      </p>
    </header>

    <div v-if="errorMessage" class="banner">
      ⚠ {{ errorMessage }}
      <span v-if="ledger">— 前回取得分を表示しています (ポーリング継続中)</span>
    </div>

    <main v-if="board">
      <StepBoard :steps="board.steps" :warnings="board.warnings" :repo-slug="repoSlug" />
      <CharacterStage :characters="board.characters" :celebrate="board.celebrate" />
    </main>
    <p v-else-if="!errorMessage" class="loading">台帳を読み込み中…</p>
  </div>
</template>

<style scoped>
.dashboard {
  max-width: 1080px;
  margin: 0 auto;
  padding: 24px 20px 48px;
}

.header h1 {
  margin: 0 0 4px;
  font-size: 22px;
}

.meta {
  margin: 0 0 16px;
  display: flex;
  flex-wrap: wrap;
  gap: 6px 16px;
  font-size: 13px;
  color: #57606a;
}

.meta strong {
  color: #24292f;
}

.degraded {
  color: #9a6700;
}

.banner {
  margin: 0 0 16px;
  padding: 10px 14px;
  border: 1px solid #d4a72c;
  border-radius: 8px;
  background: #fff8c5;
  color: #4d3800;
  font-size: 14px;
}

.loading {
  color: #57606a;
}
</style>
