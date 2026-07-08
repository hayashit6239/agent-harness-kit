import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import type { Ledger, Step } from '../types';
import {
  derive,
  deriveKanban,
  ISSUE_COLUMN_ORDER,
  ISSUE_SIGNALS,
  PR_COLUMN_ORDER,
  PR_SIGNALS,
  statusOwner,
  type KanbanColumn,
} from './derive';

// status 語彙の単一源 (.harness/plan-progress.schema.json) を読む —
// enum が増えたら対応表の網羅 assert が落ちる閉ループ (issue #9 決定事項)
const schemaPath = fileURLToPath(new URL('../../../.harness/plan-progress.schema.json', import.meta.url));
const schema = JSON.parse(readFileSync(schemaPath, 'utf-8')) as {
  definitions: { issueStatus: { enum: (string | null)[] }; prStatus: { enum: (string | null)[] } };
};
const issueEnum = schema.definitions.issueStatus.enum;
const prEnum = schema.definitions.prStatus.enum;

function step(id: string, issueStatus: string | null, prStatus: string | null): Step {
  // githubState は台帳の整合規則 (終端 status ⇔ closed/merged) と食い違わない値を入れる
  return {
    id,
    issue: {
      number: 1,
      status: issueStatus,
      githubState: issueStatus === null ? null : issueStatus === 'closed issue' ? 'closed' : 'open',
    },
    pr: {
      number: 2,
      status: prStatus,
      githubState: prStatus === null ? null : prStatus === 'merged pr' ? 'merged' : 'open',
    },
  };
}

function ledgerOf(steps: Step[]): Ledger {
  return {
    updatedAt: '2026-07-08',
    evidence: { build: null, test: 'true', lint: null, done: 'true' },
    steps,
  };
}

describe('schema 追従 (enum 全値が対応表に割当済み — 閉ループ)', () => {
  it('issueStatus enum の非 null 全値と ISSUE_SIGNALS のキーが一致する', () => {
    const nonNull = issueEnum.filter((v): v is string => v !== null);
    expect(Object.keys(ISSUE_SIGNALS).sort()).toEqual([...nonNull].sort());
  });

  it('prStatus enum の非 null 全値と PR_SIGNALS のキーが一致する', () => {
    const nonNull = prEnum.filter((v): v is string => v !== null);
    expect(Object.keys(PR_SIGNALS).sort()).toEqual([...nonNull].sort());
  });

  it('null は両フェーズの enum に含まれ、derive は信号なしとして処理する (割当済み)', () => {
    expect(issueEnum).toContain(null);
    expect(prEnum).toContain(null);
    const board = derive(ledgerOf([step('S', null, null)]));
    expect(board.characters.developer.state).toBe('idle');
    expect(board.characters.reviewer.state).toBe('idle');
    expect(board.warnings).toEqual([]);
  });
});

describe('対応表 — issue フェーズ単独 (pr.status = null) のキャラ信号', () => {
  it.each([
    [null, 'idle', 'idle'],
    ['created issue', 'idle', 'waiting'],
    ['starting review', 'idle', 'working'],
    ['completed review', 'waiting', 'idle'],
    ['ready for implementation', 'waiting', 'idle'],
    ['starting review work', 'working', 'idle'],
    ['waiting for review', 'idle', 'waiting'],
    ['closed issue', 'idle', 'idle'],
  ] as const)('issue.status=%s → developer=%s / reviewer=%s', (status, developer, reviewer) => {
    const board = derive(ledgerOf([step('S', status, null)]));
    expect(board.characters.developer.state).toBe(developer);
    expect(board.characters.reviewer.state).toBe(reviewer);
    expect(board.celebrate).toBe(false);
    expect(board.warnings).toEqual([]);
  });
});

