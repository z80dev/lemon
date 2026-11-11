import { expect, test } from 'bun:test';
import type { BackendConfiguration } from '../../src/core/services';
import { productVersion } from '../../src/core/version';
import { joinTarget, nodeName, runUpCli, type UpDependencies } from '../../src/cli/up';
import type { ProcessInput } from '../../src/cli/lifecycle';

const release = (name = 'studio') => `curl 'https://github.com/z80dev/lemon/releases/download/v2026.11.1/join-node.sh' | bash -s -- '--name' '${name}' '--controller' 'ws://127.0.0.1:4040/ws' '--version' '2026.11.1' '--base-url' 'https://github.com/z80dev/lemon'`;
function harness(options: { existing?: boolean; online?: boolean; remote?: boolean; missing?: boolean; mismatch?: boolean; uncertain?: 'joined' | 'pending'; failure?: string; conflicts?: number; sessionPersistence?: boolean; setupFailure?: boolean; currentWrapper?: string | null; repairFailure?: boolean } = {}) {
  const stdout: string[] = [], stderr: string[] = [], calls: { executable: string; args: string[]; input?: ProcessInput }[] = [], requests: { path: string; body: Record<string, unknown> | undefined }[] = [];
  let exists = options.existing ?? false, online = options.online ?? false, enrollments = 0, issued = 0, conflicts = options.conflicts ?? 0;
  let execWrapper = options.currentWrapper;
  const machine = { id: 'machine_studio', nodeName: 'studio', name: 'Studio', status: online ? 'online' : 'offline' };
  const invite = () => ({ id: `invite_${++issued}`, machineId: machine.id, inviteCode: `${issued}`.repeat(43), joinCommand: release(machine.nodeName), status: 'pending' });
  const status = (roles: string[], state = 'ready', detail: string | null = null) => ({ schema: 1, manager: 'launchd', persistence: options.sessionPersistence ? 'session' : 'login', linger: null,
    units: roles.map(role => ({ role, name: role === 'worker' ? machine.nodeName : null, state, detail, action: 'unchanged', ...(role === 'worker' ? { execWrapper } : {}) })) });
  const dependencies: UpDependencies = {
    environment: { HOME: '/tmp/lifecycle-consumers-scratch', LEMON_BOT_CONTROL_URL: options.remote ? 'wss://remote.example/ws' : 'ws://127.0.0.1:4040/ws' },
    botPath: '/tmp/lemon-bot-source',
    terminal: { interactive: false, write(value) { stderr.push(value); }, sensitive() { throw new Error('Unexpected sensitive terminal output'); }, read: async () => '' },
    load: async () => ({ config: { controlUrl: options.remote ? 'wss://remote.example/ws' : 'ws://127.0.0.1:4040/ws', runtimeLauncher: options.remote ? undefined : '/tmp/lemon', dataDir: '/tmp/lifecycle-consumers-scratch/data', port: 45123 } as BackendConfiguration, key: new Uint8Array(32), controllerSource: 'environment' }),
    executable: async path => !path.endsWith('/lemon-bot') && !options.missing,
    readKey: () => 'LOCAL_KEY_PRIVATE', hostIdentity: async () => ({ nodeName: 'studio', displayName: 'Studio', ownerName: 'Ada' }),
    stdout(value) { stdout.push(value); }, stderr(value) { stderr.push(value); }, sleep: async () => {},
    spawn: async (executable, args, input) => {
      calls.push({ executable, args, input });
      if (args[0] === 'version') return { exitCode: 0, stdout: options.mismatch ? '2000.1.1\n' : `${productVersion}\n`, stderr: '' };
      if (args[0] === 'setup') return { exitCode: options.setupFailure ? 1 : 0, stdout: '', stderr: '' };
      if (args[0] === 'open') return { exitCode: 0, stdout: '', stderr: '' };
      const worker = args.includes('worker');
      let value = status(worker ? ['worker'] : options.remote ? ['backend'] : ['controller', 'backend']);
      let exitCode = 0;
      const wrapperOption = args.indexOf('--exec-wrapper');
      if (worker && args[1] === 'repair' && wrapperOption !== -1) execWrapper = args[wrapperOption + 1];
      if (worker && args[1] === 'install') {
        enrollments++;
        if (options.uncertain && enrollments === 1) { value = status(['worker'], 'needs_enrollment', 'enrollment_outcome_unknown'); exitCode = 1; }
        else { online = true; machine.status = 'online'; value = status(['worker'], 'online'); }
      } else if (worker) { value = status(['worker'], online ? 'online' : 'needs_reauthorization'); exitCode = online ? 0 : 1; }
      if (worker && args[1] === 'repair' && options.repairFailure) { value = status(['worker'], 'blocked', 'exec_wrapper_missing'); exitCode = 1; }
      if (options.failure === 'service') { value = status(['backend'], 'blocked', 'port_in_use_foreign'); exitCode = 1; }
      return { exitCode, stdout: JSON.stringify(value), stderr: '' };
    },
    fetch: (async (input, init) => {
      const url = new URL(String(input)), path = url.pathname.replace('/v1', '');
      const body = init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : undefined;
      requests.push({ path, body });
      expect(init?.redirect).toBe('manual'); expect(init?.credentials).toBe('omit');
      if (options.failure === path) throw new Error('PRIVATE raw response');
      if (path === '/auth/local') {
        expect(new Headers(init?.headers).get('Authorization')).toBe('Bearer LOCAL_KEY_PRIVATE');
        expect(body).toEqual({ displayName: 'Ada' }); return Response.json({ token: 'SESSION_PRIVATE' });
      }
      expect(new Headers(init?.headers).get('Authorization')).toBe('Bearer SESSION_PRIVATE');
      if (body) expect(body.clientNonce).toMatch(/^[A-Za-z0-9_-]{16,128}$/);
      if (path === '/auth/logout') return Response.json({ ok: true });
      if (path.endsWith('/reconnect')) return Response.json(invite());
      if (path.endsWith('/invites')) return Response.json({ items: [{ id: 'invite_1', status: options.uncertain }], nextCursor: null });
      if (path === `/machines/${machine.id}`) return Response.json(machine);
      if (path === '/machines' && body) {
        if (conflicts-- > 0) return Response.json({ error: { code: 'conflict' } }, { status: 409 });
        machine.nodeName = String(body.nodeName); exists = true;
        return Response.json({ machine, invite: invite() }, { status: 201 });
      }
      if (path === '/machines') return Response.json({ items: exists ? [machine] : [], nextCursor: null });
      throw new Error(`Unexpected route ${path}`);
    }) as typeof fetch,
  };
  return { dependencies, stdout, stderr, calls, requests, result: () => JSON.parse(stdout.at(-1)!), counts: () => ({ issued, enrollments }) };
}

