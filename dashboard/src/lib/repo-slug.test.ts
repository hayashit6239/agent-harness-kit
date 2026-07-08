import { describe, expect, it } from 'vitest';
import { extractHost, parseRepoSlug } from './repo-slug';

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

describe('parseRepoSlug — 敵対形: github.com を含むだけの別ホストは null (ホスト境界アンカー)', () => {
  it.each([
    ['scp 風の notgithub.com', 'git@notgithub.com:owner/repo.git'],
    ['https の mygithub.com', 'https://mygithub.com/owner/repo.git'],
    ['scp 風の mygithub.com (.git なし)', 'git@mygithub.com:owner/repo'],
    ['サブドメイン (gist.github.com は repo と別物)', 'https://gist.github.com/owner/repo'],
    ['github.com が後続文字列の一部 (github.com.evil.com)', 'https://github.com.evil.com/owner/repo'],
  ])('%s: %s → null', (_label, url) => {
    expect(parseRepoSlug(url)).toBeNull();
  });

  it('認証情報付き https (…@github.com) は @ 境界で従来どおり導出できる', () => {
    // 値はダミー。導出結果に userinfo が混入しないことも確認する
    expect(parseRepoSlug('https://x-access-token:dummy@github.com/owner/repo.git')).toBe('owner/repo');
  });
});

describe('extractHost — 警告ログ用のホスト名抽出 (認証情報を漏らさない)', () => {
  it('https URL はホスト名のみ (userinfo のダミー認証情報を含まない)', () => {
    expect(extractHost('https://user:dummy-secret@gitlab.com/owner/repo.git')).toBe('gitlab.com');
  });

  it('scp 風は @ より後ろのホストのみ', () => {
    expect(extractHost('git@gitlab.com:owner/repo.git')).toBe('gitlab.com');
  });

  it('ssh:// スキームもホスト名のみ', () => {
    expect(extractHost('ssh://git@gitlab.com/owner/repo.git')).toBe('gitlab.com');
  });

  it('判別できない入力は null (無理に断片を返してリークしない)', () => {
    expect(extractHost('こんにちは')).toBeNull();
    expect(extractHost('')).toBeNull();
  });
});