describe('対応表 — PR フェーズのキャラ信号', () => {
  it.each([
    ['implementation-ready', 'waiting', 'idle', false],
    ['created pr', 'idle', 'waiting', false],
    ['starting review', 'idle', 'working', false],
    ['completed review', 'waiting', 'idle', false],
    ['ready for merge', 'idle', 'idle', true],
    ['starting review work', 'working', 'idle', false],
    ['waiting for review', 'idle', 'waiting', false],
    ['merged pr', 'idle', 'idle', false],
  ] as const)('pr.status=%s → developer=%s / reviewer=%s / celebrate=%s', (status, developer, reviewer, celebrate) => {
    const board = derive(ledgerOf([step('S', null, status)]));
    expect(board.characters.developer.state).toBe(developer);
    expect(board.characters.reviewer.state).toBe(reviewer);
    expect(board.celebrate).toBe(celebrate);
    expect(board.warnings).toEqual([]);
  });
});

describe('合成規則 1 — pr.status != null の step は PR フェーズの信号のみ採用', () => {
  it('issue の working 信号は pr が進行中なら採用されない', () => {
    // issue: starting review work (developer working) / pr: created pr (reviewer waiting)
    const board = derive(ledgerOf([step('S', 'starting review work', 'created pr')]));
    expect(board.characters.developer.state).toBe('idle');
    expect(board.characters.reviewer.state).toBe('waiting');
  });

  it('follow-up 型 step (現台帳 P8 相当): issue 側の残ボールはキャラ信号に出さない (意図的除外)', () => {
    // issue: created issue (reviewer 待ちに見える) / pr: completed review (developer 対応待ち)
    const board = derive(ledgerOf([step('P8', 'created issue', 'completed review')]));
    expect(board.characters.developer.state).toBe('waiting');
    expect(board.characters.reviewer.state).toBe('idle');
  });

  it('PR 終端 (merged pr) では issue 側の陳腐化した信号も立たない', () => {
    const board = derive(ledgerOf([step('S', 'ready for implementation', 'merged pr')]));
    expect(board.characters.developer.state).toBe('idle');
    expect(board.characters.reviewer.state).toBe('idle');
  });

  it('pr.status が未知語 (非 null) でも issue 信号は採用しない (PR フェーズ開始の事実は変わらない)', () => {
    const board = derive(ledgerOf([step('S', 'starting review', 'not-a-status')]));
    expect(board.characters.developer.state).toBe('idle');
    expect(board.characters.reviewer.state).toBe('idle');
    expect(board.warnings).toEqual([{ stepId: 'S', phase: 'pr', kind: 'unknown-status', status: 'not-a-status' }]);
  });

  it('盤面表示は両フェーズとも出す (信号の採否と独立)', () => {
    const board = derive(ledgerOf([step('S', 'created issue', 'completed review')]));
    expect(board.steps[0]!.issue.status).toBe('created issue');
    expect(board.steps[0]!.pr.status).toBe('completed review');
  });
});

describe('合成規則 2 — 作業中 > 待ち仕事あり > idle で 1 状態に畳む', () => {
  it('waiting と working が混在したら working が勝つ', () => {
    const board = derive(
      ledgerOf([step('A', 'created issue', null), step('B', 'starting review', null)]),
    );
    expect(board.characters.reviewer.state).toBe('working');
  });

  it('出現順に依存しない (working が先でも後でも同じ)', () => {
    const board = derive(
      ledgerOf([step('A', 'starting review', null), step('B', 'created issue', null)]),
    );
    expect(board.characters.reviewer.state).toBe('working');
  });

  it('キャラごとに独立して畳む', () => {
    const board = derive(
      ledgerOf([step('A', null, 'starting review work'), step('B', null, 'created pr')]),
    );
    expect(board.characters.developer.state).toBe('working');
    expect(board.characters.reviewer.state).toBe('waiting');
  });

  it('tasks に信号の由来 (stepId + フェーズ + status) が載る', () => {
    const board = derive(ledgerOf([step('P8', null, 'completed review')]));
    expect(board.characters.developer.tasks).toEqual(['P8 pr: completed review (対応待ち)']);
    expect(board.characters.reviewer.tasks).toEqual([]);
  });
});

