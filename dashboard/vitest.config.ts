import { defineConfig } from 'vitest/config';

// vitest はこのファイルを優先して読む (vite.config.ts の dev 専用 fail-fast を踏まない)。
// テスト対象は derive.ts (純関数) のみのため vue プラグインも不要。
export default defineConfig({
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
  },
});
