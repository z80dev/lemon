import { afterEach, describe, expect, test } from 'bun:test';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type * as P from '../../../contracts/protocol';
import { createBackend, type BackendInstance } from '../../src/index';
import { loadConfiguration } from '../../src/core/config';
import { opaqueToken } from '../../src/core/auth';
import { issueOwnerSetupProof } from '../../src/core/setup';
import { localAccessPath } from '../../src/core/local-access';

const cleanups: (() => Promise<void>)[] = [];
afterEach(async () => { for (const close of cleanups.splice(0)) await close(); });

/** Isolated real backend/SQLite/router; MOCK unreachable controller. */
async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), 'lemon-local-access-'));
  const configuration = await loadConfiguration({ LEMON_BOT_DATA_DIR: directory, LEMON_BOT_OPERATOR_TOKEN: 'MOCK-controller-operator', LEMON_BOT_CONTROL_URL: 'ws://127.0.0.1:1/ws' });
  let backend = await createBackend(configuration.config, configuration.key);
  cleanups.push(async () => { await backend.stop(); await rm(directory, { recursive: true, force: true }); });
  const key = async () => (await readFile(localAccessPath(directory), 'utf8')).trim();
  return {
    directory, key, get backend() { return backend; },
    async restart() { await backend.stop(); backend = await createBackend(configuration.config, configuration.key); },
    request(path: string, body: unknown, token?: string) {
      return backend.router.fetch(new Request(`${configuration.config.publicUrl}${path}`, { method: 'POST',
        headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) }));
    },
    identity(token: string) {
      return backend.router.fetch(new Request(`${configuration.config.publicUrl}/v1/identity`, { headers: { Authorization: `Bearer ${token}` } }));
    },
  };
}

describe('same-machine local access', () => {
  test('the key is a private file that survives restarts, and nothing else signs in', async () => {
    const f = await fixture();
    const key = await f.key();
    expect(key).toMatch(/^[0-9a-f]{64}$/);
    expect((await stat(localAccessPath(f.directory))).mode & 0o777).toBe(0o600);
    await f.restart();
    expect(await f.key()).toBe(key);
    for (const token of [undefined, 'a'.repeat(64), opaqueToken()]) {
      const response = await f.request('/v1/auth/local', {}, token);
      expect(response.status).toBe(401);
    }
    expect(f.backend.services.store.list('users')).toHaveLength(0);
  });

  test('an empty instance gets a passwordless owner once; later calls sign in as that owner', async () => {
    const f = await fixture();
    issueOwnerSetupProof(f.backend.services);
    const first = await f.request('/v1/auth/local', { displayName: 'Ada Lovelace' }, await f.key());
    expect(first.status).toBe(200);
    const owner = await first.json() as P.AuthResult;
    expect(owner.member.role).toBe('owner');
    expect(owner.user.displayName).toBe('Ada Lovelace');
    expect(owner.workspace.ownerUserId).toBe(owner.user.id);
    expect(owner.session.expiresAtMs).not.toBeNull();
    expect(f.backend.services.store.get('credentials', owner.user.id)).toBeNull();
    expect(f.backend.services.store.metadata('setupCode')).toBeNull();
    expect((await f.identity(owner.token)).status).toBe(200);
    const setup = await f.backend.router.fetch(new Request(`${f.backend.services.config.publicUrl}/v1/setup`));
    expect(((await setup.json()) as P.SetupStatus).setupRequired).toBe(false);

    const again = await (await f.request('/v1/auth/local', {}, await f.key())).json() as P.AuthResult;
    expect(again.user.id).toBe(owner.user.id);
    expect(again.token).not.toBe(owner.token);
    expect(f.backend.services.store.list('users')).toHaveLength(1);
  });

  test('an owner created with a setup code is the account local access opens', async () => {
    const f = await fixture();
    const proof = issueOwnerSetupProof(f.backend.services);
    const created = await (await f.request('/v1/setup', { clientNonce: opaqueToken(), setupCode: proof.code, email: 'owner@example.com', password: 'Isolated bootstrap test password 42', displayName: 'Owner', workspaceName: 'Home' })).json() as P.AuthResult;
    const local = await (await f.request('/v1/auth/local', {}, await f.key())).json() as P.AuthResult;
    expect(local.user.id).toBe(created.user.id);
    expect(local.workspace.id).toBe(created.workspace.id);
  });

  test('rewriting the key file rotates access without a restart', async () => {
    const f = await fixture();
    const previous = await f.key();
    const next = 'b'.repeat(64);
    await writeFile(localAccessPath(f.directory), `${next}\n`, { mode: 0o600 });
    expect((await f.request('/v1/auth/local', {}, previous)).status).toBe(401);
    expect((await f.request('/v1/auth/local', {}, next)).status).toBe(200);
  });
});
