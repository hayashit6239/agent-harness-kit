import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { resolve } from 'node:path';
import vue from '@vitejs/plugin-vue';
import { defineConfig, type Plugin, type PluginOption } from 'vite';

/**
 * 起動 I/F (issue #9 決定事項): 環境変数 HARNESS_PROJECT に一本化。
 *   HARNESS_PROJECT=<対象プロジェクトのパス> npm run dev
 * 相対パスは `npm run dev` を実行した cwd (= dashboard/) 起点で解決する。絶対パス指定を推奨。
 * 未設定・ディレクトリ不存在は設定誤りとして起動時に即失敗する (fail-fast)。
 * 台帳ファイルの不存在はここでは検査しない (後から生成されうるため /api/ledger の
 * LEDGER_NOT_FOUND で劣化動作 + ポーリング継続)。
 */
function resolveProjectRoot(): string {
  const raw = process.env.HARNESS_PROJECT;
  if (raw === undefined || raw.trim() === '') {
    console.error(
      '[dashboard] 環境変数 HARNESS_PROJECT が未設定です。\n' +
        '  使い方: HARNESS_PROJECT=<対象プロジェクトの絶対パス> npm run dev',
    );
    process.exit(1);
  }
  const projectRoot = resolve(process.cwd(), raw);
  if (!existsSync(projectRoot) || !statSync(projectRoot).isDirectory()) {
    console.error(`[dashboard] HARNESS_PROJECT が指すディレクトリが存在しません: ${projectRoot}`);
    process.exit(1);
  }
  return projectRoot;
}

/**
 * `git -C <project> remote get-url origin` から GitHub の owner/repo を導出する。
 * ssh (git@github.com:owner/repo.git / ssh://git@github.com/owner/repo.git) と
 * https (https://github.com/owner/repo[.git]) の両形式に対応。
 * remote 無し・GitHub 以外・git 失敗は null (画面はリンク無効化で継続 = 劣化動作)。
 */
function detectRepoSlug(projectRoot: string): string | null {
  let url: string;
  try {
    url = execFileSync('git', ['-C', projectRoot, 'remote', 'get-url', 'origin'], {
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    return null;
  }
  const matched = url.match(/github\.com[/:]([^/]+\/[^/]+?)(?:\.git)?\/?$/);
  return matched ? matched[1] : null;
}

/**
 * /api/ledger — `<project>/.harness/plan-progress.json` を読んで封筒形で返す。
 * 応答は常に HTTP 200 (issue #9 決定事項):
 *   成功: {ok: true, ledger, repoSlug, fetchedAt}
 *   失敗: {ok: false, error: {code: 'LEDGER_NOT_FOUND' | 'LEDGER_INVALID', message}}
 * LEDGER_INVALID = JSON.parse 失敗、または parse は通るが steps が配列として存在しない場合。
 * それ以上の構造検証は API 層では行わない (未知 status は derive 側の fail-soft)。
 */
function ledgerApiPlugin(projectRoot: string): Plugin {
  const ledgerPath = resolve(projectRoot, '.harness', 'plan-progress.json');
  // remote は起動中に変わらない前提で起動時に 1 回だけ導出する
  const repoSlug = detectRepoSlug(projectRoot);
  return {
    name: 'harness-ledger-api',
    configureServer(server) {
      server.middlewares.use('/api/ledger', (_req, res) => {
        res.setHeader('Content-Type', 'application/json; charset=utf-8');
        const fail = (code: 'LEDGER_NOT_FOUND' | 'LEDGER_INVALID', message: string): void => {
          res.end(JSON.stringify({ ok: false, error: { code, message } }));
        };
        let raw: string;
        try {
          raw = readFileSync(ledgerPath, 'utf-8');
        } catch {
          fail('LEDGER_NOT_FOUND', `台帳ファイルが見つかりません: ${ledgerPath}`);
          return;
        }
        let ledger: unknown;
        try {
          ledger = JSON.parse(raw);
        } catch {
          fail('LEDGER_INVALID', `台帳を JSON として解釈できません: ${ledgerPath}`);
          return;
        }
        if (ledger === null || typeof ledger !== 'object' || !Array.isArray((ledger as { steps?: unknown }).steps)) {
          fail('LEDGER_INVALID', `台帳に steps 配列がありません: ${ledgerPath}`);
          return;
        }
        res.end(JSON.stringify({ ok: true, ledger, repoSlug, fetchedAt: new Date().toISOString() }));
      });
    },
  };
}

export default defineConfig(({ command, isPreview }) => {
  const plugins: PluginOption[] = [vue()];
  // fail-fast と台帳 API は dev サーバ起動時のみ (build / preview / vitest では HARNESS_PROJECT 不要)
  if (command === 'serve' && !isPreview && !process.env.VITEST) {
    plugins.push(ledgerApiPlugin(resolveProjectRoot()));
  }
  return { plugins };
});
