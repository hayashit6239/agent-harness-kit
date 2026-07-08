import { describe, expect, it } from 'vitest';
import { parseRepoSlug } from './repo-slug';

describe('parseRepoSlug — ssh 形式', () => {
  it('scp 風 (git@github.com:owner/repo.git)', () => {
    expect(parseRepoSlug('git@github.com:hayashit6239/agent-harness-kit.git')).toBe(
      'hayashit6239/agent-harness-kit',
    );
  });

  it('ssh:// スキーム (ssh://git@github.com/owner/repo.git)', () => {
    expect(parseRepoSlug('ssh://git@github.com/owner/repo.git')).toBe('owner/repo');
  });

  it('.git なしの scp 風', () => {
    expect(parseRepoSlug('git@github.com:owner/repo')).toBe('owner/repo');
  });
});

describe('parseRepoSlug — https 形式', () => {
  it('.git あり', () => {
    expect(parseRepoSlug('https://github.com/owner/repo.git')).toBe('owner/repo');
  });

  it('.git なし', () => {
    expect(parseRepoSlug('https://github.com/owner/repo')).toBe('owner/repo');
  });

  it('末尾スラッシュ付き', () => {
    expect(parseRepoSlug('https://github.com/owner/repo/')).toBe('owner/repo');
  });

  it('前後の空白 (git 出力の改行残り) は無視する', () => {
    expect(parseRepoSlug('  https://github.com/owner/repo.git\n')).toBe('owner/repo');
  });
});

describe('parseRepoSlug — 失敗形は null (劣化動作)', () => {
  it.each([
    ['GitHub 以外のホスト', 'git@gitlab.com:owner/repo.git'],
    ['owner/repo の形になっていない', 'https://github.com/owner'],
    ['URL ですらない', 'こんにちは'],
    ['空文字', ''],
  ])('%s: %s → null', (_label, url) => {
    expect(parseRepoSlug(url)).toBeNull();
  });
});