describe('合成規則 3 — 祝いは舞台全体のフラグでキャラ状態と直交', () => {
  it('ready for merge の step が 1 つでもあれば celebrate=true、該当 step に celebrating が立つ', () => {
    const board = derive(ledgerOf([step('A', null, 'ready for merge'), step('B', null, null)]));
    expect(board.celebrate).toBe(true);
    expect(board.steps[0]!.celebrating).toBe(true);
    expect(board.steps[1]!.celebrating).toBe(false);
  });

  it('祝いとキャラの作業中は同時に成立する (直交)', () => {
    const board = derive(
      ledgerOf([step('A', null, 'ready for merge'), step('B', null, 'starting review work')]),
    );
    expect(board.celebrate).toBe(true);
    expect(board.characters.developer.state).toBe('working');
  });

  it('ready for merge 自体はどのキャラにも信号を出さない (merge は人間の専権)', () => {
    const board = derive(ledgerOf([step('A', null, 'ready for merge')]));
    expect(board.characters.developer.state).toBe('idle');
    expect(board.characters.reviewer.state).toBe('idle');
    expect(board.characters.developer.tasks).toEqual([]);
    expect(board.characters.reviewer.tasks).toEqual([]);
  });
});

describe('fail-soft — 未知 status は信号に数えず警告', () => {
  it('未知の issue status → 警告 + known=false + キャラは idle のまま', () => {
    const board = derive(ledgerOf([step('S', 'brand-new-status', null)]));
    expect(board.warnings).toEqual([{ stepId: 'S', phase: 'issue', kind: 'unknown-status', status: 'brand-new-status' }]);
    expect(board.steps[0]!.issue.known).toBe(false);
    expect(board.characters.developer.state).toBe('idle');
    expect(board.characters.reviewer.state).toBe('idle');
  });

  it('未知の issue status は規則 1 で信号除外される場合も警告される (警告は採否と独立)', () => {
    const board = derive(ledgerOf([step('S', 'weird', 'starting review')]));
    expect(board.warnings).toEqual([{ stepId: 'S', phase: 'issue', kind: 'unknown-status', status: 'weird' }]);
    expect(board.characters.reviewer.state).toBe('working'); // pr 側の既知信号は生きる
  });

  it('既知 status のみなら警告なし・known=true', () => {
    const board = derive(ledgerOf([step('S', 'created issue', 'created pr')]));
    expect(board.warnings).toEqual([]);
    expect(board.steps[0]!.issue.known).toBe(true);
    expect(board.steps[0]!.pr.known).toBe(true);
  });
});

describe('fail-soft — issue/pr オブジェクト欠落 (台帳の手編集) でも描画を壊さない', () => {
  /** 型上は必須の issue/pr を欠いた「壊れた」step を作る (手編集された台帳の再現) */
  function broken(partial: object): Step {
    return partial as Step;
  }

  it('pr オブジェクト欠落: 例外なし + missing-phase 警告 + pr.known=false (issue 信号は生きる)', () => {
    const board = derive(
      ledgerOf([broken({ id: 'S', issue: { number: 1, status: 'starting review', githubState: 'open' } })]),
    );
    expect(board.warnings).toEqual([{ stepId: 'S', phase: 'pr', kind: 'missing-phase', status: null }]);
    expect(board.steps[0]!.pr).toEqual({ number: null, status: null, githubState: null, known: false });
    expect(board.characters.reviewer.state).toBe('working'); // issue 側の信号は劣化せず採用
    expect(board.celebrate).toBe(false);
  });

  it('issue オブジェクト欠落: 例外なし + missing-phase 警告 + issue.known=false (pr 信号は生きる)', () => {
    const board = derive(
      ledgerOf([broken({ id: 'S', pr: { number: 2, status: 'created pr', githubState: 'open' } })]),
    );
    expect(board.warnings).toEqual([{ stepId: 'S', phase: 'issue', kind: 'missing-phase', status: null }]);
    expect(board.steps[0]!.issue).toEqual({ number: null, status: null, githubState: null, known: false });
    expect(board.characters.reviewer.state).toBe('waiting');
  });

  it('step がオブジェクトですらない場合も落ちない (両フェーズ missing-phase + id は位置で補完)', () => {
    const board = derive(ledgerOf([null as unknown as Step, step('B', 'created issue', null)]));
    expect(board.steps).toHaveLength(2);
    expect(board.steps[0]!.id).toBe('(steps[0])');
    expect(board.warnings).toEqual([
      { stepId: '(steps[0])', phase: 'issue', kind: 'missing-phase', status: null },
      { stepId: '(steps[0])', phase: 'pr', kind: 'missing-phase', status: null },
    ]);
    expect(board.characters.reviewer.state).toBe('waiting'); // 壊れた step 以外は通常どおり
  });

  it('カンバンでは欠落フェーズのカードは unknown 列に置かれる (「未着手」と偽らない)', () => {
    const board = derive(
      ledgerOf([broken({ id: 'S', issue: { number: 1, status: 'created issue', githubState: 'open' } })]),
    );
    const view = deriveKanban(board.steps);
    expect(view.pr.columns.at(-1)!.cards.map((c) => c.stepId)).toEqual(['S']);
    expect(view.pr.columns.slice(0, -1).every((c) => c.cards.length === 0)).toBe(true);
    // issue レーン側は既知 status の通常列に入る
    expect(view.issue.columns.find((c) => c.status === 'created issue')!.cards).toHaveLength(1);
  });
});