test('fresh bootstrap enrolls once through stdin, signs out, and rerun never invites', async () => {
  const h = harness();
  expect(await runUpCli(['--json', '--no-open'], h.dependencies)).toBe(0);
  expect(h.result()).toMatchObject({ type: 'result', status: 'ready', machineId: 'machine_studio', port: 45123, persistence: 'login' });
  const install = h.calls.find(call => call.args.includes('--invite-code-stdin'))!;
  expect(install.input?.stdin).toBe('1'.repeat(43) + '\n');
  expect(install.args).toContain('ws://127.0.0.1:4040/ws');
  expect(install.args.join(' ')).not.toContain('1'.repeat(43));
  expect(h.stdout.join('') + h.stderr.join('')).not.toMatch(/LOCAL_KEY_PRIVATE|SESSION_PRIVATE|1111111111111111111111111111111111111111111/);
  expect(h.requests.at(-1)?.path).toBe('/auth/logout');
  expect(await runUpCli(['--json', '--no-open'], h.dependencies)).toBe(0);
  expect(h.counts()).toEqual({ issued: 1, enrollments: 1 });
  expect(h.stdout.map(line => JSON.parse(line)).filter(value => value.type === 'result')).toHaveLength(2);
});

test('missing runtime has pinned Bot installer; mismatched JSON runtime blocks', async () => {
  const missing = harness({ missing: true });
  expect(await runUpCli(['--json'], missing.dependencies)).toBe(1);
  expect(missing.result()).toMatchObject({ status: 'runtime_missing' });
  expect(missing.result().installCommand).toContain(`/releases/download/v${productVersion}/install.sh`);
  expect(missing.result().installCommand).toContain('--profile bot'); expect(missing.calls).toHaveLength(0);
  const mismatch = harness({ mismatch: true });
  expect(await runUpCli(['--json'], mismatch.dependencies)).toBe(1);
  expect(mismatch.result().status).toBe('needs_attention'); expect(mismatch.requests).toHaveLength(0);
});

