import { afterEach, describe, expect, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type * as P from '../../../contracts/protocol';
import type { BackendServices } from '../../src/core/services';
import { Store } from '../../src/core/store';
import { ApiError } from '../../src/core/errors';
import { baseBotMcpTemplate, proveSameHost } from '../../src/core/bots';

const cleanups: (() => Promise<void>)[] = [];
afterEach(async () => { for (const close of cleanups.splice(0)) await close(); });

type Write = { nodeId: string; path: string; dataBase64: string };
/** MOCK controller: `node.fs.write` lands wherever the fake worker lives. */
async function fixture(publicUrl: string, worker: 'same-host' | 'elsewhere') {
  const dataDir = await mkdtemp(join(tmpdir(), 'lemon-same-host-'));
  const store = new Store(':memory:');
  const writes: Write[] = [];
  const services = {
    config: { publicUrl, dataDir, operator: { approvedPrivateMcpOrigins: [] } }, store,
    lemon: { async call(method: string, params: Write) {
      expect(method).toBe('node.fs.write'); writes.push(params);
      if (worker === 'elsewhere') throw new ApiError('not_found', 'No such directory on that machine.');
      await writeFile(params.path, Buffer.from(params.dataBase64, 'base64'));
      return { path: params.path };
    } },
  } as unknown as BackendServices;
  cleanups.push(async () => { store.close(); await rm(dataDir, { recursive: true, force: true }); });
  const machine = { id: 'machine-1', nodeId: 'node-1', name: 'studio' } as P.Machine;
  return { services, store, writes, machine, dataDir };
}

describe('loopback Bot endpoint', () => {
  test('a worker that writes into this backend’s private directory gets a loopback MCP template', async () => {
    const f = await fixture('http://127.0.0.1:4100', 'same-host');
    expect(() => baseBotMcpTemplate(f.services, f.machine)).toThrow(ApiError);
    await proveSameHost(f.services, f.machine);
    expect(f.writes).toHaveLength(1);
    expect(f.writes[0]!.path.startsWith(join(f.dataDir, 'tmp'))).toBe(true);
    expect(readdirSync(join(f.dataDir, 'tmp'))).toEqual([]);
    expect(baseBotMcpTemplate(f.services, f.machine)).toMatchObject({ url: 'http://127.0.0.1:4100/mcp', allowedOrigins: ['http://127.0.0.1:4100'], approvedPrivateOrigins: ['http://127.0.0.1:4100'] });
    await proveSameHost(f.services, f.machine);
    expect(f.writes).toHaveLength(1);
  });

  test('another machine, or the same name with a new node identity, is refused', async () => {
    const f = await fixture('http://127.0.0.1:4100', 'elsewhere');
    await proveSameHost(f.services, f.machine);
    expect(() => baseBotMcpTemplate(f.services, f.machine)).toThrow(/only reachable on its own computer/);
    // A code the client explains as "review your choice" rather than "ask your administrator".
    let refusal: unknown; try { baseBotMcpTemplate(f.services, f.machine); } catch (error) { refusal = error; }
    expect(refusal).toMatchObject({ code: 'invalid_request' });
    const g = await fixture('http://127.0.0.1:4100', 'same-host');
    await proveSameHost(g.services, g.machine);
    expect(() => baseBotMcpTemplate(g.services, { ...g.machine, nodeId: 'node-2' })).toThrow(ApiError);
  });

  test('an SSH tunnel accepts only its forwarded literal IPv4 product port', async () => {
    const f = await fixture('http://127.0.0.1:4100', 'elsewhere');
    f.machine.link = { kind: 'ssh_tunnel', sshDestination: 'me@studio', nodePort: 4044, productPort: 4100, tunnel: { state: 'online', detail: null, checkedAtMs: 1 } };
    expect(baseBotMcpTemplate(f.services, f.machine)).toMatchObject({ url: 'http://127.0.0.1:4100/mcp', allowedOrigins: ['http://127.0.0.1:4100'], approvedPrivateOrigins: ['http://127.0.0.1:4100'] });
    f.services.config.publicUrl = 'http://127.0.0.1:4101';
    expect(() => baseBotMcpTemplate(f.services, f.machine)).toThrow(ApiError);
    f.services.config.publicUrl = 'https://bot.example.ts.net';
    expect(baseBotMcpTemplate(f.services, f.machine).url).toBe('https://bot.example.ts.net/mcp');
    expect(f.writes).toHaveLength(0);
  });

  test.each(['http://[::1]:4100', 'http://[0:0:0:0:0:0:0:1]:4100', 'https://[::1]:4100', 'http://localhost:4100', 'https://bot.localhost:4100', 'http://127.0.0.2:4100', 'http://0.0.0.0:4100', 'https://127.0.0.1:4100'])('an existing SSH tunnel rejects unsupported loopback product origin %s', async publicUrl => {
    const f = await fixture(publicUrl, 'same-host');
    f.machine.link = { kind: 'ssh_tunnel', sshDestination: 'me@studio', nodePort: 4044, productPort: 4100, tunnel: { state: 'online', detail: null, checkedAtMs: 1 } };
    expect(() => baseBotMcpTemplate(f.services, f.machine)).toThrow(ApiError);
    // A cached local proof must not bypass the tunnel's IPv4-only destination contract.
    f.store.setMetadata(`machineSameHost:${f.machine.id}`, f.machine.nodeId);
    expect(() => baseBotMcpTemplate(f.services, f.machine)).toThrow(ApiError);
    expect(f.writes).toHaveLength(0);
  });

  test('a proven same-host worker without a tunnel retains IPv6 loopback support', async () => {
    const f = await fixture('http://[::1]:4100', 'same-host');
    await proveSameHost(f.services, f.machine);
    expect(baseBotMcpTemplate(f.services, f.machine)).toMatchObject({ url: 'http://[::1]:4100/mcp', allowedOrigins: ['http://[::1]:4100'], approvedPrivateOrigins: ['http://[::1]:4100'] });
  });

  test('an HTTPS origin needs no proof and a localhost name is never treated as literal loopback', async () => {
    const secure = await fixture('https://bot.example.ts.net', 'elsewhere');
    await proveSameHost(secure.services, secure.machine);
    expect(secure.writes).toHaveLength(0);
    expect(baseBotMcpTemplate(secure.services, secure.machine).approvedPrivateOrigins).toEqual([]);
    const named = await fixture('http://localhost:4100', 'same-host');
    await proveSameHost(named.services, named.machine);
    expect(named.writes).toHaveLength(0);
    expect(() => baseBotMcpTemplate(named.services, named.machine)).toThrow(ApiError);
  });
});
