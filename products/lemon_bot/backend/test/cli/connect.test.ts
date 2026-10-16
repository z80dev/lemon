import { afterEach, describe, expect, test } from 'bun:test';
import { runConnect, type ConnectTerminal } from '../../src/cli/connect';
import { parsePairUrl } from '../../../sdk/ts/src/pairing';
import type * as P from '../../../contracts/protocol';
import { pairingFixture, type PairingFixture } from '../core/pairing.fixture';

const fixtures: PairingFixture[] = [];
afterEach(async () => { for (const value of fixtures.splice(0)) await value.close(); });
const password = 'private-owner-password-not-printed';

async function harness(settings: { decision?: string; complete?: boolean; lostApproval?: boolean; wrongService?: boolean; mismatch?: 'instance' | 'workspace'; malformedLink?: boolean; otherOwner?: boolean } = {}) {
  const f = await pairingFixture(); fixtures.push(f);
  f.store.put('credentials', { id: settings.otherOwner ? f.other.user.id : f.owner.user.id, passwordHash: await Bun.password.hash(password, { algorithm: 'argon2id', memoryCost: 8, timeCost: 1 }) });
  const messages: string[] = [], sensitive: string[] = [], reads: { label: string; hidden: boolean | undefined }[] = [];
  const calls: { path: string; method: string; body: Record<string, unknown> | undefined }[] = [];
  let issued: P.PairingIssued | undefined, claim: P.PairingClaimResult | undefined, loginToken = '';
  const completeNonce = 'one-fixed-phone-completion-nonce';
  const io: ConnectTerminal = {
    interactive: true,
    write(message) { messages.push(message); },
    sensitive(message) { sensitive.push(message); },
    async read(label, hidden) {
      reads.push({ label, hidden });
      if (label.startsWith('Owner email')) return settings.otherOwner ? f.other.user.email : f.owner.user.email;
      if (hidden) return password;
      if (label.startsWith('Create')) return 'create';
      return settings.decision ?? `approve ${claim!.verificationCode}`;
    },
  };
  const fetcher = (async (input, init) => {
    const url = new URL(String(input));
    const method = init?.method ?? 'GET';
    const body = init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : undefined;
    calls.push({ path: url.pathname, method, body });
    expect(init?.redirect).toBe('manual'); expect(init?.credentials).toBe('omit');
    if (settings.wrongService && url.hostname === 'desktop.example') return new Response('<html>Phoenix</html>', { headers: { 'Content-Type': 'text/html' } });
    const authorization = new Headers(init?.headers).get('Authorization');
    const response = await f.fetch(method, url.pathname, body, authorization?.replace(/^Bearer /, '') ?? null);
    if (url.pathname === '/v1/auth/login' && response.ok) loginToken = (await response.clone().json() as P.AuthResult).token;
    if (url.pathname === '/v1/setup' && url.hostname === 'desktop.example' && settings.mismatch === 'instance') {
      const value = await response.json() as P.SetupStatus; return Response.json({ ...value, instanceId: 'wrong-backend' });
    }
    if (url.pathname === '/v1/identity' && url.hostname === 'desktop.example' && settings.mismatch === 'workspace') {
      const value = await response.json() as P.BackendIdentity; return Response.json({ ...value, workspaceId: 'wrong-workspace' });
    }
    if (url.pathname === '/v1/pairings' && method === 'POST' && response.ok) {
      issued = await response.clone().json() as P.PairingIssued;
      if (settings.malformedLink) return Response.json({ ...issued, pairUrl: `${issued.pairUrl}&extra=forbidden` }, { status: 201 });
    }
    if (url.pathname.endsWith('/approve') && response.ok) {
      if (settings.complete !== false) {
        const result = await f.fetch('POST', `/v1/pairings/${claim!.pairingId}/complete`, { claimToken: claim!.claimToken, clientNonce: completeNonce }, null);
        expect((await result.json() as P.PairingCompletion).status).toBe('connected');
      }
      if (settings.lostApproval) throw new Error(`untrusted response containing ${loginToken}`);
    }
    return response;
  }) as typeof fetch;
  async function sleep(ms: number) {
    f.advance(ms);
    if (issued && !claim) {
      const parsed = parsePairUrl(issued.pairUrl);
      const preview = await f.fetch('POST', '/v1/pairings/preview', { pairCode: parsed.pairCode, workspaceId: parsed.workspaceId }, null);
      expect(preview.status).toBe(200);
      claim = await (await f.fetch('POST', '/v1/pairings/claim', { pairCode: parsed.pairCode, workspaceId: parsed.workspaceId, installationId: 'headless-test-phone', deviceName: 'Owner iPhone', appVersion: '1', clientNonce: 'one-fixed-phone-claim-nonce' }, null)).json() as P.PairingClaimResult;
    }
  }
  return { f, io, messages, sensitive, reads, calls, fetcher, sleep, get claim() { return claim; }, get loginToken() { return loginToken; } };
}

