import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import type { Ledger, Step } from '../types';
import { derive, ISSUE_SIGNALS, PR_SIGNALS } from './derive';

// status 語彙の単一源 (.harness/plan-progress.schema.json) を読む —
// enum が増えたら対応表の網羅 assert が落ちる閉ループ (issue #9 決定事項)
const schemaPath = fileURLToPath(new URL('../../../.harness/plan-progress.schema.json', import.meta.url));
const schema = JSON.parse(readFileSync(schemaPath, 'utf-8')) as {
  definitions: { issueStatus: { enum: (string | null)[] }; prStatus: { enum: (string | null)[] } };
};
const issueEnum = schema.definitions.issueStatus.enum;
const prEnum = schema.definitions.prStatus.enum;

function step(id: string, issueStatus: string | null, prStatus: string | null): Step {
  return {
    id,
    issue: { number: 1, status: issueStatus, githubState: issueStatus === null ? null : 'open' },
    pr: { number: 2, status: prStatus, githubState: prStatus === null ? null : 'open' },
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
    expect(board.warnings).toEqual([{ stepId: 'S', phase: 'pr', status: 'not-a-status' }]);
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
    expect(board.warnings).toEqual([{ stepId: 'S', phase: 'issue', status: 'brand-new-status' }]);
    expect(board.steps[0]!.issue.known).toBe(false);
    expect(board.characters.developer.state).toBe('idle');
    expect(board.characters.reviewer.state).toBe('idle');
  });

  it('未知の issue status は規則 1 で信号除外される場合も警告される (警告は採否と独立)', () => {
    const board = derive(ledgerOf([step('S', 'weird', 'starting review')]));
    expect(board.warnings).toEqual([{ stepId: 'S', phase: 'issue', status: 'weird' }]);
    expect(board.characters.reviewer.state).toBe('working'); // pr 側の既知信号は生きる
  });

  it('既知 status のみなら警告なし・known=true', () => {
    const board = derive(ledgerOf([step('S', 'created issue', 'created pr')]));
    expect(board.warnings).toEqual([]);
    expect(board.steps[0]!.issue.known).toBe(true);
    expect(board.steps[0]!.pr.known).toBe(true);
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
