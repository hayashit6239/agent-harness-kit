import { defineConfig } from 'vitest/config';

// vitest はこのファイルを優先して読む (vite.config.ts の dev 専用 fail-fast を踏まない)。
// テスト対象は src/lib 配下の純関数群 (derive / repo-slug / api) のため vue プラグインも不要。
export default defineConfig({
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
  },
});
