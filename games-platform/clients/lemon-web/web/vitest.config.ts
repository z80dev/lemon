import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    globals: true,
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
});
