import { defineConfig } from 'vitest/config';

export const baseVitestConfig = defineConfig({
  test: {
    globals: true,
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov'],
      thresholds: {
        branches: 1,
        functions: 1,
        lines: 1,
        statements: 1,
      },
    },
  },
});
