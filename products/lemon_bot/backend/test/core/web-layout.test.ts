import { expect, test } from 'bun:test';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Router } from '../../src/core/router';
import { loadConfiguration } from '../../src/core/config';
import { pairingFixture } from './pairing.fixture';

test('configured external web serves SPA and assets without exposing adjacent private state', async () => {
  const fixture = await pairingFixture();
  const directory = await mkdtemp(join(tmpdir(), 'lemon-bot-web-'));
  try {
    const webRoot = join(directory, 'web');
    await mkdir(join(webRoot, 'assets'), { recursive: true });
    await writeFile(join(webRoot, 'index.html'), '<!doctype html><title>Installed product</title>');
    await writeFile(join(webRoot, 'assets', 'app.js'), 'window.productInstalled=true;');
    await writeFile(join(directory, 'operator.key'), 'private-not-web');
    fixture.services.config.webRoot = webRoot;
    const router = new Router(fixture.services);
    const request = (path: string, method = 'GET') => router.fetch(new Request(`https://desktop.example${path}`, { method }));
    const home = await request('/');
    expect(home.status).toBe(200);
    expect(await home.text()).toContain('Installed product');
    expect(await (await request('/setup')).text()).toContain('Installed product');
    const asset = await request('/assets/app.js');
    expect(await asset.text()).toBe('window.productInstalled=true;');
    expect(asset.headers.get('Cache-Control')).toContain('immutable');
    expect(await (await request('/assets/app.js', 'HEAD')).text()).toBe('');
    expect((await request('/%2e%2e%2foperator.key')).status).toBe(404);
    expect((await request('/operator.key')).status).toBe(404);
    expect((await request('/v1/unknown')).status).toBe(404);
  } finally {
    await fixture.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test('operator configuration selects external web without moving private persistent state', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'lemon-bot-config-'));
  try {
    const dataDir = join(directory, 'private');
    const webRoot = join(directory, 'installed', 'bot', 'web');
    const { config } = await loadConfiguration({
      LEMON_BOT_DATA_DIR: dataDir, LEMON_BOT_WEB_ROOT: webRoot,
      LEMON_BOT_CONTROL_URL: 'ws://127.0.0.1:4040/ws',
      LEMON_BOT_OPERATOR_TOKEN: 'private-test-operator',
      LEMON_BOT_PUBLIC_URL: 'http://127.0.0.1:4080',
    });
    expect(config.webRoot).toBe(webRoot);
    expect(config.dataDir).toBe(dataDir);
    expect(await Bun.file(join(dataDir, 'master.key')).exists()).toBe(true);
    expect(await Bun.file(join(webRoot, 'master.key')).exists()).toBe(false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