describe('statusOwner — 列ヘッダの色分け (信号表からの導出)', () => {
  it('その status のボールを持つロールを返す (信号表と一致)', () => {
    expect(statusOwner('issue', 'created issue')).toBe('reviewer');
    expect(statusOwner('issue', 'starting review work')).toBe('developer');
    expect(statusOwner('pr', 'implementation-ready')).toBe('developer');
    expect(statusOwner('pr', 'starting review')).toBe('reviewer');
  });

  it('未着手 / 終端 / ready for merge / 未知語はどのロールでもない (null)', () => {
    expect(statusOwner('issue', null)).toBeNull();
    expect(statusOwner('issue', 'closed issue')).toBeNull();
    expect(statusOwner('pr', 'merged pr')).toBeNull();
    expect(statusOwner('pr', 'ready for merge')).toBeNull();
    expect(statusOwner('pr', 'not-a-status')).toBeNull();
  });
});

describe('台帳に動きなし = 両キャラ idle', () => {
  it('全 step が null または終端 (closed issue / merged pr) なら両キャラ idle・celebrate なし', () => {
    const board = derive(
      ledgerOf([
        step('A', null, null),
        step('B', 'closed issue', 'merged pr'),
        step('C', 'closed issue', null),
      ]),
    );
    expect(board.characters.developer.state).toBe('idle');
    expect(board.characters.reviewer.state).toBe('idle');
    expect(board.celebrate).toBe(false);
    expect(board.warnings).toEqual([]);
  });

  it('steps が空でも壊れず両キャラ idle', () => {
    const board = derive(ledgerOf([]));
    expect(board.steps).toEqual([]);
    expect(board.characters.developer.state).toBe('idle');
    expect(board.characters.reviewer.state).toBe('idle');
  });
});

