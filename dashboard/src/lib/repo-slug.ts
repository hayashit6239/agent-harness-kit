/**
 * git remote URL → GitHub の owner/repo (slug) を導出する純関数。
 * vite.config.ts (/api/ledger の repoSlug) から使う。判断ロジックをテスト境界の
 * 内側に置くためだけに分離している (vitest: repo-slug.test.ts)。
 *
 * 対応形式:
 *   ssh:   git@github.com:owner/repo.git / ssh://git@github.com/owner/repo.git
 *   https: https://github.com/owner/repo[.git][/]
 * GitHub 以外・形式外は null (画面はリンク無効化で継続 = 劣化動作)。
 */
export function parseRepoSlug(remoteUrl: string): string | null {
  const matched = remoteUrl.trim().match(/github\.com[/:]([^/]+\/[^/]+?)(?:\.git)?\/?$/);
  return matched ? matched[1] : null;
}
