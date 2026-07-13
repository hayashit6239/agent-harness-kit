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

/**
 * 作業レポート 1 件 (schema definitions.report / issue #25)。
 * 「最後に作業したエージェントが何をしたか」を人間可読で残す任意データで、
 * ダッシュボードは deriveFeed (src/lib/derive.ts) で step 横断のフィードに束ねて表示する。
 * step あたり最新 10 件上限 (FIFO) は schema の maxItems: 10 が単一源。
 */
export interface Report {
  author: string;
  /** developer / reviewer 等 */
  role: string;
  /** ISO 8601 秒精度 (例: 2026-07-13T12:34:56+09:00) */
  timestamp: string;
  body: string;
}

export interface Step {
  id: string;
  kind?: string;
  title?: string;
  issue: IssuePhase;
  pr: PrPhase;
  /** 任意・後方互換 (issue #25)。欠落 = レポートなし */
  reports?: Report[];
}

export interface Ledger {
  project?: string;
  description?: string;
  updatedAt: string;
  evidence: Evidence;
  steps: Step[];
}

/**
 * /api/ledger の封筒形 (常に HTTP 200)。サーバ側 (vite.config.ts) が返す契約の記述。
 * クライアントは応答をこの型と信じて参照せず、src/lib/api.ts の parseLedgerResponse で
 * 検証・正規化してから使う (封筒形でない JSON が返る構成への防御)。
 */
export type LedgerApiResponse =
  | { ok: true; ledger: Ledger; repoSlug: string | null; fetchedAt: string }
  | { ok: false; error: { code: 'LEDGER_NOT_FOUND' | 'LEDGER_INVALID'; message: string } };