describe('カンバン (deriveKanban) — 列順', () => {
  it('issue レーンの列順 = 作者指定のカンバン並び 8 枚 + 右端に unknown 警告列', () => {
    const lane = deriveKanban([]).issue;
    expect(lane.columns.map((c) => c.status)).toEqual([
      null, // 未着手
      'created issue',
      'waiting for review',
      'starting review',
      'completed review',
      'starting review work',
      'ready for implementation',
      'closed issue',
      null, // unknown 列 (status なし・kind で区別)
    ]);
    expect(lane.columns.at(-1)!.kind).toBe('unknown');
  });

  it('PR レーンの列順 = 作者指定のカンバン並び 9 枚 + 右端に unknown 警告列', () => {
    const lane = deriveKanban([]).pr;
    expect(lane.columns.map((c) => c.status)).toEqual([
      null, // 未着手
      'implementation-ready',
      'created pr',
      'waiting for review',
      'starting review',
      'completed review',
      'starting review work',
      'ready for merge',
      'merged pr',
      null, // unknown 列
    ]);
    expect(lane.columns.at(-1)!.kind).toBe('unknown');
  });

  it('列順定数は schema enum を過不足なく覆う (閉ループ: 表示順は自由、語彙の網羅は必須)', () => {
    // 表示順は作者指定で enum 順と異なってよいが、語彙の集合は schema と完全一致すること
    // (enum に値が増えたら列を足すまでこのテストが落ちる)
    expect([...ISSUE_COLUMN_ORDER].sort()).toEqual([...issueEnum].sort());
    expect([...PR_COLUMN_ORDER].sort()).toEqual([...prEnum].sort());
    expect(new Set(ISSUE_COLUMN_ORDER).size).toBe(ISSUE_COLUMN_ORDER.length);
    expect(new Set(PR_COLUMN_ORDER).size).toBe(PR_COLUMN_ORDER.length);
  });

  it('step が無くても全列が空のまま存在する (空の列も表示するため)', () => {
    const view = deriveKanban([]);
    for (const lane of [view.issue, view.pr]) {
      expect(lane.columns.every((c) => c.cards.length === 0)).toBe(true);
    }
  });
});

