import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import type { Route } from '../../src/core/services';
import { ApiError } from '../../src/core/errors';
import { createMachineSshSetup, machineSshEnvironment, refreshMachineTunnelStatus, uninstallMachineTunnel, type MachineSshCommand, type MachineSshHooks, type MachineSshResult } from '../../src/runtime/machine-ssh';
import { fixture, type TestRuntimeFixture } from './fixture';

interface Harness {
  f: TestRuntimeFixture;
  commands: MachineSshCommand[];
  issues: { machine: P.Machine; options: { tunnelPort?: number }; code: string }[];
  revoked: string[];
  probe: MachineSshResult;
  tunnel: MachineSshResult;
  check: MachineSshResult;
  install: MachineSshResult;
  ready: boolean;
  hooks: MachineSshHooks;
}
const route: Route = { method: 'POST', path: '/v1/machines/ssh', auth: 'admin', handler() {} };
const probeOutput = 'host=Studio.Worker\ncomputer=Studio Worker\nos=Darwin\narch=arm64\nservice=launchd\nlinger=unknown\nfree=4044\nfree=4045\nfree=4100\n';
function receipt(role: string, name: string, state = 'online', detail: string | null = null, persistence = 'login'): string {
  return JSON.stringify({ schema: 1, persistence, manager: 'launchd', units: [{ role, name, state, detail, installed: true, loaded: true }] });
}
function harness(): Harness {
  const f = fixture();
  f.services.config.controlUrl = 'ws://127.0.0.1:4040/ws';
  f.services.config.publicUrl = 'http://127.0.0.1:4100';
  f.services.config.port = 4100;
  f.services.config.runtimeLauncher = '/fixture/lemon';
  f.rpc = async method => { if (method === 'node.pair.preview') return { reachability: 'loopback_only', nodeGateway: { available: true, port: 4044 } }; throw new Error(`Unexpected ${method}`); };
  const commands: MachineSshCommand[] = [];
  const issues: { machine: P.Machine; options: { tunnelPort?: number }; code: string }[] = [];
  const revoked: string[] = [];
  let online = false;
  const state: Harness = {
    f, commands, issues, revoked,
    probe: { exitCode: 0, stdout: probeOutput, stderr: '' } as MachineSshResult,
    tunnel: { exitCode: 0, stdout: receipt('tunnel', 'studio.worker'), stderr: '' } as MachineSshResult,
    check: { exitCode: 0, stdout: '{"service":"lemon-node-gateway","ok":true}\n{"product":"lemon_bot"}', stderr: '' } as MachineSshResult,
    install: { exitCode: 0, stdout: `LEMON_SSH_INSTALL_STARTED\n${receipt('worker', 'studio.worker')}`, stderr: '' } as MachineSshResult,
    ready: true,
    hooks: null as unknown as MachineSshHooks,
  };
  state.hooks = {
    async run(command) {
      commands.push(command);
      if (command.argv[0] === '/fixture/lemon') return state.tunnel;
      if (command.stdin.includes('code=')) { if (state.install.exitCode === 0) online = true; return state.install; }
      if (command.stdin.includes('/healthz')) return state.check;
      return state.probe;
    },
    async issue(_context, machine, options) {
      const code = String.fromCharCode(65 + issues.length).repeat(43);
      issues.push({ machine, options, code });
      const invitation: P.MachineInvite = f.services.resource('machine_invite', { machineId: machine.id, inviteCode: code, joinCommand: `curl -fsSL 'https://downloads.example/releases/download/v2026.11.1/join-node.sh' | bash -s -- '--name' '${machine.nodeName}' '--controller' '${options.tunnelPort ? `ws://127.0.0.1:${options.tunnelPort}/ws` : 'wss://nodes.example/ws'}' '--version' '2026.11.1' '--base-url' 'https://downloads.example'`, expiresAtMs: f.services.now() + 900_000, status: 'pending', enrollment: 'waiting_for_join', lastError: null });
      f.store.put('machineInvites', invitation); return invitation;
    },
    async revokeInvite(_actor, invitation) { revoked.push(invitation.id); f.store.put('machineInvites', f.services.update(invitation, { status: 'revoked', inviteCode: '', joinCommand: '' })); },
    async refreshMachines() {
      if (online) for (const machine of f.store.list<P.Machine>('machines', value => value.nodeName === 'studio.worker')) f.store.put('machines', f.services.update(machine, { nodeId: machine.nodeId ?? 'node_studio', status: 'online' }));
    },
    async ensureMachineRuntimeReady() { if (!state.ready) throw new ApiError('capability_unavailable', 'Missing required worker features.'); },
  };
  return state;
}
async function start(h: Harness, nonce = 'setup-one', machineId?: string) {
  const job = createMachineSshSetup(h.f.services, h.hooks);
  const body: P.MachineSshSetupRequest = { clientNonce: nonce, sshDestination: 'me@studio', ...(machineId ? { machineId } : {}) };
  const initial = job.start(h.f.context(route, body), body);
  await job.drain();
  return { job, initial, result: job.get(h.f.alice, initial.id), body };
}

describe('SSH machine setup state machine', () => {
  test('persists every step, installs one worker, verifies bot readiness and scopes setup events to its initiator', async () => {
    const h = harness(); const steps: string[] = []; const audiences: unknown[] = [];
    h.f.services.events.subscribe((event, audience) => { if (event.event === 'machine_setup.upserted') { steps.push((event.payload as P.MachineSetup).step); audiences.push(audience); } });
    try {
      const { initial, result } = await start(h);
      expect(initial.state).toBe('running');
      expect(result).toMatchObject({ state: 'succeeded', step: 'online', persistence: 'login', failure: null });
      expect(result.finishedAtMs).not.toBeNull();
      expect([...new Set(steps)]).toEqual(['checking_ssh', 'opening_tunnel', 'issuing_invite', 'installing', 'verifying', 'online']);
      expect(audiences.every(value => JSON.stringify(value) === JSON.stringify({ userIds: [h.f.alice.userId] }))).toBe(true);
      const machine = h.f.store.require<P.Machine>('machines', result.machineId!);
      expect(machine).toMatchObject({ name: 'Studio Worker', nodeName: 'studio.worker', nodeId: 'node_studio', status: 'online', link: { kind: 'ssh_tunnel', sshDestination: 'me@studio', nodePort: 4044, productPort: 4100, tunnel: { state: 'online' } } });
      expect(h.issues).toHaveLength(1);
      expect(h.issues[0]!.options).toEqual({ tunnelPort: 4044 });
      const tunnel = h.commands.find(command => command.argv[0] === '/fixture/lemon')!;
      expect(tunnel.argv).toEqual(['/fixture/lemon', 'service', 'install', 'tunnel', '--name', 'studio.worker', '--ssh', 'me@studio', '--node-port', '4044', '--gateway-port', '4044', '--product-port', '4100', '--backend-port', '4100', '--wait', '15', '--json']);
      const install = h.commands.find(command => command.stdin.includes('code='))!;
      expect(install.timeoutMs).toBe(600_000);
      expect(install.stdin).toContain('"$code" | bash "$tmp" "$@"');
      expect(install.stdin).toContain('--cwd "$HOME" --code-stdin --json');
      expect(install.stdin).toContain("--proto '=https' --proto-redir '=https'");
      expect(install.argv.join(' ')).not.toContain(h.issues[0]!.code);
      expect(JSON.stringify(install.env)).not.toContain(h.issues[0]!.code);
      expect(JSON.stringify(result)).not.toContain(h.issues[0]!.code);
      for (const command of h.commands) { expect(command.env).not.toHaveProperty('LEMON_CONTROL_PLANE_OPERATOR_TOKEN'); expect(JSON.stringify(command)).not.toContain(h.f.services.config.operatorToken); }
      const probe = h.commands[0]!;
      expect(probe.timeoutMs).toBe(30_000);
      expect(probe.argv.slice(-5)).toEqual(['-T', '--', 'me@studio', 'sh', '-s']);
      expect(probe.argv).toContain('StrictHostKeyChecking=accept-new');
      expect(probe.argv).toContain('ForwardAgent=no'); expect(probe.argv).toContain('ForwardX11=no'); expect(probe.argv).toContain('ControlPath=none'); expect(probe.argv).toContain('PermitLocalCommand=no');
    } finally { h.f.store.close(); }
  });

  test('the SSH environment is an exact allowlist, including LC_ALL=C', () => {
    expect(machineSshEnvironment({ HOME: '/home/me', USER: 'me', LOGNAME: 'me', PATH: '/bin', SSH_AUTH_SOCK: '/agent', LC_ALL: 'fr_FR', LEMON_CONTROL_PLANE_OPERATOR_TOKEN: 'secret', LEMON_BOT_ENCRYPTION_KEY: 'key', AWS_SECRET_ACCESS_KEY: 'aws', BASH_ENV: '/evil', ENV: '/evil' })).toEqual({ HOME: '/home/me', USER: 'me', LOGNAME: 'me', PATH: '/bin', SSH_AUTH_SOCK: '/agent', LC_ALL: 'C' });
  });

  test('nonce replay returns current durable state and conflicts bind both destination and machine', async () => {
    const h = harness();
    const { promise: wait, resolve: release } = Promise.withResolvers<void>();
    const run = h.hooks.run!;
    h.hooks.run = async command => { await wait; return run(command); };
    const job = createMachineSshSetup(h.f.services, h.hooks);
    const body = { clientNonce: 'fixed', sshDestination: 'me@studio' };
    try {
      const first = job.start(h.f.context(route, body), body);
      expect(job.start(h.f.context(route, body), body).id).toBe(first.id);
      expect(() => job.start(h.f.context(route, body), { ...body, name: 'Different' })).toThrow('nonce');
      expect(() => job.start(h.f.context(route, body), { ...body, clientNonce: 'another' })).toThrow('already running');
      release(); await job.drain();
      expect(job.start(h.f.context(route, body), body)).toMatchObject({ id: first.id, state: 'succeeded' });
      expect(h.issues).toHaveLength(1);
      const current = job.get(h.f.alice, first.id);
      const again = job.start(h.f.context(route, body), { ...body, machineId: current.machineId!, clientNonce: 'repair' });
      expect(() => job.start(h.f.context(route, body), { ...body, machineId: current.machineId!, sshDestination: 'other@studio', clientNonce: 'other' })).toThrow('existing SSH destination');
      await job.drain(); expect(job.get(h.f.alice, again.id).state).toBe('succeeded');
    } finally { release(); await job.drain(); h.f.store.close(); }
  });

  test('only initiator or owner can read jobs and only owner/admin can start them', async () => {
    const h = harness();
    try {
      const admin = { ...h.f.bob, role: 'admin' as const };
      const job = createMachineSshSetup(h.f.services, h.hooks);
      const body = { clientNonce: 'permissions', sshDestination: 'me@studio' };
      expect(() => job.start(h.f.context(route, body, h.f.bob), body)).toThrow('Only an owner');
      const initial = job.start(h.f.context(route, body), body);
      expect(() => job.get(admin, initial.id)).toThrow('not found');
      expect(() => job.get({ ...h.f.alice, kind: 'bot' }, initial.id)).toThrow('not found');
      await job.drain();
      expect(job.get(h.f.alice, initial.id).state).toBe('succeeded');
    } finally { h.f.store.close(); }
  });

  test.each(['-oProxyCommand=evil', 'me@host;touch /tmp/x', '@host', 'me@', 'me@host\nother', 'a'.repeat(256)])('rejects unsafe SSH destination %s before persistence or spawning', unsafe => {
    const h = harness();
    try { const job = createMachineSshSetup(h.f.services, h.hooks); const body = { clientNonce: 'invalid', sshDestination: unsafe }; expect(() => job.start(h.f.context(route, body), body)).toThrow('valid SSH'); expect(h.f.store.list('machineSetups')).toHaveLength(0); expect(h.commands).toHaveLength(0); }
    finally { h.f.store.close(); }
  });

  const failures: { name: string; code: P.MachineSetupFailure; configure(h: Harness): void }[] = [
    { name: 'unreachable SSH', code: 'ssh_unreachable', configure(h) { h.probe = { exitCode: 255, stdout: '', stderr: 'ssh: connect: No route to host' }; } },
    { name: 'SSH authentication', code: 'ssh_auth_failed', configure(h) { h.probe = { exitCode: 255, stdout: '', stderr: 'Permission denied (publickey).' }; } },
    { name: 'changed SSH key', code: 'ssh_host_key_changed', configure(h) { h.probe = { exitCode: 255, stdout: '', stderr: 'REMOTE HOST IDENTIFICATION HAS CHANGED' }; } },
    { name: 'probe timeout', code: 'ssh_unreachable', configure(h) { h.probe.timedOut = true; } },
    { name: 'unsupported OS', code: 'unsupported_host', configure(h) { h.probe.stdout = probeOutput.replace('Darwin', 'Windows'); } },
    { name: 'unsupported architecture', code: 'unsupported_host', configure(h) { h.probe.stdout = probeOutput.replace('arm64', 'sparc'); } },
    { name: 'missing curl', code: 'unsupported_host', configure(h) { h.probe = { exitCode: 1, stdout: '', stderr: 'unsupported_host' }; } },
    { name: 'occupied product port', code: 'port_in_use', configure(h) { h.probe.stdout = probeOutput.replace('free=4100\n', ''); } },
    { name: 'occupied node range', code: 'port_in_use', configure(h) { h.probe.stdout = probeOutput.replace(/free=404[45]\n/g, ''); } },
    { name: 'tunnel forward refused', code: 'forward_refused', configure(h) { h.tunnel = { exitCode: 1, stdout: receipt('tunnel', 'studio.worker', 'failed', 'forward_refused'), stderr: '' }; } },
    { name: 'tunnel port occupied', code: 'port_in_use', configure(h) { h.tunnel = { exitCode: 1, stdout: receipt('tunnel', 'studio.worker', 'failed', 'remote_port_in_use'), stderr: '' }; } },
    { name: 'tunnel auth failed', code: 'ssh_auth_failed', configure(h) { h.tunnel = { exitCode: 1, stdout: receipt('tunnel', 'studio.worker', 'failed', 'ssh_auth_failed'), stderr: 'Permission denied' }; } },
    { name: 'tunnel changed host key', code: 'ssh_host_key_changed', configure(h) { h.tunnel = { exitCode: 0, stdout: receipt('tunnel', 'studio.worker', 'failed', 'host_key_changed'), stderr: '' }; } },
    { name: 'wrong gateway health', code: 'forward_refused', configure(h) { h.check.stdout = '{"ok":true}'; } },
    { name: 'wrong product health', code: 'forward_refused', configure(h) { h.check.stdout = '{"service":"lemon-node-gateway"}'; } },
    { name: 'install failure before enrollment', code: 'runtime_install_failed', configure(h) { h.install = { exitCode: 1, stdout: '', stderr: 'Runtime download failed; enrollment was not attempted' }; } },
    { name: 'unsupported installer host', code: 'unsupported_host', configure(h) { h.install = { exitCode: 1, stdout: '', stderr: 'unsupported architecture' }; } },
    { name: 'enrollment rejected', code: 'enroll_failed', configure(h) { h.install = { exitCode: 2, stdout: receipt('worker', 'studio.worker', 'needs_enrollment'), stderr: 'Enrollment attempted' }; } },
    { name: 'installed reconnecting worker', code: 'service_failed', configure(h) { h.install = { exitCode: 3, stdout: receipt('worker', 'studio.worker', 'reconnecting'), stderr: 'Installed but not online yet' }; } },
    { name: 'SSH disconnect after start', code: 'enroll_outcome_unknown', configure(h) { h.install = { exitCode: 255, stdout: 'LEMON_SSH_INSTALL_STARTED\n', stderr: 'Connection closed' }; } },
    { name: 'install timeout', code: 'enroll_outcome_unknown', configure(h) { h.install.timedOut = true; } },
    { name: 'missing enrollment receipt', code: 'enroll_outcome_unknown', configure(h) { h.install.stdout = 'not JSON'; } },
    { name: 'worker conflict receipt', code: 'enroll_failed', configure(h) { h.install.stdout = receipt('worker', 'studio.worker', 'conflict'); } },
    { name: 'not bot ready', code: 'not_bot_ready', configure(h) { h.ready = false; } },
    { name: 'controller disconnected', code: 'controller_unavailable', configure(h) { h.f.services.lemon.connected = false; } },
    { name: 'gateway unavailable', code: 'controller_unavailable', configure(h) { h.f.rpc = async () => ({ reachability: 'loopback_only', nodeGateway: { available: false, port: null } }); } },
  ];
  for (const failure of failures) test(`classifies ${failure.name}`, async () => {
    const h = harness(); failure.configure(h);
    try { const { result } = await start(h); expect(result.state).toBe('failed'); expect(result.failure?.code).toBe(failure.code); expect(result.finishedAtMs).not.toBeNull(); if (result.step === 'checking_ssh' || result.step === 'opening_tunnel') expect(h.issues).toHaveLength(0); }
    finally { h.f.store.close(); }
  });

  test('service failure keeps lifecycle persistence and stable worker detail', async () => {
    const h = harness(); h.install = { exitCode: 3, stdout: receipt('worker', 'studio.worker', 'needs_reauthorization', 'loopback_listener_not_owned', 'session'), stderr: '' };
    try { const { result } = await start(h); expect(result).toMatchObject({ state: 'failed', persistence: 'session', failure: { code: 'service_failed', detail: 'loopback_listener_not_owned' } }); }
    finally { h.f.store.close(); }
  });

  test('connected incompatible workers project not_bot_ready even when refresh marks them pending', async () => {
    const h = harness(); const refresh = h.hooks.refreshMachines;
    h.ready = false;
    h.hooks.refreshMachines = async () => {
      await refresh();
      for (const machine of h.f.store.list<P.Machine>('machines', value => value.nodeName === 'studio.worker' && value.nodeId !== null)) h.f.store.put('machines', h.f.services.update(machine, { status: 'pending' }));
    };
    try { const { result } = await start(h); expect(result.failure?.code).toBe('not_bot_ready'); }
    finally { h.f.store.close(); }
  });

  test('bounded diagnostics redact enrollment codes and operator authority and retain only eight lines', async () => {
    const h = harness();
    h.install = { exitCode: 2, stdout: '', stderr: `code=${'A'.repeat(43)}\nBearer ${h.f.services.config.operatorToken}\n${Array.from({ length: 30 }, (_, index) => `line ${index}`).join('\n')}\n${'A'.repeat(43)}\n${h.f.services.config.operatorToken}\n` };
    try { const { result } = await start(h); const detail = result.failure!.detail!; expect(detail.split('\n').length).toBeLessThanOrEqual(8); expect(detail.length).toBeLessThanOrEqual(2048); expect(detail).not.toContain('A'.repeat(43)); expect(detail).not.toContain(h.f.services.config.operatorToken); expect(detail).not.toContain('line 0\n'); }
    finally { h.f.store.close(); }
  });

  test('a reconnect reuses reserved ports and issues a bound repair with a fresh code after an uncertain outcome', async () => {
    const h = harness(); h.install = { exitCode: 255, stdout: 'LEMON_SSH_INSTALL_STARTED\n', stderr: 'Connection lost' };
    try {
      const first = await start(h);
      expect(first.result.failure?.code).toBe('enroll_outcome_unknown');
      const machine = h.f.store.require<P.Machine>('machines', first.result.machineId!);
      h.f.store.put('machines', h.f.services.update(machine, { nodeId: 'durable_node', status: 'offline' }));
      h.probe.stdout = probeOutput.replace(/free=404[45]\n|free=4100\n/g, '');
      h.install = { exitCode: 0, stdout: receipt('worker', 'studio.worker'), stderr: '' };
      const second = await start(h, 'repair', machine.id);
      expect(second.result.state).toBe('succeeded');
      expect(h.issues).toHaveLength(2); expect(h.issues[1]!.machine.nodeId).toBe('durable_node'); expect(h.issues[1]!.options).toEqual({ tunnelPort: 4044 });
      expect(h.revoked).toHaveLength(1);
      const installs = h.commands.filter(command => command.stdin.includes('code=')); expect(installs).toHaveLength(2);
      expect(installs[1]!.stdin).not.toContain(h.issues[0]!.code); expect(installs[1]!.stdin).toContain(h.issues[1]!.code);
      expect(h.f.store.metadata(`machineSshEnrollmentUncertain:${machine.id}`)).toBe(false);
    } finally { h.f.store.close(); }
  });

  test('an uncertain enrollment without durable identity fails closed without issuing or sending another code', async () => {
    const h = harness(); h.install = { exitCode: 255, stdout: 'LEMON_SSH_INSTALL_STARTED\n', stderr: 'Connection lost' };
    try { const first = await start(h); const second = await start(h, 'repair', first.result.machineId!); expect(second.result.failure?.code).toBe('enroll_outcome_unknown'); expect(h.issues).toHaveLength(1); expect(h.commands.filter(command => command.stdin.includes('code='))).toHaveLength(1); expect(h.revoked).toHaveLength(0); }
    finally { h.f.store.close(); }
  });

  test('backend restart persists interrupted terminal jobs and replays their nonce without restarting SSH', async () => {
    const h = harness();
    try {
      const body = { clientNonce: 'restart', sshDestination: 'me@studio' };
      const interrupted: P.MachineSetup = h.f.services.resource('machine_setup', { machineId: null, sshDestination: body.sshDestination, step: 'installing', state: 'running', failure: null, persistence: null, finishedAtMs: null });
      h.f.store.put('machineSetups', interrupted);
      h.f.store.setMetadata(`machineSshSetup:${interrupted.id}`, { userId: h.f.alice.userId, nonce: body.clientNonce, fingerprint: h.f.services.mutations.digest({ sshDestination: body.sshDestination, name: null, machineId: null }) });
      const restarted = createMachineSshSetup(h.f.services, h.hooks);
      const recovered = restarted.start(h.f.context(route, body), body);
      expect(recovered).toMatchObject({ id: interrupted.id, state: 'failed', failure: { code: 'interrupted' } });
      expect(h.f.store.require<P.MachineSetup>('machineSetups', interrupted.id).finishedAtMs).not.toBeNull();
      await restarted.drain(); expect(h.commands).toHaveLength(0);
    } finally { h.f.store.close(); }
  });

  test('routable controllers use direct invites and skip tunnel installation', async () => {
    const h = harness(); h.f.rpc = async () => ({ reachability: 'routable', nodeGateway: { available: true, port: 4044 } });
    try { const { result } = await start(h); expect(result.state).toBe('succeeded'); expect(h.issues[0]!.options).toEqual({}); expect(h.f.store.require<P.Machine>('machines', result.machineId!).link).toEqual({ kind: 'direct' }); expect(h.commands.filter(command => command.argv[0] === '/fixture/lemon')).toHaveLength(0); }
    finally { h.f.store.close(); }
  });

  test('source invites remain data, shell-quote apostrophes, and use a temporary script with stdin code', async () => {
    const h = harness(); const issue = h.hooks.issue;
    h.hooks.issue = async (context, machine, options) => { const invitation = await issue(context, machine, options); return { ...invitation, joinCommand: `bash '/home/me/a'\\''b/scripts/join-node.sh' '--name' '${machine.nodeName}' '--controller' 'ws://127.0.0.1:${options.tunnelPort}/ws' '--source' '/home/me/a'\\''b'` }; };
    try { const { result } = await start(h); expect(result.state).toBe('succeeded'); const install = h.commands.find(command => command.stdin.includes('code='))!; expect(install.stdin).toContain("source='/home/me/a'\\''b'"); expect(install.stdin).toContain('cp "$source/scripts/join-node.sh" "$tmp"'); }
    finally { h.f.store.close(); }
  });
});

describe('SSH tunnel lifecycle projection', () => {
  test('loads all tunnel states with one status call, caches ten seconds and never treats query failure as stopped', async () => {
    const h = harness(); let calls = 0; let now = 100_000;
    h.f.services.now = () => now;
    const link: P.MachineLink = { kind: 'ssh_tunnel', sshDestination: 'me@studio', nodePort: 4044, productPort: 4100, tunnel: { state: 'unknown', detail: null, checkedAtMs: null } };
    h.f.store.put('machines', { ...h.f.machine, link });
    const second = { ...h.f.machine, id: 'second_machine', nodeName: 'second', link }; h.f.store.put('machines', second);
    const commands: MachineSshCommand[] = [];
    const run = async (command: MachineSshCommand) => { calls++; commands.push(command); return { exitCode: 0, stdout: JSON.stringify({ schema: 1, persistence: 'login', units: [{ role: 'tunnel', name: h.f.machine.nodeName, state: 'reconnecting', detail: 'host_unreachable' }, { role: 'tunnel', name: second.nodeName, state: 'failed', detail: 'host_key_changed' }] }), stderr: '' }; };
    try {
      await Promise.all([refreshMachineTunnelStatus(h.f.services, run), refreshMachineTunnelStatus(h.f.services, run)]);
      expect(calls).toBe(1); expect(commands[0]!.argv).toEqual(['/fixture/lemon', 'service', 'status', '--json']);
      expect(h.f.store.require<P.Machine>('machines', h.f.machine.id).link).toMatchObject({ tunnel: { state: 'reconnecting', detail: 'host_unreachable', checkedAtMs: now } });
      expect(h.f.store.require<P.Machine>('machines', second.id).link).toMatchObject({ tunnel: { state: 'failed', detail: 'host_key_changed' } });
      now += 9999; await refreshMachineTunnelStatus(h.f.services, run); expect(calls).toBe(1);
      now++; await refreshMachineTunnelStatus(h.f.services, async () => { calls++; throw new Error('launcher unavailable'); });
      expect(calls).toBe(2); expect(h.f.store.require<P.Machine>('machines', second.id).link).toMatchObject({ tunnel: { state: 'unknown', detail: null, checkedAtMs: now } });
    } finally { h.f.store.close(); }
  });

  test('uninstall failure is audited but does not block revocation, and direct machines never spawn', async () => {
    const h = harness(); const commands: MachineSshCommand[] = [];
    const machine: P.Machine = { ...h.f.machine, link: { kind: 'ssh_tunnel', sshDestination: 'me@studio', nodePort: 4044, productPort: null, tunnel: { state: 'online', detail: null, checkedAtMs: null } } };
    try {
      await uninstallMachineTunnel(h.f.services, h.f.alice, machine, async command => { commands.push(command); return { exitCode: 1, stdout: '', stderr: 'failed' }; });
      expect(commands[0]!.argv).toEqual(['/fixture/lemon', 'service', 'uninstall', 'tunnel', '--name', machine.nodeName, '--json']);
      expect(h.f.store.list<P.AuditRecord>('auditRecords').at(-1)).toMatchObject({ action: 'machine.tunnel_uninstall', outcome: 'failed', resourceId: machine.id });
      await uninstallMachineTunnel(h.f.services, h.f.alice, { ...machine, link: { kind: 'direct' } }, async () => { throw new Error('must not spawn'); });
      await uninstallMachineTunnel(h.f.services, h.f.alice, { ...machine, link: undefined }, async () => { throw new Error('must not spawn'); });
      expect(commands).toHaveLength(1);
      await uninstallMachineTunnel(h.f.services, h.f.alice, machine, async () => ({ exitCode: 0, stdout: receipt('tunnel', machine.nodeName, 'stopped'), stderr: '' }));
      expect(h.f.store.list<P.AuditRecord>('auditRecords').some(audit => audit.action === 'machine.tunnel_uninstall' && audit.outcome === 'succeeded')).toBe(true);
    } finally { h.f.store.close(); }
  });
});
