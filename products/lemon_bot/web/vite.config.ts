import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath } from 'node:url';
import { version } from './package.json';
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  const target = env.LEMON_BOT_DEV_BACKEND || 'http://127.0.0.1:4100';
  return {
    plugins: [react()],
    define: { __APP_VERSION__: JSON.stringify(version) },
    resolve: { alias: { '@lemon-bot/sdk': fileURLToPath(new URL('../sdk/ts/src/index.ts', import.meta.url)) } },
    server: { port: 4081, fs: { allow: [fileURLToPath(new URL('..', import.meta.url))] }, proxy: { '/v1': { target, ws: true }, '/hooks': { target }, '/mcp': { target } } },
    build: { outDir: 'dist' },
  };
});