const args = ['iphone', '--backend', 'http://127.0.0.1:4080'];
describe('headless owner pairing through the real product state machine', () => {
  test('hidden local owner login, explicit approval and actual phone completion; transient login revoked', async () => {
    const h = await harness();
    expect(await runConnect(args, { terminal: h.io, fetch: h.fetcher, sleep: h.sleep, now: h.f.services.now })).toBe(0);
    expect(h.reads.find(row => row.label.startsWith('Owner password'))?.hidden).toBe(true);
    expect(h.reads.some(row => row.label.startsWith('Type approve'))).toBe(true);
    expect(h.f.persistentCalls).toBe(1);
    expect(h.messages.join('\n')).toContain('Phone completed pairing');
    expect(h.sensitive).toHaveLength(1);
    const parsed = parsePairUrl(h.sensitive[0]!);
    expect(parsed.workspaceId).toBe(h.f.workspace.id);
    expect(parsed.instanceId).toBe(h.f.store.metadata<string>('instanceId')!);
    const ordinary = h.messages.join('\n');
    for (const secret of [password, h.loginToken, h.f.owner.token, h.f.services.config.operatorToken, parsed.pairCode, h.claim!.claimToken]) expect(ordinary).not.toContain(secret);
    expect(h.sensitive[0]).not.toContain(h.loginToken);
    const revoked = await h.f.fetch('GET', '/v1/identity', undefined, h.loginToken);
    expect(revoked.status).toBe(401);
    expect(h.calls.filter(row => row.path.endsWith('/approve'))).toHaveLength(1);
    expect(h.calls.filter(row => row.path === '/v1/pairings' && row.method === 'POST')).toHaveLength(1);
  });

  for (const settings of [{}, { decision: 'deny' }, { wrongService: true }]) {
    test(`cleanup preserves existing OIDC and owner sessions (${JSON.stringify(settings)})`, async () => {
      const h = await harness(settings);
      const providerSession = { id: h.f.owner.session.id, userId: h.f.owner.user.id, providerId: 'optional-oidc', encryptedIDToken: h.f.services.encrypt('existing-provider-id-token') };
      h.f.store.put('oidcProviderSessions', providerSession);
      expect(await runConnect(args, { terminal: h.io, fetch: h.fetcher, sleep: h.sleep, now: h.f.services.now })).toBe('wrongService' in settings ? 1 : 0);
      expect(h.f.store.get('oidcProviderSessions', providerSession.id)).toEqual(providerSession);
      expect(h.f.store.list('oidcEndSessionReceipts')).toEqual([]);
      expect((await h.f.fetch('GET', '/v1/identity', undefined, h.f.owner.token)).status).toBe(200);
      expect((await h.f.fetch('GET', '/v1/identity', undefined, h.loginToken)).status).toBe(401);
      expect(h.calls.filter(row => row.method === 'DELETE' && row.path.startsWith('/v1/auth/sessions/'))).toHaveLength(1);
      expect(h.calls.some(row => row.path === '/v1/auth/logout')).toBe(false);
      // Positive control: the production-equivalent logout hook really ends provider sessions.
      expect((await h.f.fetch('POST', '/v1/auth/logout', { clientNonce: 'explicit-owner-logout-control' }, h.f.owner.token)).status).toBe(200);
      expect(h.f.store.get('oidcProviderSessions', providerSession.id)).toBeNull();
      expect(h.f.store.list('oidcEndSessionReceipts')).toHaveLength(1);
    });
  }

  for (const decision of ['deny', 'yes', 'approve 999999']) {
    test(`fails closed on terminal decision ${decision}`, async () => {
      const h = await harness({ decision });
      expect(await runConnect(args, { terminal: h.io, fetch: h.fetcher, sleep: h.sleep, now: h.f.services.now })).toBe(0);
      expect(h.messages.join('\n')).toContain('Pairing denied');
      expect(h.f.persistentCalls).toBe(0);
      expect(h.calls.some(row => row.path.endsWith('/approve'))).toBe(false);
      expect(h.calls.filter(row => row.path.endsWith('/deny'))).toHaveLength(1);
    });
  }

  test('noninteractive refusal precedes credential input, requests and one-use output', async () => {
    const h = await harness(); h.io.interactive = false;
    expect(await runConnect(args, { terminal: h.io, fetch: h.fetcher })).toBe(1);
    expect(h.calls).toEqual([]); expect(h.reads).toEqual([]); expect(h.sensitive).toEqual([]);
    expect(h.messages[0]).toContain('interactive private terminal');
  });

  test('standalone executable dispatch refuses piped pairing without backend startup', async () => {
    const child = Bun.spawn([process.execPath, new URL('../../src/cli.ts', import.meta.url).pathname, 'connect', ...args], { stdin: 'ignore', stdout: 'pipe', stderr: 'pipe', env: {} });
    const output = await new Response(child.stdout).text();
    const error = await new Response(child.stderr).text();
    expect(await child.exited).toBe(1);
    expect(output).toContain('interactive private terminal');
    expect(error).toBe('');
    expect(output).not.toContain('listening');
  });

  test('runtime TLS bypass is refused before discovery or owner login', async () => {
    const h = await harness(), previous = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
    process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
    try {
      expect(await runConnect(args, { terminal: h.io, fetch: h.fetcher })).toBe(1);
      expect(h.calls).toEqual([]); expect(h.reads).toEqual([]); expect(h.sensitive).toEqual([]);
      expect(h.messages.join('\n')).toContain('TLS verification bypass');
    } finally {
      if (previous === undefined) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
      else process.env.NODE_TLS_REJECT_UNAUTHORIZED = previous;
    }
  });

  test('wrong service preflight fails without issuance or sensitive output', async () => {
    const h = await harness({ wrongService: true });
    expect(await runConnect(args, { terminal: h.io, fetch: h.fetcher })).toBe(1);
    expect(h.sensitive).toEqual([]); expect(h.calls.some(row => row.path === '/v1/pairings')).toBe(false);
    expect(h.messages.join('\n')).toContain('supported Lemon Bot product API');
    expect(h.messages.join('\n')).not.toContain('Phoenix');
  });

  for (const mismatch of ['instance', 'workspace'] as const) {
    test(`phone alias ${mismatch} mismatch fails before issuance`, async () => {
      const h = await harness({ mismatch });
      expect(await runConnect(args, { terminal: h.io, fetch: h.fetcher })).toBe(1);
      expect(h.sensitive).toEqual([]); expect(h.calls.some(row => row.path === '/v1/pairings')).toBe(false);
    });
  }

  test('another owner-role account cannot substitute for the actual workspace owner', async () => {
    const h = await harness({ otherOwner: true });
    expect(await runConnect(args, { terminal: h.io, fetch: h.fetcher })).toBe(1);
    expect(h.messages.join('\n')).toContain('Only the current workspace owner'); expect(h.sensitive).toEqual([]);
  });

  test('lost approval response reconciles consumption without a second issuance or approval', async () => {
    const h = await harness({ lostApproval: true });
    expect(await runConnect(args, { terminal: h.io, fetch: h.fetcher, sleep: h.sleep, now: h.f.services.now })).toBe(0);
    expect(h.calls.filter(row => row.path.endsWith('/approve'))).toHaveLength(1); expect(h.f.persistentCalls).toBe(1);
    expect(h.messages.join('\n')).not.toContain(h.loginToken);
  });

  test('approval alone is not success: phone must actually complete before expiry', async () => {
    const h = await harness({ complete: false });
    expect(await runConnect(args, { terminal: h.io, fetch: h.fetcher, sleep: h.sleep, now: h.f.services.now })).toBe(1);
    expect(h.messages.join('\n')).not.toContain('Phone completed pairing');
    expect(h.f.persistentCalls).toBe(1); expect(h.calls.filter(row => row.path.endsWith('/approve'))).toHaveLength(1);
  });

  test('CLI rejects malformed owner-issued QR before displaying it', async () => {
    const h = await harness({ malformedLink: true });
    expect(await runConnect(args, { terminal: h.io, fetch: h.fetcher, now: h.f.services.now })).toBe(1);
    expect(h.sensitive).toEqual([]); expect(h.messages.join('\n')).toContain('Invalid owner-issued pairing payload');
  });

  test('unknown secret/approval flags are never echoed or accepted', async () => {
    const h = await harness();
    expect(await runConnect([...args, '--token', password], { terminal: h.io, fetch: h.fetcher })).toBe(2);
    expect(h.messages.join('\n')).not.toContain(password); expect(h.calls).toEqual([]);
  });
});

describe('CLI QR payload parsing uses the strict shared four-key parser', () => {
  const link = `lemonbot://pair?backend=https%3A%2F%2Fdesktop.example&instance=instance-1&cluster=workspace-1&code=${'A'.repeat(43)}`;
  test('parses exactly backend/instance/cluster/code', () => {
    expect(parsePairUrl(link)).toEqual({ backendUrl: 'https://desktop.example', instanceId: 'instance-1', workspaceId: 'workspace-1', pairCode: 'A'.repeat(43) });
  });
  for (const invalid of [link.replace('&instance=instance-1', ''), `${link}&code=${'B'.repeat(43)}`, `${link}&token=secret`, link.replace('workspace-1', '%ZZ'), link.replace('instance-1', ''), link.replace('desktop.example', 'user%3Apassword%40desktop.example'), `${link}#fragment`]) {
    test('rejects missing/duplicate/unknown/malformed or credential-bearing fields', () => { expect(() => parsePairUrl(invalid)).toThrow(); });
  }
});
