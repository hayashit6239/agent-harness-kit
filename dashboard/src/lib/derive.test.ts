import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import type { Ledger, Report, Step } from '../types';
import {
  derive,
  deriveFeed,
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
    ['implementation-ready', 'waiting', 'idle', false, false],
    ['created pr', 'idle', 'waiting', false, false],
    ['starting review', 'idle', 'working', false, false],
    ['completed review', 'waiting', 'idle', false, false],
    ['need for human review', 'idle', 'idle', false, true],
    ['ready for merge', 'idle', 'idle', true, false],
    ['starting review work', 'working', 'idle', false, false],
    ['waiting for review', 'idle', 'waiting', false, false],
    ['merged pr', 'idle', 'idle', false, false],
  ] as const)('pr.status=%s → developer=%s / reviewer=%s / celebrate=%s / escalate=%s', (status, developer, reviewer, celebrate, escalate) => {
    const board = derive(ledgerOf([step('S', null, status)]));
    expect(board.characters.developer.state).toBe(developer);
    expect(board.characters.reviewer.state).toBe(reviewer);
    expect(board.celebrate).toBe(celebrate);
    expect(board.escalate).toBe(escalate);
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

describe('合成規則 4 — エスカレーションも舞台全体のフラグでキャラ状態と直交 (issue #12)', () => {
  it('need for human review の step が 1 つでもあれば escalate=true、該当 step に escalating が立つ', () => {
    const board = derive(ledgerOf([step('A', null, 'need for human review'), step('B', null, null)]));
    expect(board.escalate).toBe(true);
    expect(board.steps[0]!.escalating).toBe(true);
    expect(board.steps[1]!.escalating).toBe(false);
  });

  it('エスカレーションとキャラの作業中は同時に成立する (直交)', () => {
    const board = derive(
      ledgerOf([step('A', null, 'need for human review'), step('B', null, 'starting review work')]),
    );
    expect(board.escalate).toBe(true);
    expect(board.characters.developer.state).toBe('working');
  });

  it('エスカレーションと祝いは独立に成立しうる (別 step なら両方 true)', () => {
    const board = derive(ledgerOf([step('A', null, 'need for human review'), step('B', null, 'ready for merge')]));
    expect(board.escalate).toBe(true);
    expect(board.celebrate).toBe(true);
  });

  it('need for human review 自体はどのキャラにも信号を出さない (続行可否の判断は人間の専権)', () => {
    const board = derive(ledgerOf([step('A', null, 'need for human review')]));
    expect(board.characters.developer.state).toBe('idle');
    expect(board.characters.reviewer.state).toBe('idle');
    expect(board.characters.developer.tasks).toEqual([]);
    expect(board.characters.reviewer.tasks).toEqual([]);
  });

  it('エスカレーション step が無ければ escalate=false', () => {
    const board = derive(ledgerOf([step('A', null, 'ready for merge'), step('B', null, null)]));
    expect(board.escalate).toBe(false);
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

describe('敵対的入力 — prototype 連鎖のキーを既知語と誤認しない (Object.hasOwn)', () => {
  // "constructor" 等は `in` だと Object.prototype から継承したプロパティに当たり、
  // 継承関数を Signal 扱いして derive 全体が TypeError で落ちていた (round 2 #4)
  it.each(['constructor', 'toString', '__proto__', 'hasOwnProperty'])(
    'issue.status="%s" → crash せず unknown 警告 + キャラ idle',
    (status) => {
      const board = derive(ledgerOf([step('S', status, null)]));
      expect(board.warnings).toEqual([{ stepId: 'S', phase: 'issue', kind: 'unknown-status', status }]);
      expect(board.steps[0]!.issue.known).toBe(false);
      expect(board.characters.developer.state).toBe('idle');
      expect(board.characters.reviewer.state).toBe('idle');
    },
  );

  it.each(['constructor', 'toString', '__proto__'])(
    'pr.status="%s" → crash せず unknown 警告 + キャラ idle',
    (status) => {
      const board = derive(ledgerOf([step('S', null, status)]));
      expect(board.warnings).toEqual([{ stepId: 'S', phase: 'pr', kind: 'unknown-status', status }]);
      expect(board.steps[0]!.pr.known).toBe(false);
      expect(board.characters.developer.state).toBe('idle');
      expect(board.characters.reviewer.state).toBe('idle');
    },
  );

  it('statusOwner も prototype 連鎖を拾わない (どのロールでもない = null)', () => {
    expect(statusOwner('issue', 'constructor')).toBeNull();
    expect(statusOwner('pr', 'toString')).toBeNull();
    expect(statusOwner('pr', '__proto__')).toBeNull();
  });

  it('カンバンでも prototype 連鎖の status は unknown 列に置かれる', () => {
    const board = derive(ledgerOf([step('S', 'constructor', null)]));
    const view = deriveKanban(board.steps);
    expect(view.issue.columns.at(-1)!.cards.map((c) => c.stepId)).toEqual(['S']);
  });
});

describe('敵対的入力 — status キー欠落 (undefined) は明示 null (未着手) と区別する', () => {
  /** 型上は必須の status キーを欠いた「壊れた」フェーズオブジェクトを作る */
  function noStatus(id: string, phase: 'issue' | 'pr'): Step {
    const base = step(id, null, null);
    const partial = { ...base } as unknown as Record<string, unknown>;
    partial[phase] = { number: phase === 'issue' ? 1 : 2, githubState: 'open' }; // status キーなし
    return partial as unknown as Step;
  }

  it('issue.status キー欠落 → missing-status 警告 + known=false (「未着手」と偽らない)', () => {
    const board = derive(ledgerOf([noStatus('S', 'issue')]));
    expect(board.warnings).toEqual([{ stepId: 'S', phase: 'issue', kind: 'missing-status', status: null }]);
    expect(board.steps[0]!.issue.known).toBe(false);
    // カンバンでは unknown 列 (未着手列に紛れない)
    const view = deriveKanban(board.steps);
    expect(view.issue.columns.at(-1)!.cards.map((c) => c.stepId)).toEqual(['S']);
    expect(view.issue.columns[0]!.cards).toEqual([]);
  });

  it('issue.status 明示 null → 従来どおり未着手 (警告なし・未着手列)', () => {
    const board = derive(ledgerOf([step('S', null, null)]));
    expect(board.warnings).toEqual([]);
    expect(board.steps[0]!.issue.known).toBe(true);
    const view = deriveKanban(board.steps);
    expect(view.issue.columns[0]!.cards.map((c) => c.stepId)).toEqual(['S']);
  });

  it('pr.status キー欠落 → missing-status 警告 + known=false (issue 信号は生きる)', () => {
    const broken = noStatus('S', 'pr');
    (broken.issue as { status: string | null }).status = 'starting review';
    const board = derive(ledgerOf([broken]));
    expect(board.warnings).toEqual([{ stepId: 'S', phase: 'pr', kind: 'missing-status', status: null }]);
    expect(board.steps[0]!.pr.known).toBe(false);
    expect(board.characters.reviewer.state).toBe('working'); // PR フェーズ未開始扱いで issue 信号は採用
  });

  it('pr.status 明示 null → 従来どおり未着手 (警告なし・未着手列)', () => {
    const board = derive(ledgerOf([step('S', null, null)]));
    expect(board.warnings).toEqual([]);
    const view = deriveKanban(board.steps);
    expect(view.pr.columns[0]!.cards.map((c) => c.stepId)).toEqual(['S']);
  });

  it('status が string でも null でもない値 (数値) は文字列化して unknown 警告に流す', () => {
    const broken = step('S', null, null);
    (broken.issue as unknown as Record<string, unknown>).status = 42;
    const board = derive(ledgerOf([broken]));
    expect(board.warnings).toEqual([{ stepId: 'S', phase: 'issue', kind: 'unknown-status', status: '42' }]);
    expect(board.steps[0]!.issue.known).toBe(false);
  });
});

describe('敵対的入力 — 重複 step id でも表示キーは一意', () => {
  it('duplicate-id 警告は id ごとに 1 件へ集約される (3 回出現でも 1 件)', () => {
    const board = derive(
      ledgerOf([step('P1', 'created issue', null), step('P1', null, null), step('P1', null, 'created pr')]),
    );
    expect(board.warnings).toEqual([{ stepId: 'P1', phase: null, kind: 'duplicate-id', status: null }]);
  });

  it('StepView.key は "id#出現番号" で一意化される (1 枚目は id と同値で安定)', () => {
    const board = derive(ledgerOf([step('P1', null, null), step('P1', null, null), step('P2', null, null)]));
    expect(board.steps.map((s) => s.key)).toEqual(['P1', 'P1#2', 'P2']);
    expect(new Set(board.steps.map((s) => s.key)).size).toBe(3);
  });

  it('カンバンのカードにも一意キーが写る (同じ列に重複 id が並んでも :key 衝突しない)', () => {
    const board = derive(ledgerOf([step('P1', 'created issue', null), step('P1', 'created issue', null)]));
    const view = deriveKanban(board.steps);
    const col = view.issue.columns.find((c) => c.status === 'created issue')!;
    expect(col.cards.map((c) => c.key)).toEqual(['P1', 'P1#2']);
    expect(col.cards.map((c) => c.stepId)).toEqual(['P1', 'P1']); // 表示上の id は生のまま
  });

  it('重複 id でもキャラ信号は両方の step から畳まれる (警告は表示のためで信号は壊さない)', () => {
    const board = derive(ledgerOf([step('P1', 'created issue', null), step('P1', 'starting review', null)]));
    expect(board.characters.reviewer.state).toBe('working');
    expect(board.characters.reviewer.tasks).toHaveLength(2);
  });
});

describe('statusOwner — 列ヘッダの色分け (信号表からの導出)', () => {
  it('その status のボールを持つロールを返す (信号表と一致)', () => {
    expect(statusOwner('issue', 'created issue')).toBe('reviewer');
    expect(statusOwner('issue', 'starting review work')).toBe('developer');
    expect(statusOwner('pr', 'implementation-ready')).toBe('developer');
    expect(statusOwner('pr', 'starting review')).toBe('reviewer');
  });

  it('未着手 / 終端 / ready for merge / need for human review / 未知語はどのロールでもない (null)', () => {
    expect(statusOwner('issue', null)).toBeNull();
    expect(statusOwner('issue', 'closed issue')).toBeNull();
    expect(statusOwner('pr', 'merged pr')).toBeNull();
    expect(statusOwner('pr', 'ready for merge')).toBeNull();
    expect(statusOwner('pr', 'need for human review')).toBeNull();
    expect(statusOwner('pr', 'not-a-status')).toBeNull();
  });
});

describe('台帳に動きなし = 両キャラ idle', () => {
  it('全 step が null または終端 (closed issue / merged pr) なら両キャラ idle・celebrate/escalate なし', () => {
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
    expect(board.escalate).toBe(false);
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

  it('PR レーンの列順 = 作者指定のカンバン並び 10 枚 + 右端に unknown 警告列', () => {
    const lane = deriveKanban([]).pr;
    expect(lane.columns.map((c) => c.status)).toEqual([
      null, // 未着手
      'implementation-ready',
      'created pr',
      'waiting for review',
      'starting review',
      'completed review',
      'need for human review',
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
      { stepId: 'S', key: 'S', kind: null, title: null, number: 1, status: 'brand-new-status', githubState: 'open' },
    ]);
    expect(prUnknown.cards).toEqual([
      { stepId: 'S', key: 'S', kind: null, title: null, number: 2, status: 'not-a-status', githubState: 'open' },
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

  it('エスカレーションは列の escalating に集約される (規則 4 の導出値の消費 — UI は再導出しない・issue #12)', () => {
    const board = derive(ledgerOf([step('A', 'created issue', 'need for human review')]));
    const view = deriveKanban(board.steps);
    expect(columnOf(view.pr, 'need for human review').escalating).toBe(true);
    // 同じ step のカードが入る issue レーン側の列には立たない
    expect(view.issue.columns.every((c) => !c.escalating)).toBe(true);
  });

  it('エスカレーション step が無ければ全列 escalating=false', () => {
    const board = derive(ledgerOf([step('A', null, 'created pr')]));
    const view = deriveKanban(board.steps);
    for (const lane of [view.issue, view.pr]) {
      expect(lane.columns.every((c) => !c.escalating)).toBe(true);
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

describe('作業フィード (deriveFeed) — reports の step 横断集約 (issue #25 レイヤ 2)', () => {
  /** reports 付きの step を作る (unknown を混ぜる敵対ケースは as で流し込む) */
  function reported(id: string, reports: unknown): Step {
    return { ...step(id, 'created issue', null), reports: reports as Report[] };
  }

  function report(partial: Partial<Report>): Report {
    return {
      author: 'main developer',
      role: 'developer',
      timestamp: '2026-07-13T10:00:00+09:00',
      body: '実装した',
      ...partial,
    };
  }

  it('reports キーの無い台帳 (既存形) では空フィード (後方互換)', () => {
    expect(deriveFeed(ledgerOf([step('A', 'created issue', null)]))).toEqual([]);
  });

  it('reports: [] の step だけでも空フィード', () => {
    expect(deriveFeed(ledgerOf([reported('A', [])]))).toEqual([]);
  });

  it('steps が空でも壊れない', () => {
    expect(deriveFeed(ledgerOf([]))).toEqual([]);
  });

  it('複数 step の reports を timestamp 降順 (新しい順) に束ねる', () => {
    const feed = deriveFeed(
      ledgerOf([
        reported('A', [
          report({ body: '古い', timestamp: '2026-07-13T09:00:00+09:00' }),
          report({ body: '最新', timestamp: '2026-07-13T12:00:00+09:00' }),
        ]),
        reported('B', [report({ body: '中間', timestamp: '2026-07-13T10:30:00+09:00', role: 'reviewer' })]),
      ]),
    );
    expect(feed.map((f) => f.body)).toEqual(['最新', '中間', '古い']);
    expect(feed.map((f) => f.stepId)).toEqual(['A', 'B', 'A']);
  });

  it('同時刻は台帳の出現順を保つ (安定ソート)', () => {
    const t = '2026-07-13T10:00:00+09:00';
    const feed = deriveFeed(
      ledgerOf([
        reported('A', [report({ body: '1', timestamp: t }), report({ body: '2', timestamp: t })]),
        reported('B', [report({ body: '3', timestamp: t })]),
      ]),
    );
    expect(feed.map((f) => f.body)).toEqual(['1', '2', '3']);
  });

  it('timestamp のタイムゾーンを跨いで比較する (+09:00 と Z の混在)', () => {
    const feed = deriveFeed(
      ledgerOf([
        reported('A', [report({ body: 'JST 朝9時', timestamp: '2026-07-13T09:00:00+09:00' })]),
        // UTC 01:00 = JST 10:00 — 表記上は 01:00 だがこちらが新しい
        reported('B', [report({ body: 'UTC 1時', timestamp: '2026-07-13T01:00:00Z' })]),
      ]),
    );
    expect(feed.map((f) => f.body)).toEqual(['UTC 1時', 'JST 朝9時']);
  });

  it('timestamp 欠落 (キーなし) は time=null で末尾へ回る (本文は失わない)', () => {
    const noTs = { author: 'x', role: 'developer', body: '時刻なし' };
    const feed = deriveFeed(
      ledgerOf([reported('A', [noTs, report({ body: '時刻あり', timestamp: '2026-07-13T10:00:00+09:00' })])]),
    );
    expect(feed.map((f) => f.body)).toEqual(['時刻あり', '時刻なし']);
    expect(feed[1]!.timestamp).toBeNull();
    expect(feed[1]!.time).toBeNull();
  });

  it('timestamp が解釈不能な文字列でも落ちず末尾へ (生の文字列は保持)', () => {
    const feed = deriveFeed(
      ledgerOf([
        reported('A', [
          report({ body: '壊れ時刻', timestamp: 'not-a-timestamp' }),
          report({ body: '正常', timestamp: '2026-07-13T10:00:00+09:00' }),
        ]),
      ]),
    );
    expect(feed.map((f) => f.body)).toEqual(['正常', '壊れ時刻']);
    expect(feed[1]!.timestamp).toBe('not-a-timestamp');
    expect(feed[1]!.time).toBeNull();
  });

  it('timestamp が非文字列 (数値) は欠落と同じ扱い (epoch と誤解釈しない)', () => {
    const numeric = { author: 'x', role: 'developer', timestamp: 1752368400000, body: '数値時刻' };
    const feed = deriveFeed(ledgerOf([reported('A', [numeric])]));
    expect(feed).toHaveLength(1);
    expect(feed[0]!.timestamp).toBeNull();
    expect(feed[0]!.time).toBeNull();
  });

  it('time=null 同士は台帳の出現順を保つ', () => {
    const feed = deriveFeed(
      ledgerOf([
        reported('A', [{ body: '先' }, { body: '後' }]),
        reported('B', [{ body: '末' }]),
      ]),
    );
    expect(feed.map((f) => f.body)).toEqual(['先', '後', '末']);
  });

  it('report 要素が非オブジェクト (null / 文字列) なら読み飛ばす (他の要素は生かす)', () => {
    const feed = deriveFeed(
      ledgerOf([reported('A', [null, 'ただの文字列', report({ body: '生き残り' })])]),
    );
    expect(feed.map((f) => f.body)).toEqual(['生き残り']);
  });

  it('reports が配列でない (オブジェクト) なら その step はレポートなし扱い', () => {
    const feed = deriveFeed(
      ledgerOf([reported('A', { not: 'an array' }), reported('B', [report({ body: 'B の報' })])]),
    );
    expect(feed.map((f) => f.body)).toEqual(['B の報']);
  });

  it('author / role / body の欠落は表示用の代替値に落ちる (crash しない)', () => {
    const feed = deriveFeed(ledgerOf([reported('A', [{ timestamp: '2026-07-13T10:00:00+09:00' }])]));
    expect(feed).toEqual([
      {
        stepId: 'A',
        stepTitle: null,
        author: '(作者不明)',
        role: '(ロール不明)',
        timestamp: '2026-07-13T10:00:00+09:00',
        time: Date.parse('2026-07-13T10:00:00+09:00'),
        body: '',
        key: 'steps[0]:reports[0]',
      },
    ]);
  });

  it('step の title を写す (フィード行の文脈表示用)', () => {
    const titled: Step = { ...reported('A', [report({})]), title: 'ダッシュボード進化' };
    const feed = deriveFeed(ledgerOf([titled]));
    expect(feed[0]!.stepTitle).toBe('ダッシュボード進化');
  });

  it('key は steps 添字 + reports 添字で一意 (重複 step id でも衝突しない)', () => {
    const feed = deriveFeed(
      ledgerOf([reported('P1', [report({ body: 'a' })]), reported('P1', [report({ body: 'b' })])]),
    );
    expect(feed.map((f) => f.key).sort()).toEqual(['steps[0]:reports[0]', 'steps[1]:reports[0]']);
    expect(new Set(feed.map((f) => f.key)).size).toBe(2);
  });

  it('step 自体が壊れていても (非オブジェクト) 落ちない', () => {
    const feed = deriveFeed(ledgerOf([null as unknown as Step, reported('B', [report({ body: 'B' })])]));
    expect(feed.map((f) => f.body)).toEqual(['B']);
  });

  it('既存の derive / deriveKanban は reports の有無で変化しない (退行防止)', () => {
    const bare = step('A', 'created issue', 'completed review');
    const withReports: Step = { ...bare, reports: [report({})] };
    const boardBare = derive(ledgerOf([bare]));
    const boardReported = derive(ledgerOf([withReports]));
    expect(boardReported).toEqual(boardBare);
    expect(deriveKanban(boardReported.steps)).toEqual(deriveKanban(boardBare.steps));
  });
});
