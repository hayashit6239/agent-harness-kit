/**
 * /api/ledger 応答 (unknown) を封筒形へ検証・正規化する純関数 (vitest: api.test.ts)。
 *
 * WHY: fetch 先が本 API とは限らない (別サーバやプロキシが `{"message":"Not Found"}` の
 * ような封筒形でない JSON を 200 で返す構成がある)。封筒形の検証をここで一元化し、
 * 外れた応答は BAD_RESPONSE の失敗封筒に落とす — 呼び出し側 (App.vue) は ok の
 * 真偽だけを見ればよく、`body.error.code` 参照で TypeError になる経路を塞ぐ。
 *
 * 検証の深さは「クライアントがフィールド参照でクラッシュしない」最低限に留める:
 *   - ledger は steps 配列を持つオブジェクトであること (derive が steps.map するため必須)
 *   - ledger 内部の step の変則形はここでは見ない (derive 側の fail-soft の領分)
 *   - repoSlug / fetchedAt の型崩れは劣化動作 (null) に正規化して盤面表示は続ける
 */
import type { Ledger } from '../types';

/** 正規化後の封筒。error.code はサーバ既知語 + BAD_RESPONSE (表示にしか使わないので string) */
export type ParsedLedgerResponse =
  | { ok: true; ledger: Ledger; repoSlug: string | null; fetchedAt: string | null }
  | { ok: false; error: { code: string; message: string } };

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function bad(message: string): ParsedLedgerResponse {
  return { ok: false, error: { code: 'BAD_RESPONSE', message } };
}

export function parseLedgerResponse(body: unknown): ParsedLedgerResponse {
  if (!isRecord(body)) {
    return bad('応答が封筒形 (ok を持つオブジェクト) ではありません');
  }
  if (body.ok === true) {
    const ledger = body.ledger;
    if (!isRecord(ledger) || !Array.isArray(ledger.steps)) {
      return bad('ok 応答に steps 配列を持つ ledger がありません');
    }
    return {
      ok: true,
      // steps 配列の存在は確認済み。step 単位の変則形は derive 側の fail-soft が受ける
      ledger: ledger as unknown as Ledger,
      // 型崩れは全体を落とさず劣化動作 (リンク無効 / 取得時刻非表示) に正規化する
      repoSlug: typeof body.repoSlug === 'string' ? body.repoSlug : null,
      fetchedAt: typeof body.fetchedAt === 'string' ? body.fetchedAt : null,
    };
  }
  if (body.ok === false) {
    const error = body.error;
    if (!isRecord(error) || typeof error.code !== 'string' || typeof error.message !== 'string') {
      return bad('失敗封筒に error.code / error.message (string) がありません');
    }
    return { ok: false, error: { code: error.code, message: error.message } };
  }
  return bad('応答の ok が真偽値ではありません');
}
