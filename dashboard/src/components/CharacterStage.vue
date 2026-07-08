<script setup lang="ts">
import { computed } from 'vue';
import type { CharacterId, CharacterState, CharacterView } from '../lib/derive';

const props = defineProps<{
  characters: Record<CharacterId, CharacterView>;
  celebrate: boolean;
}>();

/** 画面上の表示名は「main developer / pr reviewer」、コード上の識別子は developer / reviewer (issue #9 決定事項) */
const CHARACTER_META: Record<CharacterId, { label: string; face: string; workingNote: string }> = {
  developer: { label: 'main developer', face: '🧑‍💻', workingNote: 'カタカタ実装・修正中…' },
  reviewer: { label: 'pr reviewer', face: '🕵️', workingNote: 'じっくりレビュー中…' },
};

const STATE_LABEL: Record<CharacterState, string> = {
  working: '作業中',
  waiting: '待ち仕事あり',
  idle: '待機中',
};

const cast = computed(() =>
  (['developer', 'reviewer'] as const).map((id) => ({
    id,
    meta: CHARACTER_META[id],
    view: props.characters[id],
  })),
);

/** 祝い紙吹雪 (index から決定論的に散らす) */
function pieceStyle(i: number): Record<string, string> {
  const colors = ['#f94144', '#f8961e', '#f9c74f', '#90be6d', '#43aa8b', '#577590', '#9b5de5'];
  return {
    left: `${(i * 37) % 100}%`,
    backgroundColor: colors[i % colors.length]!,
    animationDelay: `${(i % 8) * 0.35}s`,
    animationDuration: `${2.4 + (i % 5) * 0.3}s`,
  };
}
</script>

<template>
  <section class="stage" :class="{ 'is-celebrating': celebrate }">
    <div v-if="celebrate" class="confetti" aria-hidden="true">
      <span v-for="i in 28" :key="i" class="piece" :style="pieceStyle(i)"></span>
    </div>
    <div v-if="celebrate" class="celebrate-banner">🎉 ready for merge — merge は人間の出番です!</div>

    <div class="cast">
      <article
        v-for="c in cast"
        :key="c.id"
        class="character"
        :class="`state-${c.view.state}`"
        :data-character="c.id"
      >
        <div class="scene">
          <!-- 作業中: キャラごとの動き (developer = タイピング / reviewer = 虫眼鏡で走査) -->
          <span class="face">{{ c.meta.face }}</span>
          <span v-if="c.id === 'developer' && c.view.state === 'working'" class="prop typing" aria-hidden="true">
            ⌨️<i>.</i><i>.</i><i>.</i>
          </span>
          <span v-if="c.id === 'reviewer' && c.view.state === 'working'" class="prop scan" aria-hidden="true">
            <span class="paper">📄</span><span class="lens">🔍</span>
          </span>
          <span v-if="c.view.state === 'waiting'" class="prop inbox" aria-hidden="true">📬</span>
          <span v-if="c.view.state === 'idle'" class="prop zzz" aria-hidden="true">💤</span>
        </div>

        <h2 class="name">{{ c.meta.label }}</h2>
        <p class="state-label" :class="`pill-${c.view.state}`">{{ STATE_LABEL[c.view.state] }}</p>
        <p v-if="c.view.state === 'working'" class="note">{{ c.meta.workingNote }}</p>

        <ul v-if="c.view.tasks.length" class="tasks">
          <li v-for="task in c.view.tasks" :key="task">{{ task }}</li>
        </ul>
        <p v-else class="tasks-empty">割当なし</p>
      </article>
    </div>
  </section>
</template>

