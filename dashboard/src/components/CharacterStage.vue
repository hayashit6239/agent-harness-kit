<script setup lang="ts">
import { computed } from 'vue';
import type { CharacterId, CharacterState, CharacterView } from '../lib/derive';

/**
 * ピクセルオフィスステージ (issue #25 レイヤ4・DESIGN.md 第6章)。
 *
 * 方式 = 「1 枚絵の背景 + DOM オーバーレイ」(6.1):
 *   レイヤ0 背景 / レイヤ1 キャラスプライト / レイヤ2 名前チップ (キャラ下端追従) /
 *   レイヤ3 状態吹き出し (キャラ上端追従) / z-order は y 座標昇順 (下ほど手前)。
 * 座標系 (6.2) = 論理座標 (STAGE 620×420) を % に射影し、外側コンテナに追従してスケール。
 * 素材 (6.3 段階戦略 = 選択肢 C1) = CSS + 絵文字プレースホルダで先に組む。
 *   生成素材が出来たら .scene の背景を office_bg.png 1 枚絵へ、.sprite の中身を
 *   透過 PNG (<img image-rendering: pixelated>) へ差し替える — 座標系・チップ・吹き出しの
 *   ロジックは素材と独立に完成している (差し替えてもこのファイルの script は不変)。
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

/** 論理座標系 (DESIGN.md 6.2)。背景素材を差し替えてもこの系で座標を維持する */
const STAGE = { w: 620, h: 420 } as const;

interface Spot {
  x: number;
  y: number;
}

/**
 * オフィスの席割り (office_config 相当の宣言 — DESIGN.md 6.2)。
 * state → スポットの対応が「BoardState 由来の配置」の実体:
 *   working = 自席 (developer は制作デスク / reviewer はレビュー室のテーブル)
 *   waiting = 受信箱前 (待ち仕事を取りに行く)
 *   idle    = 休憩ラウンジのソファ (待機の長い社員はラウンジへ — 7 章の挙動)
 */
const SPOTS: Record<CharacterId, Record<CharacterState, Spot>> = {
  developer: {
    working: { x: 148, y: 218 },
    waiting: { x: 252, y: 168 },
    idle: { x: 448, y: 352 },
  },
  reviewer: {
    working: { x: 468, y: 178 },
    waiting: { x: 322, y: 168 },
    idle: { x: 548, y: 352 },
  },
};

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

const STATE_ICON: Record<CharacterState, string> = {
  working: '💭',
  waiting: '📬',
  idle: '💤',
};

