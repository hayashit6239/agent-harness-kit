/**
 * 台帳 (.harness/plan-progress.json) と /api/ledger 封筒の型。
 *
 * status 語彙 (enum) の単一源は `.harness/plan-progress.schema.json`。
 * 既知語彙 → キャラ信号の対応表は src/lib/derive.ts にあり、schema との同期は
 * derive.test.ts の「enum 全値割当 assert」で閉ループ検証される。
 * status は新旧台帳の混在 (未知語) に備えて string で受ける (fail-soft は derive 側)。
 */

export interface Evidence {
  build: string | null;
  test: string | null;
  lint: string | null;
  done: string | null;
}

export interface IssuePhase {
  number: number | null;
  status: string | null;
  githubState: 'open' | 'closed' | null;
  lastReviewedStatus?: string | null;
}

export interface PrPhase {
  number: number | null;
  status: string | null;
  githubState: 'open' | 'merged' | 'closed' | null;
  isDraft?: boolean;
  lastReviewedStatus?: string | null;
}

export interface Step {
  id: string;
  kind?: string;
  title?: string;
  issue: IssuePhase;
  pr: PrPhase;
}

export interface Ledger {
  project?: string;
  description?: string;
  updatedAt: string;
  evidence: Evidence;
  steps: Step[];
}

/** /api/ledger の封筒形 (常に HTTP 200)。 */
export type LedgerApiResponse =
  | { ok: true; ledger: Ledger; repoSlug: string | null; fetchedAt: string }
  | { ok: false; error: { code: 'LEDGER_NOT_FOUND' | 'LEDGER_INVALID'; message: string } };
