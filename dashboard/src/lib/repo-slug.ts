/**
 * git remote URL → GitHub の owner/repo (slug) を導出する純関数。
 * vite.config.ts (/api/ledger の repoSlug) から使う。判断ロジックをテスト境界の
 * 内側に置くためだけに分離している (vitest: repo-slug.test.ts)。
 *
 * 対応形式:
 *   ssh:   git@github.com:owner/repo.git / ssh://git@github.com/owner/repo.git
 *   https: https://github.com/owner/repo[.git][/]
 * GitHub 以外・形式外は null (画面はリンク無効化で継続 = 劣化動作)。
 *
 * ホスト境界アンカー (?:^|[/@]): github.com の直前が 先頭 / '/' / '@' のいずれかで
 * あることを要求する。非アンカーだと notgithub.com / mygithub.com のような別ホストの
 * 部分一致で誤った github.com 向け slug を導出してしまう。'.' は境界に含めない
 * (gist.github.com 等のサブドメインは github.com/owner/repo と別物のため null に落とす)。
 */
export function parseRepoSlug(remoteUrl: string): string | null {
  const matched = remoteUrl.trim().match(/(?:^|[/@])github\.com[/:]([^/]+\/[^/]+?)(?:\.git)?\/?$/);
  return matched ? matched[1]! : null;
}

/**
 * remote URL からホスト名だけを取り出す (ログ・警告表示用)。
 * WHY: 「GitHub 形式ではない remote」を警告する際、URL 全体には認証情報
 * (https://user:token@host/... の userinfo) が含まれうるため、絶対にそのまま
 * ログへ出さない。ホスト名のみに切り詰める責務をテスト可能な純関数として持つ。
 * 判別できない入力は null (呼び出し側で「不明」等に置き換える)。
 */
export function extractHost(remoteUrl: string): string | null {
  const trimmed = remoteUrl.trim();
  try {
    // URL として解釈できる形 (https:// / ssh:// 等) は userinfo を除いた hostname を返す
    return new URL(trimmed).hostname || null;
  } catch {
    // scp 風 (user@host:path / user:pass@host:path)。'@' より後ろだけを見るので認証情報は出ない
    const matched = trimmed.match(/^(?:[^@\s]+@)?([^:/@\s]+):/);
    return matched ? matched[1]! : null;
  }
}
