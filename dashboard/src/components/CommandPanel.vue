<script setup lang="ts">
import { ref } from 'vue';

/**
 * 左コマンド送信パネル — プレースホルダ枠のみ (issue #25 レイヤ6・DESIGN.md 5.2)。
 *
 * 本 issue のスコープは「開閉可能 (collapsible) な枠」まで。
 * 実コマンド送信ロジック (宛先解決・配達キュー・POST /api/instruct 相当) は
 * 実装しない — follow-up の別 issue で扱う (issue #25 スコープ外の明記)。
 * そのためフォーム部品はすべて disabled のモック表示。
 */

// 既定は閉 (issue #97 DoD ②)。開くと細い開閉ストリップから指示センター本体が展開する。
const open = ref(false);

function toggle(): void {
  open.value = !open.value;
}
</script>

<template>
  <section class="panel" :class="{ 'is-closed': !open }">
    <!-- 開閉トグル (DoD ④: 開閉トグルが動作すること) -->
    <button
      type="button"
      class="toggle"
      :aria-expanded="open"
      aria-controls="command-panel-body"
      @click="toggle"
    >
      <span class="toggle-icon" aria-hidden="true">{{ open ? '⟨' : '⟩' }}</span>
      <span v-if="!open" class="toggle-label">🎛 指示センター</span>
    </button>

    <div v-if="open" id="command-panel-body" class="body">
      <h2 class="title">🎛 指示センター</h2>
      <p class="placeholder-note">
        ここからキャラ (セッション) へ指示を送れるようになる予定です。
        <strong>送信機能は follow-up の別 issue で実装</strong> — 本パネルは枠のみ。
      </p>
      <!-- 以下はプレースホルダのモック (すべて操作不能・DESIGN.md 5.2 の将来像) -->
      <label class="field-label" for="command-target">宛先</label>
      <select id="command-target" class="target" disabled>
        <option>宛先を選択 (準備中)</option>
      </select>
      <label class="field-label" for="command-text">指示</label>
      <textarea
        id="command-text"
        class="text"
        disabled
        placeholder="例: キリのいいところで進捗をまとめてコミットして、残タスクを報告して"
      ></textarea>
      <button type="button" class="send" disabled>投函する (準備中)</button>
      <p class="help">届くタイミングや配達状態の表示も送信機能と同時に実装予定です。</p>
    </div>
  </section>
</template>

<style scoped>
.panel {
  position: relative;
  width: 250px;
  padding: 14px 16px 16px 40px;
  border: 1px solid var(--line);
  border-radius: 14px;
  background: var(--tray);
  box-shadow: inset 0 2px 12px rgba(0, 0, 0, 0.45);
  transition: width 0.25s ease;
}

.panel.is-closed {
  width: 44px;
  padding: 14px 0;
  min-height: 180px;
}

.toggle {
  position: absolute;
  top: 10px;
  left: 6px;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 10px;
  padding: 6px 4px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--panel);
  color: var(--text-lo);
  font-size: 12px;
  cursor: pointer;
}

.toggle:hover {
  color: var(--text-hi);
  border-color: var(--rev);
}

.toggle-icon {
  font-family: var(--font-mono);
  font-weight: 700;
}

/* 閉時: 縦書きラベルで何のレールかを示す */
.toggle-label {
  writing-mode: vertical-rl;
  font-size: 11px;
  letter-spacing: 0.14em;
  white-space: nowrap;
}

.title {
  margin: 0 0 8px;
  font-family: var(--font-mono);
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0.18em;
  color: var(--text-lo);
}

.placeholder-note {
  margin: 0 0 12px;
  padding: 8px 10px;
  border: 1px dashed var(--line);
  border-radius: 8px;
  font-size: 11px;
  line-height: 1.6;
  color: var(--text-lo);
}

.placeholder-note strong {
  color: var(--dev);
}

.field-label {
  display: block;
  margin: 0 0 4px;
  font-size: 11px;
  color: var(--text-lo);
}

.target,
.text {
  width: 100%;
  margin-bottom: 10px;
  padding: 7px 9px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--panel);
  color: var(--text-lo);
  font-family: var(--font-sans);
  font-size: 12px;
}

.text {
  height: 72px;
  resize: none;
}

.target:disabled,
.text:disabled,
.send:disabled {
  opacity: 0.55;
  cursor: not-allowed;
}

.send {
  width: 100%;
  padding: 9px 0;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: var(--panel);
  color: var(--text-lo);
  font-size: 13px;
  font-weight: 700;
}

.help {
  margin: 8px 0 0;
  font-size: 10px;
  line-height: 1.6;
  color: var(--text-lo);
}
</style>
