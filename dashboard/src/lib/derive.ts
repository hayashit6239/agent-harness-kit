/**
 * 台帳 → 盤面 + キャラ状態の導出 (純関数。vitest の unit test 対象)。
 *
 * 対応表と合成規則は issue #9「レビュー反映 — 決定事項 (2026-07-08)」
 * および「増分レビュー反映 — 決定事項 (2026-07-08 set2)」が正:
 *   規則 1 (step 内): pr.status != null の step は PR フェーズの信号のみ採用する
 *     (PR フェーズが始まった step では PR 側の信号を現在地として優先する —
 *      issue 側の残タスクは盤面で可視。follow-up 型 step の issue 残ボールは意図的除外)
 *   規則 2 (キャラ状態): 全 step の信号を 作業中 > 待ち仕事あり > idle の優先順位で 1 状態に畳む
 *   規則 3 (祝い): ready for merge はキャラ信号ではなく舞台全体の演出フラグ (キャラ状態と直交)
 * 未知 status は unknown として信号に数えず警告を返す (fail-soft)。
 */
import type { Ledger } from '../types';

export type CharacterId = 'developer' | 'reviewer';
export type CharacterState = 'working' | 'waiting' | 'idle';
export type Phase = 'issue' | 'pr';

export interface Signal {
  character: CharacterId;
  kind: 'working' | 'waiting';
  /** 画面表示用の補足 (対応表の注記) */
  label: string;
}

/**
 * issue フェーズ (schema issueStatus の非 null 全 7 値) → キャラ信号。
 * null 信号 = キャラへの信号なし。schema enum との網羅一致は derive.test.ts が assert する。
 */
export const ISSUE_SIGNALS: Readonly<Record<string, Readonly<Signal> | null>> = {
  'created issue': { character: 'reviewer', kind: 'waiting', label: 'レビュー待ち' },
  'starting review': { character: 'reviewer', kind: 'working', label: 'レビュー中' },
  'completed review': { character: 'developer', kind: 'waiting', label: '対応待ち' },
  'ready for implementation': { character: 'developer', kind: 'waiting', label: '実装着手待ち' },
  'starting review work': { character: 'developer', kind: 'working', label: '指摘対応中' },
  'waiting for review': { character: 'reviewer', kind: 'waiting', label: '再レビュー待ち' },
  'closed issue': null, // 終端
};

/**
 * PR フェーズ (schema prStatus の非 null 全 8 値) → キャラ信号。
 * 'ready for merge' はキャラ信号なし (merge は人間の専権) — 祝いは舞台フラグで別扱い (規則 3)。
 */
export const PR_SIGNALS: Readonly<Record<string, Readonly<Signal> | null>> = {
  'implementation-ready': { character: 'developer', kind: 'waiting', label: 'PR 作成待ち' },
  'created pr': { character: 'reviewer', kind: 'waiting', label: 'レビュー待ち' },
  'starting review': { character: 'reviewer', kind: 'working', label: 'レビュー中' },
  'completed review': { character: 'developer', kind: 'waiting', label: '対応待ち' },
  'ready for merge': null, // 祝い演出 (舞台フラグ)
  'starting review work': { character: 'developer', kind: 'working', label: '指摘対応中' },
  'waiting for review': { character: 'reviewer', kind: 'waiting', label: '再レビュー待ち' },
  'merged pr': null, // 終端
};

export interface PhaseView {
  number: number | null;
  status: string | null;
  githubState: string | null;
  /** status が schema 語彙内か (null は既知扱い)。false なら盤面に警告表示 */
  known: boolean;
}

export interface StepView {
  id: string;
  kind: string | null;
  title: string | null;
  issue: PhaseView;
  pr: PhaseView;
  /** pr.status が 'ready for merge' (祝いフラグの由来 step。行を強調表示) */
  celebrating: boolean;
}

export interface UnknownStatusWarning {
  stepId: string;
  phase: Phase;
  status: string;
}

export interface CharacterView {
  state: CharacterState;
  /** 信号の由来 (例: "P8 pr: completed review (対応待ち)")。手動確認と画面表示用 */
  tasks: string[];
}

export interface BoardState {
  steps: StepView[];
  characters: Record<CharacterId, CharacterView>;
  /** 規則 3: ready for merge の step が 1 つでもあれば true (キャラ状態と直交) */
  celebrate: boolean;
  warnings: UnknownStatusWarning[];
}

interface Lookup {
  signal: Readonly<Signal> | null;
  known: boolean;
}

function lookupSignal(phase: Phase, status: string | null): Lookup {
  if (status === null) return { signal: null, known: true };
  const table = phase === 'issue' ? ISSUE_SIGNALS : PR_SIGNALS;
  if (!(status in table)) return { signal: null, known: false }; // 未知 status: 信号に数えない (fail-soft)
  return { signal: table[status], known: true };
}

