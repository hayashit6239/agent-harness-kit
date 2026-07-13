<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue';
import CharacterStage from './components/CharacterStage.vue';
import CommandPanel from './components/CommandPanel.vue';
import KanbanBoard from './components/KanbanBoard.vue';
import WorkFeed from './components/WorkFeed.vue';
import { parseLedgerResponse } from './lib/api';
import { derive, deriveFeed } from './lib/derive';
import type { Ledger } from './types';

/** ポーリング既定値 5 秒 (issue #9 決定事項。DoD ③「10 秒以内」= 5 秒 × 2 周期分) */
const POLL_INTERVAL_MS = 5000;

const ledger = ref<Ledger | null>(null);
const repoSlug = ref<string | null>(null);
const fetchedAt = ref<string | null>(null);
const errorMessage = ref<string | null>(null);

// WHY (世代トークン): setInterval の各 poll は応答順序が保証されず、遅延した古い応答が
// 新しい応答の後に届くと盤面が一時的に (最大 1 周期分) 過去へ巻き戻る。発行時に世代を
// 採番し、await をまたいだ後の状態書込み前に「自分が最新の発行か」を確認して
// 古い応答 (成功・失敗とも) は黙って破棄する。
let pollGeneration = 0;

async function poll(): Promise<void> {
  const generation = ++pollGeneration;
  const isStale = (): boolean => generation !== pollGeneration;
  // 失敗系はバナー表示 + 前回データがあれば表示継続。ポーリングは継続 (劣化動作)。
  // 接続失敗 (fetch 例外) と JSON 解析失敗 (API 不在で 200/HTML が返る構成) は原因が違うので分けて伝える
  let res: Response;
  try {
    res = await fetch('/api/ledger');
  } catch {
    if (isStale()) return;
    errorMessage.value = '台帳 API に接続できません (dev サーバの応答がありません)';
    return;
  }
  let raw: unknown;
  try {
    raw = await res.json();
  } catch {
    if (isStale()) return;
    errorMessage.value = '台帳 API の応答を JSON として解釈できません (/api/ledger を持たないサーバが応答している可能性)';
    return;
  }
  if (isStale()) return;
  // 封筒形の検証は純関数 parseLedgerResponse に委譲 — 封筒形でない JSON
  // (プロキシの {"message":"Not Found"} 等) は BAD_RESPONSE の失敗封筒に正規化される
  const body = parseLedgerResponse(raw);
  if (body.ok) {
    ledger.value = body.ledger;
    repoSlug.value = body.repoSlug;
    fetchedAt.value = body.fetchedAt;
    errorMessage.value = null;
  } else {
    errorMessage.value = `${body.error.code}: ${body.error.message}`;
  }
}

let timer: number | undefined;
onMounted(() => {
  void poll();
  timer = window.setInterval(() => void poll(), POLL_INTERVAL_MS);
});
onUnmounted(() => {
  if (timer !== undefined) window.clearInterval(timer);
  pollGeneration++; // 飛行中の応答も破棄する (unmount 後の状態書込みを防ぐ)
});

const board = computed(() => (ledger.value ? derive(ledger.value) : null));

/** 作業フィード (issue #25 レイヤ5)。fetchedAt をポーリングごとに渡し相対時刻を再計算させる */
const feed = computed(() => (ledger.value ? deriveFeed(ledger.value) : []));

function formatTime(iso: string): string {
  return new Date(iso).toLocaleTimeString('ja-JP');
}
</script>

