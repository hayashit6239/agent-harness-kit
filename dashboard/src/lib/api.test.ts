import { describe, expect, it } from 'vitest';
import { parseLedgerResponse } from './api';

/** 最小の正常 ok 封筒 (steps 空配列) */
function okEnvelope(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    ok: true,
    ledger: { updatedAt: '2026-07-08', evidence: { build: null, test: 'true', lint: null, done: 'true' }, steps: [] },
    repoSlug: 'owner/repo',
    fetchedAt: '2026-07-08T00:00:00.000Z',
    ...overrides,
  };
}

describe('parseLedgerResponse — 封筒形でない応答は BAD_RESPONSE に正規化 (敵対的入力)', () => {
  it.each([
    ['プロキシの 404 応答', { message: 'Not Found' }],
    ['配列', []],
    ['null', null],
    ['文字列', 'ok'],
    ['数値', 200],
    ['ok が文字列 "true"', { ok: 'true', ledger: { steps: [] } }],
    ['ok が 1 (truthy 数値)', { ok: 1, ledger: { steps: [] } }],
  ])('%s → ok:false / BAD_RESPONSE', (_label, body) => {
    const parsed = parseLedgerResponse(body);
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) expect(parsed.error.code).toBe('BAD_RESPONSE');
  });
});

describe('parseLedgerResponse — ok:true 側の変則形', () => {
  it('ledger 欠落 → BAD_RESPONSE', () => {
    const parsed = parseLedgerResponse({ ok: true });
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) expect(parsed.error.code).toBe('BAD_RESPONSE');
  });

  it('ledger.steps が配列でない → BAD_RESPONSE (derive が steps.map できない)', () => {
    const parsed = parseLedgerResponse(okEnvelope({ ledger: { steps: 'not-array' } }));
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) expect(parsed.error.code).toBe('BAD_RESPONSE');
  });

  it('ledger が配列 → BAD_RESPONSE', () => {
    const parsed = parseLedgerResponse(okEnvelope({ ledger: [] }));
    expect(parsed.ok).toBe(false);
  });

  it('repoSlug が非 string → null に正規化 (リンク無効の劣化動作。全体は落とさない)', () => {
    const parsed = parseLedgerResponse(okEnvelope({ repoSlug: 42 }));
    expect(parsed.ok).toBe(true);
    if (parsed.ok) expect(parsed.repoSlug).toBeNull();
  });

  it('fetchedAt 欠落 → null に正規化 (取得時刻非表示の劣化動作。全体は落とさない)', () => {
    const envelope = okEnvelope();
    delete envelope.fetchedAt;
    const parsed = parseLedgerResponse(envelope);
    expect(parsed.ok).toBe(true);
    if (parsed.ok) expect(parsed.fetchedAt).toBeNull();
  });

  it('正常な ok 封筒はそのまま通す', () => {
    const parsed = parseLedgerResponse(okEnvelope());
    expect(parsed).toMatchObject({ ok: true, repoSlug: 'owner/repo', fetchedAt: '2026-07-08T00:00:00.000Z' });
  });
});

describe('parseLedgerResponse — ok:false 側の変則形', () => {
  it('サーバの失敗封筒 (LEDGER_NOT_FOUND) はそのまま通す', () => {
    const parsed = parseLedgerResponse({ ok: false, error: { code: 'LEDGER_NOT_FOUND', message: '台帳がない' } });
    expect(parsed).toEqual({ ok: false, error: { code: 'LEDGER_NOT_FOUND', message: '台帳がない' } });
  });

  it('error 欠落 → BAD_RESPONSE (body.error.code の TypeError 経路を塞ぐ)', () => {
    const parsed = parseLedgerResponse({ ok: false });
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) expect(parsed.error.code).toBe('BAD_RESPONSE');
  });

  it('error.code / error.message が非 string → BAD_RESPONSE', () => {
    const parsed = parseLedgerResponse({ ok: false, error: { code: 500, message: null } });
    expect(parsed.ok).toBe(false);
    if (!parsed.ok) expect(parsed.error.code).toBe('BAD_RESPONSE');
  });
});