export function derive(ledger: Ledger): BoardState {
  const warnings: UnknownStatusWarning[] = [];
  const characters: Record<CharacterId, CharacterView> = {
    developer: { state: 'idle', tasks: [] },
    reviewer: { state: 'idle', tasks: [] },
  };
  let celebrate = false;

  const applySignal = (signal: Readonly<Signal>, stepId: string, phase: Phase, status: string): void => {
    const character = characters[signal.character];
    // 規則 2: 作業中 > 待ち仕事あり > idle (出現順に依存しない畳み込み)
    if (signal.kind === 'working') {
      character.state = 'working';
    } else if (character.state !== 'working') {
      character.state = 'waiting';
    }
    character.tasks.push(`${stepId} ${phase}: ${status} (${signal.label})`);
  };

  const steps: StepView[] = ledger.steps.map((step) => {
    const issue = lookupSignal('issue', step.issue.status);
    const pr = lookupSignal('pr', step.pr.status);
    // 警告は信号の採否 (規則 1) と独立 — 盤面表示のための fail-soft 通知
    if (!issue.known) warnings.push({ stepId: step.id, phase: 'issue', status: step.issue.status as string });
    if (!pr.known) warnings.push({ stepId: step.id, phase: 'pr', status: step.pr.status as string });

    const celebrating = step.pr.status === 'ready for merge';
    if (celebrating) celebrate = true;

    // 規則 1: pr.status != null の step は PR フェーズの信号のみ採用。
    // pr.status が未知語でも「PR フェーズが始まっている」事実は変わらないため issue 信号は採用しない。
    if (step.pr.status !== null) {
      if (pr.signal) applySignal(pr.signal, step.id, 'pr', step.pr.status);
    } else if (issue.signal && step.issue.status !== null) {
      applySignal(issue.signal, step.id, 'issue', step.issue.status);
    }

    return {
      id: step.id,
      kind: step.kind ?? null,
      title: step.title ?? null,
      issue: { number: step.issue.number, status: step.issue.status, githubState: step.issue.githubState, known: issue.known },
      pr: { number: step.pr.number, status: step.pr.status, githubState: step.pr.githubState, known: pr.known },
      celebrating,
    };
  });

  return { steps, characters, celebrate, warnings };
}

/* ------------------------------------------------------------------ */
/* カンバン盤面の導出                                                    */
/* ------------------------------------------------------------------ */

/**
 * カンバンの列順 (= status の遷移順)。
 * 対応表 (ISSUE_SIGNALS / PR_SIGNALS) のキー宣言順が schema enum の遷移順と一致している
 * ことを derive.test.ts が assert する (語彙の重複定義を避け、キー順を列順の単一源にする)。
 * 先頭の null は「未着手」列。
 */
export const ISSUE_COLUMN_ORDER: ReadonlyArray<string | null> = [null, ...Object.keys(ISSUE_SIGNALS)];
export const PR_COLUMN_ORDER: ReadonlyArray<string | null> = [null, ...Object.keys(PR_SIGNALS)];

/** 終端 status (レーン最終列。画面では控えめな見た目にする) */
const TERMINAL_STATUSES: ReadonlySet<string> = new Set(['closed issue', 'merged pr']);

/**
 * 列の種別:
 *   flow     = 遷移順の通常列 (空でも表示して流れを見せる)
 *   terminal = 終端列 (closed issue / merged pr。控えめ表示)
 *   unknown  = 未知 status の警告列 (レーン右端。fail-soft の可視化)
 */
export type KanbanColumnKind = 'flow' | 'terminal' | 'unknown';

export interface KanbanCard {
  stepId: string;
  kind: string | null;
  title: string | null;
  /** このレーンで表示する GitHub 番号 (issue レーン = issue.number / PR レーン = pr.number) */
  number: number | null;
  /** この step のレーン上の生 status (unknown 列でどの語だったかを表示するために持つ) */
  status: string | null;
}

export interface KanbanColumn {
  /** 列を定める status (null = 未着手列。unknown 列も null で kind で区別) */
  status: string | null;
  kind: KanbanColumnKind;
  cards: KanbanCard[];
}

export interface KanbanLane {
  phase: Phase;
  /** 遷移順の列 + 右端の unknown 列 (空でも常に含む。表示の間引きは画面側の裁量) */
  columns: KanbanColumn[];
}

export interface KanbanView {
  issue: KanbanLane;
  pr: KanbanLane;
}

function buildLane(phase: Phase, order: ReadonlyArray<string | null>, steps: StepView[]): KanbanLane {
  const columns: KanbanColumn[] = order.map((status) => ({
    status,
    kind: status !== null && TERMINAL_STATUSES.has(status) ? 'terminal' : 'flow',
    cards: [],
  }));
  const unknown: KanbanColumn = { status: null, kind: 'unknown', cards: [] };
  const byStatus = new Map<string | null, KanbanColumn>(columns.map((c) => [c.status, c]));

  for (const step of steps) {
    const view = phase === 'issue' ? step.issue : step.pr;
    const card: KanbanCard = {
      stepId: step.id,
      kind: step.kind,
      title: step.title,
      number: view.number,
      status: view.status,
    };
    // 未知 status (known=false) は unknown 列へ。既知なのに列が無いケースも防御的に unknown 行き
    const column = view.known ? byStatus.get(view.status) : undefined;
    (column ?? unknown).cards.push(card);
  }
  return { phase, columns: [...columns, unknown] };
}

/**
 * StepView[] → カンバン 2 レーン (issue フェーズ / PR フェーズ)。
 * 各 step は両レーンに 1 枚ずつ現れる (issue レーンは issue.status の列、PR レーンは pr.status の列)。
 * 列内のカード順は台帳の steps 順のまま。
 */
export function deriveKanban(steps: StepView[]): KanbanView {
  return {
    issue: buildLane('issue', ISSUE_COLUMN_ORDER, steps),
    pr: buildLane('pr', PR_COLUMN_ORDER, steps),
  };
}
