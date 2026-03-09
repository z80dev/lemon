import { defineConfig, mergeConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import { baseVitestConfig } from '../../vitest.base.js';

export default mergeConfig(
  baseVitestConfig,
  defineConfig({
    plugins: [react()],
    test: {
      environment: 'jsdom',
      setupFiles: ['./src/test/setup.ts'],
      onConsoleLog(log, type) {
        if (
          type === 'stderr' &&
          (/not wrapped in act\(\.\.\.\)/i.test(log) ||
            /Encountered two children with the same key/i.test(log))
        ) {
          return false;
        }
      },
    },
  })
);