test('remote controller installs backend only and skips local worker', async () => {
  const h = harness({ remote: true });
  expect(await runUpCli(['--json'], h.dependencies)).toBe(0);
  expect(h.calls.find(call => call.args[1] === 'install')?.args).toEqual(['service', 'install', 'backend', '--bot', '/tmp/lemon-bot-source', '--wait', '120', '--json']);
  expect(h.requests.map(request => request.path)).toEqual(['/auth/local', '/auth/logout']);
  expect(h.stdout.join('')).toContain('remote_controller');
});

for (const currentWrapper of [undefined, null, '/Applications/Old Worker.app/Contents/MacOS/Worker']) test(`online worker migrates ${currentWrapper ?? 'missing'} wrapper without an invite`, async () => {
  const wrapper = '/Applications/Lemon Bot.app/Contents/Helpers/Lemon Bot Worker.app/Contents/MacOS/Lemon Bot Worker';
  const h = harness({ existing: true, online: true, currentWrapper });
  expect(await runUpCli(['--json', '--no-open', '--worker-wrapper', wrapper], h.dependencies)).toBe(0);
  expect(h.calls.filter(call => call.args[1] === 'repair')).toHaveLength(1);
  expect(h.calls.find(call => call.args[1] === 'repair')?.args).toEqual(['service', 'repair', 'worker', '--name', 'studio', '--wait', '60', '--exec-wrapper', wrapper, '--json']);
  expect(h.counts()).toEqual({ issued: 0, enrollments: 0 });
  expect(h.requests.some(request => request.path.endsWith('/reconnect'))).toBe(false);
  expect(await runUpCli(['--json', '--no-open', '--worker-wrapper', wrapper], h.dependencies)).toBe(0);
  expect(h.calls.filter(call => call.args[1] === 'repair')).toHaveLength(1);
});

test('online worker already using requested wrapper remains unchanged', async () => {
  const wrapper = '/Applications/Lemon Bot.app/Contents/Helpers/Lemon Bot Worker.app/Contents/MacOS/Lemon Bot Worker';
  const h = harness({ existing: true, online: true, currentWrapper: wrapper });
  expect(await runUpCli(['--json', '--worker-wrapper', wrapper], h.dependencies)).toBe(0);
  expect(h.calls.filter(call => call.args[1] === 'repair')).toHaveLength(0);
  expect(h.counts()).toEqual({ issued: 0, enrollments: 0 });
});

test('failed wrapper migration does not mint a replacement invitation', async () => {
  const h = harness({ existing: true, online: true, repairFailure: true });
  expect(await runUpCli(['--json', '--worker-wrapper', '/Applications/Lemon Bot.app/Contents/MacOS/Worker'], h.dependencies)).toBe(1);
  expect(h.result().status).toBe('service_failed');
  expect(h.counts()).toEqual({ issued: 0, enrollments: 0 });
  expect(h.requests.some(request => request.path.endsWith('/reconnect'))).toBe(false);
  expect(h.requests.at(-1)?.path).toBe('/auth/logout');
});

test('offline worker repair also receives the requested signed wrapper', async () => {
  const wrapper = '/Applications/Lemon Bot.app/Contents/MacOS/Worker';
  const h = harness({ existing: true });
  expect(await runUpCli(['--json', '--worker-wrapper', wrapper], h.dependencies)).toBe(0);
  expect(h.calls.find(call => call.args[1] === 'repair')?.args).toContain('--exec-wrapper');
  expect(h.calls.find(call => call.args[1] === 'repair')?.args).toContain(wrapper);
});

test('online existing host gets no invite; parked credential uses one bound reconnect', async () => {
  const ready = harness({ existing: true, online: true });
  expect(await runUpCli(['--json'], ready.dependencies)).toBe(0); expect(ready.counts().issued).toBe(0);
  expect(ready.calls.filter(call => call.args[1] === 'repair')).toHaveLength(0);
  const parked = harness({ existing: true });
  expect(await runUpCli(['--json'], parked.dependencies)).toBe(0);
  expect(parked.requests.filter(request => request.path.endsWith('/reconnect'))).toHaveLength(1);
});

test('conflicting names try every suffix through -4', async () => {
  const h = harness({ conflicts: 3 });
  expect(await runUpCli(['--json'], h.dependencies)).toBe(0);
  expect(h.requests.filter(request => request.path === '/machines' && request.body).map(request => request.body?.nodeName)).toEqual(['studio', 'studio-2', 'studio-3', 'studio-4']);
});