describe('カンバン (deriveKanban) — カードの配置', () => {
  /** 指定 status の列を取り出す (flow / terminal のみ。unknown 列は kind で別取得) */
  function columnOf(lane: { columns: KanbanColumn[] }, status: string | null): KanbanColumn {
    const col = lane.columns.find((c) => c.kind !== 'unknown' && c.status === status);
    if (!col) throw new Error(`column not found: ${status}`);
    return col;
  }

  it('同じ step が両レーンに 1 枚ずつ現れる (issue レーンは issue.status の列 / PR レーンは pr.status の列)', () => {
    const board = derive(ledgerOf([step('P8', 'created issue', 'completed review')]));
    const view = deriveKanban(board.steps);
    const countCards = (lane: { columns: KanbanColumn[] }) =>
      lane.columns.reduce((n, c) => n + c.cards.length, 0);
    expect(countCards(view.issue)).toBe(1);
    expect(countCards(view.pr)).toBe(1);
    expect(columnOf(view.issue, 'created issue').cards[0]!.stepId).toBe('P8');
    expect(columnOf(view.pr, 'completed review').cards[0]!.stepId).toBe('P8');
  });

  it('status = null の step は両レーンの「未着手」列 (先頭) に入る', () => {
    const board = derive(ledgerOf([step('S', null, null)]));
    const view = deriveKanban(board.steps);
    expect(view.issue.columns[0]!.cards.map((c) => c.stepId)).toEqual(['S']);
    expect(view.pr.columns[0]!.cards.map((c) => c.stepId)).toEqual(['S']);
    // unknown 列 (末尾も status=null) には入らない
    expect(view.issue.columns.at(-1)!.cards).toEqual([]);
    expect(view.pr.columns.at(-1)!.cards).toEqual([]);
  });

  it('終端 status は kind=terminal の列に入る (closed issue / merged pr)', () => {
    const board = derive(ledgerOf([step('S', 'closed issue', 'merged pr')]));
    const view = deriveKanban(board.steps);
    const issueTerminal = columnOf(view.issue, 'closed issue');
    const prTerminal = columnOf(view.pr, 'merged pr');
    expect(issueTerminal.kind).toBe('terminal');
    expect(prTerminal.kind).toBe('terminal');
    expect(issueTerminal.cards.map((c) => c.stepId)).toEqual(['S']);
    expect(prTerminal.cards.map((c) => c.stepId)).toEqual(['S']);
    // 終端以外の列は flow
    expect(columnOf(view.issue, 'created issue').kind).toBe('flow');
    expect(columnOf(view.pr, 'ready for merge').kind).toBe('flow');
  });

  it('未知 status のカードはレーン右端の unknown 列に入り、生の status を保持する (fail-soft)', () => {
    const board = derive(ledgerOf([step('S', 'brand-new-status', 'not-a-status')]));
    const view = deriveKanban(board.steps);
    const issueUnknown = view.issue.columns.at(-1)!;
    const prUnknown = view.pr.columns.at(-1)!;
    expect(issueUnknown.cards).toEqual([
      { stepId: 'S', kind: null, title: null, number: 1, status: 'brand-new-status', githubState: 'open' },
    ]);
    expect(prUnknown.cards).toEqual([
      { stepId: 'S', kind: null, title: null, number: 2, status: 'not-a-status', githubState: 'open' },
    ]);
    // 通常列には現れない (二重配置しない)
    expect(view.issue.columns.slice(0, -1).every((c) => c.cards.length === 0)).toBe(true);
    expect(view.pr.columns.slice(0, -1).every((c) => c.cards.length === 0)).toBe(true);
  });

  it('カードの番号はレーンごとに切り替わる (issue レーン = issue.number / PR レーン = pr.number)', () => {
    // step() ヘルパは issue.number=1 / pr.number=2 を入れる
    const board = derive(ledgerOf([step('S', 'created issue', 'created pr')]));
    const view = deriveKanban(board.steps);
    expect(columnOf(view.issue, 'created issue').cards[0]!.number).toBe(1);
    expect(columnOf(view.pr, 'created pr').cards[0]!.number).toBe(2);
  });

  it('同じ列に複数 step が入ったら台帳の steps 順を保つ', () => {
    const board = derive(
      ledgerOf([step('A', 'created issue', null), step('B', 'created issue', null)]),
    );
    const view = deriveKanban(board.steps);
    expect(columnOf(view.issue, 'created issue').cards.map((c) => c.stepId)).toEqual(['A', 'B']);
  });

  it('カードは githubState を写す (カード上の小表示用)', () => {
    const board = derive(ledgerOf([step('S', 'closed issue', 'merged pr')]));
    const view = deriveKanban(board.steps);
    expect(columnOf(view.issue, 'closed issue').cards[0]!.githubState).toBe('closed');
    expect(columnOf(view.pr, 'merged pr').cards[0]!.githubState).toBe('merged');
  });

  it('祝いは列の celebrating に集約される (規則 3 の導出値の消費 — UI は再導出しない)', () => {
    const board = derive(ledgerOf([step('A', 'created issue', 'ready for merge')]));
    const view = deriveKanban(board.steps);
    expect(columnOf(view.pr, 'ready for merge').celebrating).toBe(true);
    // 同じ step のカードが入る issue レーン側の列には立たない
    expect(view.issue.columns.every((c) => !c.celebrating)).toBe(true);
  });

  it('祝い step が無ければ全列 celebrating=false', () => {
    const board = derive(ledgerOf([step('A', null, 'created pr')]));
    const view = deriveKanban(board.steps);
    for (const lane of [view.issue, view.pr]) {
      expect(lane.columns.every((c) => !c.celebrating)).toBe(true);
    }
  });
});

describe('盤面 (StepView) への写像', () => {
  it('number / githubState / kind / title を写す (kind / title 欠落は null)', () => {
    const full: Step = {
      id: 'P1',
      kind: 'feat',
      title: 'タイトル',
      issue: { number: 2, status: 'closed issue', githubState: 'closed', lastReviewedStatus: 'waiting for review' },
      pr: { number: 5, status: 'merged pr', githubState: 'merged', isDraft: false },
    };
    const bare = step('P2', null, null);
    const board = derive(ledgerOf([full, bare]));
    expect(board.steps[0]).toMatchObject({
      id: 'P1',
      kind: 'feat',
      title: 'タイトル',
      issue: { number: 2, status: 'closed issue', githubState: 'closed', known: true },
      pr: { number: 5, status: 'merged pr', githubState: 'merged', known: true },
      celebrating: false,
    });
    expect(board.steps[1]).toMatchObject({ id: 'P2', kind: null, title: null });
  });
});