const actors = computed(() =>
  (['developer', 'reviewer'] as const).map((id) => {
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
      <div class="scene" role="img" aria-label="AI オフィスの俯瞰図。developer と reviewer の稼働状況をキャラクターで表示">
        <!-- レイヤ0: 背景 (CSS プレースホルダ。後で office_bg.png 1 枚絵へ差替え — 6.3) -->
        <div class="bg wall" aria-hidden="true">
          <span class="window w1"></span>
          <span class="sign">AGENT HARNESS OFFICE</span>
          <span class="window w2"></span>
          <span class="clock">🕐</span>
        </div>
        <div class="bg room-works" aria-hidden="true">
          <span class="room-label">🏷 制作デスク</span>
          <span class="desk d1">🖥️</span>
          <span class="desk d2">🖥️</span>
          <span class="inbox-obj">📥</span>
          <span class="plant p1">🪴</span>
        </div>
        <div class="bg room-meeting" aria-hidden="true">
          <span class="room-label">🏷 レビュー室</span>
          <span class="table"></span>
        </div>
        <div class="bg room-lounge" aria-hidden="true">
          <span class="room-label">🏷 休憩ラウンジ</span>
          <span class="sofa s1"></span>
          <span class="sofa s2"></span>
          <span class="plant p2">🪴</span>
        </div>

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
          <!-- レイヤ1: スプライト (絵文字プレースホルダ。生成スプライトが出来たら透過 PNG の <img> へ差替え — 6.3) -->
          <div class="sprite">
            <span class="face">{{ a.meta.face }}</span>
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
          {{ a.meta.face }} {{ a.meta.label }}
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
 * (--px-* はステージ専用トークン — style.css のグローバルには足さない)
 */
.stage {
  --px-brick: #7c4b2a;
  --px-brick-shadow: #5e3820;
  --px-floor: #a9793f;
  --px-floor-dark: #8c6132;
  --px-wood-dark: #4a3018;
  --px-desk: #6e4623;
  --px-meeting-floor: #24443c;
  --px-meeting-glass: #2f6053;
  --px-lounge-sofa: #a63e30;
  --px-check-light: #e9e0ce;
  --px-check-dark: #201812;
  --px-window: #f5d98a;
  --stage-bezel: #17110b;
  --bubble-bg: rgba(22, 15, 9, 0.92);
  --bubble-name: #e4b96a;
  --alert-bg: #4e1712;
  --alert-border: #c3372e;
  --alert-title: #f2c063;

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

/* --- シーン: 論理座標 620×420 の窓。% 配置でコンテナ幅に追従スケール (6.2) --- */
.scene {
  position: relative;
  aspect-ratio: 620 / 420;
  width: 100%;
  overflow: hidden;
  border-radius: 8px;
  /* 床 (レイヤ0 の地): 木の床板 + 継ぎ目。office_bg.png へ差替えたらここを background-image に */
  background: repeating-linear-gradient(90deg, var(--px-floor-dark) 0 2px, var(--px-floor) 2px 42px);
}

.bg {
  position: absolute;
  z-index: 1;
}

/* レンガ壁 (上帯): 目地の横線 + 縦継ぎ目の簡略パターン */
.wall {
  inset: 0 0 auto 0;
  height: 16%;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 12px;
  background:
    repeating-linear-gradient(0deg, rgba(0, 0, 0, 0.2) 0 2px, transparent 2px 11px),
    repeating-linear-gradient(90deg, var(--px-brick-shadow) 0 2px, var(--px-brick) 2px 26px);
  border-bottom: 3px solid var(--px-wood-dark);
}

.sign {
  padding: 2px 10px;
  border: 2px solid #2e1d0c;
  border-radius: 3px;
  background: var(--px-wood-dark);
  color: var(--px-window);
  font-family: var(--font-mono);
  font-size: 10px;
  font-weight: 700;
  letter-spacing: 0.18em;
  white-space: nowrap;
}

.window {
  width: 9%;
  height: 55%;
  border: 3px solid var(--px-wood-dark);
  border-radius: 2px;
  background: var(--px-window);
  box-shadow: inset 0 0 8px rgba(255, 178, 64, 0.75);
}

.clock {
  font-size: 13px;
}

/* 制作デスク (左 works エリア) */
.room-works {
  left: 3%;
  top: 22%;
  width: 44%;
  height: 42%;
}

.desk {
  position: absolute;
  width: 34%;
  height: 26%;
  border-radius: 3px;
  background: var(--px-desk);
  border: 2px solid var(--px-wood-dark);
  box-shadow: 0 4px 0 rgba(0, 0, 0, 0.25);
  font-size: 15px;
  display: flex;
  align-items: center;
  justify-content: center;
}

.desk.d1 {
  left: 6%;
  top: 30%;
}

.desk.d2 {
  left: 52%;
  top: 30%;
}

.inbox-obj {
  position: absolute;
  left: 76%;
  top: -8%;
  font-size: 15px;
}

/* レビュー室 (右上・ティール床 + ガラスパーティション) */
.room-meeting {
  right: 2.5%;
  top: 20%;
  width: 33%;
  height: 27%;
  border: 2px solid var(--px-meeting-glass);
  border-radius: 4px;
  background:
    repeating-linear-gradient(45deg, rgba(255, 255, 255, 0.03) 0 6px, transparent 6px 12px),
    var(--px-meeting-floor);
}

.table {
  position: absolute;
  left: 50%;
  top: 58%;
  width: 56%;
  height: 34%;
  transform: translate(-50%, -50%);
  border-radius: 50%;
  background: var(--px-desk);
  border: 3px solid var(--px-wood-dark);
}

/* 休憩ラウンジ (右下・市松床 + 赤ソファ) */
.room-lounge {
  right: 2.5%;
  bottom: 3%;
  width: 40%;
  height: 30%;
  border: 2px solid var(--px-wood-dark);
  border-radius: 4px;
  background: repeating-conic-gradient(var(--px-check-light) 0% 25%, var(--px-check-dark) 0% 50%) 0 0 / 22px 22px;
}

.sofa {
  position: absolute;
  bottom: 12%;
  width: 34%;
  height: 30%;
  border-radius: 5px 5px 3px 3px;
  background: var(--px-lounge-sofa);
  border: 2px solid #6e2118;
  box-shadow: inset 0 5px 0 rgba(255, 255, 255, 0.12);
}

.sofa.s1 {
  left: 8%;
}

.sofa.s2 {
  right: 8%;
}

.plant {
  position: absolute;
  font-size: 14px;
}

.plant.p1 {
  left: -6%;
  top: 70%;
}

.plant.p2 {
  right: 2%;
  top: -18%;
}

.room-label {
  position: absolute;
  top: -9px;
  left: 6px;
  padding: 1px 6px;
  border-radius: 3px;
  background: var(--bubble-bg);
  color: #f0e6d2;
  font-family: var(--font-mono);
  font-size: 9px;
  white-space: nowrap;
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
  font-size: 26px;
  line-height: 1;
  display: inline-block;
}

.shadow {
  position: absolute;
  bottom: -3px;
  left: 50%;
  transform: translateX(-50%);
  width: 26px;
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

/* レイヤ3: 状態吹き出し (キャラ上端・下向きしっぽ — 5.8) */
.bubble {
  position: absolute;
  bottom: 36px;
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

.assign[data-character='developer'] {
  --role: var(--dev);
  --role-dim: var(--dev-dim);
}

.assign[data-character='reviewer'] {
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