for (const uncertain of ['joined', 'pending'] as const) test(`uncertain ${uncertain} enrollment reconciles once and never resends`, async () => {
  const h = harness({ uncertain });
  expect(await runUpCli(['--json'], h.dependencies)).toBe(uncertain === 'joined' ? 0 : 1);
  expect(h.requests.filter(request => request.path.endsWith('/invites'))).toHaveLength(1);
  expect(h.counts()).toEqual(uncertain === 'joined' ? { issued: 2, enrollments: 2 } : { issued: 1, enrollments: 1 });
  const codes = h.calls.filter(call => call.input?.stdin).map(call => call.input!.stdin);
  expect(new Set(codes).size).toBe(codes.length);
  expect(h.requests.at(-1)?.path).toBe('/auth/logout');
});

test('all post-auth failures still log out and never expose raw errors', async () => {
  const h = harness({ failure: '/machines' });
  expect(await runUpCli(['--json'], h.dependencies)).toBe(1);
  expect(h.result().status).toBe('enroll_failed'); expect(h.requests.at(-1)?.path).toBe('/auth/logout');
  expect(h.stdout.join('') + h.stderr.join('')).not.toContain('PRIVATE');
});

test('unit failure refuses owner sign-in; no-worker skips machines', async () => {
  const broken = harness({ failure: 'service' });
  expect(await runUpCli(['--json'], broken.dependencies)).toBe(1); expect(broken.requests).toHaveLength(0);
  const h = harness(); expect(await runUpCli(['--json', '--no-worker'], h.dependencies)).toBe(0);
  expect(h.requests.map(request => request.path)).toEqual(['/auth/local', '/auth/logout']);
});

test('interactive setup precedes units, linger prompts, open inherits terminal after logout', async () => {
  const h = harness({ sessionPersistence: true }); h.dependencies.terminal.interactive = true;
  h.dependencies.environment.SSH_TTY = '/dev/mock';
  expect(await runUpCli(['--json', '--worker-wrapper', '/Applications/Lemon Bot.app/Contents/Helpers/worker'], h.dependencies)).toBe(0);
  expect(h.calls.findIndex(call => call.args[0] === 'setup')).toBeLessThan(h.calls.findIndex(call => call.args[1] === 'install'));
  expect(h.calls.some(call => call.args.includes('--enable-linger'))).toBe(true);
  expect(h.calls.find(call => call.args.includes('--exec-wrapper'))?.args).toContain('/Applications/Lemon Bot.app/Contents/Helpers/worker');
  expect(h.calls.at(-1)).toMatchObject({ args: ['open', '--headless'], input: { attached: true, diagnostics: true } });
  const failed = harness({ setupFailure: true }); failed.dependencies.terminal.interactive = true;
  expect(await runUpCli(['--json'], failed.dependencies)).toBe(1); expect(failed.result().status).toBe('setup_required');
});

test('argument validation rejects duplicates and unsafe names', async () => {
  for (const args of [['--json', '--json'], ['--name'], ['--name', '-bad'], ['--worker-wrapper', 'relative'], ['--unexpected']]) {
    const h = harness(); expect(await runUpCli(args, h.dependencies)).toBe(2); expect(h.calls).toHaveLength(0);
  }
});

test('join parser preserves exact URL and source/release validation parity', () => {
  expect(joinTarget(release())).toEqual({ name: 'studio', controller: 'ws://127.0.0.1:4040/ws' });
  expect(joinTarget("bash '/x/join-node.sh' '--name' 'a' '--controller' 'wss://example/ws' '--source' '/Users/me/lemon'")).toEqual({ name: 'a', controller: 'wss://example/ws' });
  for (const bad of [release('a; rm -rf ~'), release().replace('ws://127.0.0.1:4040/ws', 'ws://evil/ws'), release().replace('/ws\'', '/ws?token=x\''), release().replace('https://github.com/z80dev/lemon\'', 'http://github.com/z80dev/lemon\''), release().replace("'2026.11.1' '--base-url'", "'$(id)' '--base-url'")]) expect(() => joinTarget(bad)).toThrow();
  expect(nodeName('--Ünïcode Host!')).toBe('ncodehost'); expect(nodeName('!!!')).toBe('lemon-host');
});