<style scoped>
.stage {
  position: relative;
  padding: 16px;
  border: 1px solid #d0d7de;
  border-radius: 10px;
  background: linear-gradient(180deg, #ffffff 0%, #f0f4f8 100%);
  overflow: hidden;
}

.stage.is-celebrating {
  border-color: #d4a72c;
  background: linear-gradient(180deg, #fffdf5 0%, #fff3d1 100%);
}

.celebrate-banner {
  position: relative;
  z-index: 2;
  margin-bottom: 14px;
  padding: 8px 14px;
  border-radius: 8px;
  background: #ffd867;
  color: #4d3800;
  font-weight: 700;
  text-align: center;
  animation: banner-pop 0.9s ease-in-out infinite alternate;
}

@keyframes banner-pop {
  from { transform: scale(1); }
  to { transform: scale(1.02); }
}

.cast {
  position: relative;
  z-index: 2;
  display: grid;
  /* 側柱 (右カラム) では縦積み。狭い側柱でも 2 キャラが常に見える */
  grid-template-columns: 1fr;
  gap: 12px;
}

.character {
  padding: 16px;
  border: 1px solid #d8dee4;
  border-radius: 10px;
  background: #ffffff;
  text-align: center;
}

.scene {
  position: relative;
  height: 84px;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 10px;
}

.face {
  font-size: 52px;
  display: inline-block;
}

/* --- 作業中: それとわかる動き --- */
.state-working .face {
  animation: work-bob 0.4s ease-in-out infinite alternate;
}

@keyframes work-bob {
  from { transform: translateY(0) rotate(-2deg); }
  to { transform: translateY(-6px) rotate(2deg); }
}

/* developer: タイピングの点滅ドット */
.typing {
  font-size: 26px;
}

.typing i {
  font-style: normal;
  font-weight: 700;
  color: #0969da;
  animation: type-dot 0.9s steps(1) infinite;
}

.typing i:nth-child(2) {
  animation-delay: 0.3s;
}

.typing i:nth-child(3) {
  animation-delay: 0.6s;
}

@keyframes type-dot {
  0%, 40% { opacity: 1; }
  50%, 100% { opacity: 0.15; }
}

/* reviewer: 書類の上を虫眼鏡が走査 */
.scan {
  position: relative;
  width: 64px;
  height: 48px;
  display: inline-block;
}

.scan .paper {
  position: absolute;
  left: 14px;
  top: 6px;
  font-size: 34px;
}

.scan .lens {
  position: absolute;
  top: 12px;
  left: 0;
  font-size: 26px;
  animation: lens-sweep 1.3s ease-in-out infinite alternate;
}

@keyframes lens-sweep {
  from { transform: translate(0, 0) rotate(-12deg); }
  to { transform: translate(28px, 8px) rotate(12deg); }
}

/* --- 待ち仕事あり: 受信箱がぷるぷる --- */
.inbox {
  font-size: 28px;
  animation: inbox-pulse 1.1s ease-in-out infinite;
}

@keyframes inbox-pulse {
  0%, 100% { transform: scale(1); }
  50% { transform: scale(1.2) rotate(-6deg); }
}

.state-waiting .face {
  animation: waiting-breath 2.4s ease-in-out infinite;
}

@keyframes waiting-breath {
  0%, 100% { transform: translateY(0); }
  50% { transform: translateY(-2px); }
}

/* --- idle: グレーアウト + zzz --- */
.state-idle .face {
  filter: grayscale(0.9);
  opacity: 0.55;
}

.zzz {
  font-size: 22px;
  animation: zzz-float 2.6s ease-in-out infinite;
}

@keyframes zzz-float {
  0% { transform: translateY(4px); opacity: 0.25; }
  50% { transform: translateY(-4px); opacity: 0.85; }
  100% { transform: translateY(-10px); opacity: 0; }
}

.name {
  margin: 6px 0 4px;
  font-size: 15px;
}

.state-label {
  display: inline-block;
  margin: 0;
  padding: 2px 12px;
  border-radius: 12px;
  font-size: 13px;
  font-weight: 700;
}

.pill-working {
  background: #ddf4ff;
  color: #0550ae;
}

.pill-waiting {
  background: #fff8c5;
  color: #7d4e00;
}

.pill-idle {
  background: #eaeef2;
  color: #57606a;
}

.note {
  margin: 6px 0 0;
  font-size: 12px;
  color: #57606a;
}

.tasks {
  margin: 10px 0 0;
  padding: 0;
  list-style: none;
  font-size: 12px;
  color: #57606a;
  text-align: left;
}

.tasks li {
  padding: 2px 8px;
  border-left: 3px solid #d0d7de;
  margin-bottom: 2px;
}

.tasks-empty {
  margin: 10px 0 0;
  font-size: 12px;
  color: #8c959f;
}

/* --- 祝い: 紙吹雪 --- */
.confetti {
  position: absolute;
  inset: 0;
  z-index: 1;
  pointer-events: none;
}

.piece {
  position: absolute;
  top: -12px;
  width: 8px;
  height: 12px;
  border-radius: 2px;
  opacity: 0;
  animation-name: confetti-fall;
  animation-timing-function: linear;
  animation-iteration-count: infinite;
}

@keyframes confetti-fall {
  0% { transform: translateY(-10%) rotate(0deg); opacity: 0; }
  10% { opacity: 0.95; }
  100% { transform: translateY(420px) rotate(680deg); opacity: 0.1; }
}
</style>