<template>
  <div class="dashboard">
    <header class="header">
      <p class="eyebrow">AGENT HARNESS — MISSION CONTROL</p>
      <h1>進捗ダッシュボード</h1>
      <p v-if="ledger" class="meta">
        <strong class="project">{{ ledger.project ?? '(project 名なし)' }}</strong>
        <span class="mono">台帳更新日 {{ ledger.updatedAt }}</span>
        <span v-if="fetchedAt" class="mono live">
          <span class="led" :class="errorMessage ? 'led-alert' : 'led-ok'" aria-hidden="true"></span>
          最終取得 {{ formatTime(fetchedAt) }}
        </span>
        <span v-if="repoSlug === null" class="degraded">GitHub リンク無効 (repo slug を導出できず)</span>
      </p>
    </header>

    <div v-if="errorMessage" class="banner" role="alert">
      ⚠ {{ errorMessage }}
      <span v-if="ledger">— 前回取得分を表示しています (ポーリング継続中)</span>
    </div>

    <main v-if="board" class="layout">
      <!-- 左: コマンド送信パネル (枠 + 開閉のみ — issue #25 レイヤ6。実送信は別 issue) -->
      <CommandPanel class="command" />
      <KanbanBoard :steps="board.steps" :warnings="board.warnings" :repo-slug="repoSlug" />
      <aside class="side">
        <CharacterStage :characters="board.characters" :celebrate="board.celebrate" :escalate="board.escalate" />
        <WorkFeed :items="feed" :now="fetchedAt" />
      </aside>
    </main>
    <p v-else-if="!errorMessage" class="loading mono">台帳を読み込み中<span class="cursor">▋</span></p>
  </div>
</template>

<style scoped>
.dashboard {
  /* カンバン (issue 9 列 + PR 10 列) + 右のキャラ側柱をなるべくスクロールなしで見せるため広めに取る */
  max-width: 1720px;
  margin: 0 auto;
  padding: 28px 24px 56px;
}

/* 左パネル (auto = 開閉で伸縮) + カンバン (可変幅) + 右側柱 (ステージ + フィード) の 3 段組 */
.layout {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) 360px;
  gap: 18px;
  align-items: start;
}

.command {
  position: sticky;
  top: 16px;
}

.side {
  position: sticky;
  top: 16px;
  display: grid;
  gap: 14px;
  align-content: start;
  max-height: calc(100vh - 32px);
  overflow-y: auto;
}

/* 幅が足りない画面では縦積みに戻す (キャラは下段) */
@media (max-width: 1100px) {
  .layout {
    grid-template-columns: minmax(0, 1fr);
  }
  .side,
  .command {
    position: static;
  }
  .side {
    max-height: none;
    overflow-y: visible;
  }
}

.eyebrow {
  margin: 0 0 2px;
  font-family: var(--font-mono);
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.32em;
  color: var(--text-lo);
}

.header h1 {
  margin: 0 0 6px;
  font-size: 26px;
  font-weight: 700;
  letter-spacing: 0.04em;
  color: var(--text-hi);
}

.meta {
  margin: 0 0 20px;
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 6px 20px;
  font-size: 12px;
  color: var(--text-lo);
}

.project {
  font-size: 14px;
  font-weight: 500;
  color: var(--text-hi);
}

.mono {
  font-family: var(--font-mono);
  font-variant-numeric: tabular-nums;
}

.live {
  display: inline-flex;
  align-items: center;
  gap: 7px;
}

/* ポーリングの生存を示す計器 LED */
.led {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  flex: none;
}

.led-ok {
  background: var(--ok);
  box-shadow: 0 0 6px rgba(86, 211, 100, 0.8);
  animation: led-pulse 2.4s ease-in-out infinite;
}

.led-alert {
  background: var(--alert);
  box-shadow: 0 0 6px rgba(255, 123, 114, 0.8);
  animation: led-pulse 0.8s ease-in-out infinite;
}

@keyframes led-pulse {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.35;
  }
}

.degraded {
  color: var(--dev);
}

.banner {
  margin: 0 0 18px;
  padding: 10px 16px;
  border: 1px solid rgba(255, 123, 114, 0.45);
  border-left: 3px solid var(--alert);
  border-radius: 8px;
  background: var(--alert-dim);
  color: #ffc9c4;
  font-size: 13px;
}

.loading {
  color: var(--text-lo);
  font-size: 13px;
}

.cursor {
  margin-left: 2px;
  color: var(--rev);
  animation: cursor-blink 1s steps(1) infinite;
}

@keyframes cursor-blink {
  0%,
  49% {
    opacity: 1;
  }
  50%,
  100% {
    opacity: 0;
  }
}
</style>
