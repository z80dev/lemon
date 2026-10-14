import { afterEach, describe, expect, test } from 'bun:test';
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, LemonService, Principal, RequestContext, Route } from '../../src/core/services';
import { Store } from '../../src/core/store';
import { installHelpers } from '../../src/core/helpers';
import { createAccessService } from '../../src/core/auth';
import { createEventService } from '../../src/core/events';
import { createMutationService } from '../../src/core/mutations';
import { canonicalNetworkRule, createHostRoutes, createHostServices, type HostServices, type ReviewedSetup } from '../../src/enterprise/host';
import { createPolicyServices } from '../../src/enterprise/policy';

/** This is an actual destination executable, not a synthesized RPC receipt. It
 * journals performed effects on disk, checks them through probeArgv, and executes
 * reviewed setup/check scripts as separate child processes with local secrets. */
const driverSource = `
import { appendFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
const [directory, mode, behavior] = process.argv.slice(2);
const operation = JSON.parse(await Bun.stdin.text());
const path = join(directory, operation.operationId + '.json');
appendFileSync(join(directory, 'driver.log'), JSON.stringify({id:operation.operationId, mode, kind:operation.kind, phase:operation.phase, argv:process.argv.slice(2), input:operation}) + '\\n');
let answer;
if (operation.kind === 'inspect') {
  const inspection = existsSync(join(directory,'inspection.json')) ? JSON.parse(readFileSync(join(directory,'inspection.json'),'utf8')) : {hostState:'awake',inactiveSinceMs:0};
  answer = {...inspection,environmentRoot:operation.environmentRoot ?? join(directory,'environment'),isolatedEnvironment:!operation.environmentRoot || operation.environmentRoot === join(directory,'environment'),lastBackupAtMs:1799999990000,state:'succeeded',exitCode:0};
} else if (mode === 'probe') {
  answer = existsSync(path) ? JSON.parse(readFileSync(path,'utf8')) : {state:'not_found',exitCode:null};
} else {
  answer = {state:'succeeded',exitCode:0};
  if (operation.kind === 'network') {
    writeFileSync(join(directory,'firewall.json'), JSON.stringify(operation));
    answer.appliedRevision = operation.policy.revision;
  } else if (operation.kind === 'egress') {
    writeFileSync(join(directory,'route.json'), JSON.stringify(operation));
    answer.enabled=operation.enabled;answer.authenticated=true;answer.encrypted=behavior!=='unencrypted';
  } else if (operation.kind === 'setup') {
    const local = JSON.parse(readFileSync(join(directory,'secrets.json'),'utf8'));
    const env = {PATH:process.env.PATH,HOME:directory};
    for (const name of operation.secretNames) env[name] = local[name];
    const child = Bun.spawn(['/bin/sh','-c',operation.script], {cwd:directory,env,stdout:'pipe',stderr:'pipe'});
    const stdout = await new Response(child.stdout).text();
    const stderr = await new Response(child.stderr).text();
    answer.exitCode = await child.exited;
    for (const name of operation.secretNames) delete env[name];
    // Intentionally secret-bearing child output tests that the backend never
    // projects any raw output, even when the destination driver misbehaves.
    process.stdout.write(stdout + stderr);
    answer.destinationSecretsOnly=true;answer.secretsWiped=true;
  } else if (operation.kind === 'host') {
    if (behavior === 'fail') answer.state='failed';
    else if (behavior === 'skip') { answer.state='skipped';answer.skipReason='already_current'; }
    else {
      if (operation.action === 'delete_environment' || operation.action === 'recreate_environment') {
        if (operation.environmentRoot !== join(directory,'environment')) throw new Error('Unsafe test root.');
        rmSync(operation.environmentRoot,{recursive:true,force:true});
        if (operation.action === 'recreate_environment') mkdirSync(operation.environmentRoot);
      }
      writeFileSync(join(directory,'host-effect.json'), JSON.stringify(operation));
    }
    answer.safePoint=behavior!=='unsafe';answer.retainedUserHome=true;answer.retainedSSH=true;answer.retainedDisk=true;answer.retainedIdentity=true;answer.environmentRoot=operation.environmentRoot;answer.isolatedEnvironment=operation.environmentRoot===join(directory,'environment');
    if (operation.inactivePolicy) Object.assign(answer,JSON.parse(readFileSync(join(directory,'inspection.json'),'utf8')));
  }
  writeFileSync(path,JSON.stringify(answer));
}
if (mode === 'apply' && behavior === 'lose') process.exit(0);
const receipt = {type:'lemon_bot_host_result',version:1,operationId:behavior==='wrong'&&mode==='apply'?'wrong_operation':operation.operationId,machineId:operation.machineId,configDigest:behavior==='wrong_config'&&mode==='apply'?'wrong_config':operation.configDigest,inputDigest:behavior==='wrong_input'&&mode==='apply'?'wrong_input':operation.inputDigest,...answer};
process.stdout.write('\\n' + JSON.stringify(receipt) + '\\n');
`;

const ptyFrame = z.discriminatedUnion('type', [
  z.object({ type: z.literal('ready') }),
  z.object({ type: z.literal('output'), dataBase64: z.string() }),
  z.object({ type: z.literal('exit'), code: z.number().int() }),
]);
interface Shell {
  process: Bun.Subprocess<'pipe', 'pipe', 'ignore'>;
  input: Bun.FileSink;
  seq: number;
  streamed: Promise<void>;
}
class ActualPTY implements LemonService {
  connected = true;
  methods = ['node.shell.open', 'node.shell.input', 'node.shell.close'];
  private listeners = new Set<(event: string, payload: unknown) => void>();
  private connections = new Set<() => void>();
  readonly shells = new Map<string, Shell>();
  readonly calls: { method: string; params: Record<string, unknown> }[] = [];
  onEvent(listener: (event: string, payload: unknown) => void) { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; }
  onConnected(listener: () => void) { this.connections.add(listener); return () => { this.connections.delete(listener); }; }
  start() { this.connected = true; for (const listener of this.connections) listener(); }
  async close() {
    this.connected = false;
    const shells = [...this.shells.values()];
    // Closing the worker-owned pipe is the native owner-disconnect path; the
    // helper closes the PTY and reaps its child before emitting its exit frame.
    for (const shell of shells) shell.input.end();
    await Promise.all(shells.map(shell => shell.streamed));
  }
  private async packet(shell: Shell, value: unknown) {
    const data = Buffer.from(JSON.stringify(value)), header = Buffer.alloc(4);
    header.writeUInt32BE(data.length);
    shell.input.write(header); shell.input.write(data); await shell.input.flush();
    data.fill(0);
  }
  async call<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    this.calls.push({ method, params });
    let response: unknown;
    if (method === 'node.shell.open') {
      const shellId = `shell_${this.calls.length}`;
      const python = Bun.which('python3'); if (!python) throw new Error('Native node PTY requires python3.');
      // Use the worker's actual pty.fork helper, not script(1), whose macOS
      // terminal setup expects its own stdin to be a terminal rather than a pipe.
      const helper = join(import.meta.dir, '../../../../../apps/coding_agent/priv/node_pty.py');
      const processHandle = Bun.spawn([python, helper, String(params.cwd), '/bin/bash', String(params.cols ?? 80), String(params.rows ?? 24)], {
        stdin: 'pipe', stdout: 'pipe', stderr: 'ignore', env: { PATH: process.env.PATH, HOME: String(params.cwd), PS1: '', PS2: '', PROMPT_COMMAND: '' },
      });
      const shell: Shell = { process: processHandle, input: processHandle.stdin, seq: 0, streamed: Promise.resolve() };
      let resolveReady!: () => void, rejectReady!: (error: Error) => void;
      const ready = new Promise<void>((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
      this.shells.set(shellId, shell);
      shell.streamed = (async () => {
        const reader = processHandle.stdout.getReader();
        let incoming: Buffer = Buffer.alloc(0), exited = false;
        try {
          while (true) {
            const chunk = await reader.read(); if (chunk.done) break;
            incoming = Buffer.concat([incoming, chunk.value]);
            while (incoming.length >= 4) {
              const length = incoming.readUInt32BE(0);
              if (length > 2 * 1024 * 1024) throw new Error('Native PTY frame exceeds its bound.');
              if (incoming.length < length + 4) break;
              const frame = ptyFrame.parse(JSON.parse(incoming.subarray(4, length + 4).toString('utf8')));
              incoming = incoming.subarray(length + 4);
              if (frame.type === 'ready') resolveReady();
              else if (frame.type === 'output') {
                const payload = { shellId, dataBase64: frame.dataBase64, seq: ++shell.seq };
                for (const listener of this.listeners) listener('node.shell.output', payload);
                await this.packet(shell, { type: 'ack' });
              } else {
                exited = true;
                for (const listener of this.listeners) listener('node.shell.exit', { shellId, code: frame.code });
              }
            }
          }
          const code = await processHandle.exited;
          if (!exited) for (const listener of this.listeners) listener('node.shell.exit', { shellId, code: code === 0 ? 124 : code });
        } catch (error) {
          rejectReady(error instanceof Error ? error : new Error('Native PTY transport failed.'));
          processHandle.kill();
          for (const listener of this.listeners) listener('node.shell.exit', { shellId, code: 124 });
          throw error;
        } finally {
          reader.releaseLock(); rejectReady(new Error('Native PTY exited before readiness.'));
          await processHandle.exited;
          this.shells.delete(shellId);
        }
      })();
      // The worker-owned policy packet precedes all terminal input and pins cwd
      // under this fixture's sole admitted root.
      await this.packet(shell, { cwd: String(params.cwd), roots: [String(params.cwd)] });
      await ready; response = { shellId };
    } else if (method === 'node.shell.input') {
      const shell = this.shells.get(String(params.shellId)); if (!shell) throw new Error('Shell absent.');
      await this.packet(shell, { type: 'input', dataBase64: String(params.dataBase64) }); response = { shellId: params.shellId, accepted: true };
    } else if (method === 'node.shell.close') {
      const shell = this.shells.get(String(params.shellId));
      if (shell) { await this.packet(shell, { type: 'close' }); await shell.streamed; }
      response = { shellId: params.shellId, accepted: true };
    } else throw new Error('Unexpected upstream method.');
    // This generic test transport represents the real JSON RPC decoding boundary.
    return response as T;
  }
}
interface Fixture {
  services: BackendServices; store: Store; host: HostServices; routes: Route[];
  owner: Principal; outsider: Principal; admin: Principal; directory: string; lemon: ActualPTY;
  request<T>(method: string, path: string, body?: unknown, actor?: Principal): Promise<T>;
  setBehavior(behavior: string): void;
  log(): Promise<{ id: string; mode: string; kind: string; phase?: string; argv: string[]; input: Record<string, unknown> }[]>;
  close(): Promise<void>;
}
const fixtures: Fixture[] = [];
afterEach(async () => { for (const fixture of fixtures.splice(0)) await fixture.close(); });
async function fixture(reviewedSetups: ReviewedSetup[] = []): Promise<Fixture> {
  const directory = await mkdtemp(join(tmpdir(), 'lemon-host-'));
  await writeFile(join(directory, 'driver.ts'), driverSource);
  await writeFile(join(directory, 'secrets.json'), JSON.stringify({ TEAM_SECRET: 'destination-only-private-value' }));
  const store = new Store(join(directory, 'host.sqlite'));
  const lemon = new ActualPTY();
  const operator: P.OperatorConfiguration = { version: 1, trustedFrontendOrigins: [], oauthRedirectUris: [], serverSecrets: {}, channelProviders: [], emailProviders: [], eventProviders: [], hostDrivers: [], xProvider: null, exportAllowedOrigins: [], requiredRuntimeDestinations: [{ kind: 'domain', value: 'runtime.example', ports: [443], protocol: 'tcp' }], breakGlassOwnerUserId: null };
  operator.reviewedSetupManifests = reviewedSetups;
  operator.machineManagementUserIds = [];
  const key = randomBytes(32);
  const unexpected = (boundary: string): never => { throw new Error(`Unexpected host fixture boundary: ${boundary}.`); };
  let auth: BackendServices['auth'] | undefined;
  let events: BackendServices['events'] | undefined;
  let mutations: BackendServices['mutations'] | undefined;
  const services: BackendServices = {
    store, lemon,
    config: { publicUrl: 'https://product.example', controlUrl: 'wss://controller.example/ws', operatorToken: 'never-disclosed', dataDir: directory, host: '127.0.0.1', port: 4080, trustedOverlay: false, operator },
    get auth() { return auth ??= createAccessService(services); },
    get events() { return events ??= createEventService(services); },
    get mutations() { return mutations ??= createMutationService(services, key); },
    get runtime(): BackendServices['runtime'] { return unexpected('runtime'); },
    get attachments(): BackendServices['attachments'] { return unexpected('attachments'); },
    get gates(): BackendServices['gates'] { return unexpected('gates'); },
    integrations: {
      effectivePolicy: (actor, botId) => policy.effectivePolicy(actor, botId),
      canReadResource: (actor, collection, entity) => host.canReadResource(actor, collection, entity) ?? false,
      admission: () => unexpected('integration admission'),
      connectorConfig: () => unexpected('connector configuration'),
      sendApprovedDraft: () => unexpected('approved draft delivery'),
      emitProviderNotifications: () => unexpected('provider notifications'),
      channelIngress: () => unexpected('channel ingress'),
      providerCapabilities: () => unexpected('provider capabilities'),
    },
    // installHelpers installs the production implementations before this graph
    // is exposed; access during construction fails rather than inventing a result.
    id: () => unexpected('id before helpers'),
    now: () => unexpected('clock before helpers'),
    resource: () => unexpected('resource before helpers'),
    update: () => unexpected('update before helpers'),
    page: () => unexpected('page before helpers'),
    pageAfter: () => unexpected('page cursor before helpers'),
    audit: () => unexpected('audit before helpers'),
    entry: () => unexpected('entry before helpers'),
    notify: () => unexpected('notification before helpers'),
    secret: () => unexpected('backend secret'),
    encrypt: () => unexpected('encryption before codec'),
    decrypt: () => unexpected('decryption before codec'),
    invoke: () => unexpected('internal invocation'),
    syncBotProfile: () => unexpected('profile synchronization'),
  };
  installHelpers(services);
  services.now = () => 1800000000000;
  services.encrypt = value => {
    const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, iv);
    const bytes = Buffer.concat([cipher.update(JSON.stringify(value)), cipher.final()]);
    return Buffer.concat([iv, cipher.getAuthTag(), bytes]).toString('base64url');
  };
  services.decrypt = <T>(value: string): T => {
    const bytes = Buffer.from(value, 'base64url'), decipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12)); decipher.setAuthTag(bytes.subarray(12, 28));
    const decoded: unknown = JSON.parse(Buffer.concat([decipher.update(bytes.subarray(28)), decipher.final()]).toString());
    // Tests decode values written by the production owning service and AES-GCM.
    return decoded as T;
  };
  const workspace = services.resource('workspace', { name: 'Hosts', ownerUserId: 'owner', enabled: true, timezone: 'UTC' }); store.put('workspaces', workspace); store.setMetadata('workspaceId', workspace.id);
  const voice: P.VoiceSettings = { voiceId: 'default', speed: 1, language: null };
  const preferences: P.Preferences = { appearance: 'system', language: null, timezone: 'UTC', botColors: true, threadsBesideChat: false, voice, celebrationsEnabled: false };
  for (const [userId, role] of Object.entries({ owner: 'owner', outsider: 'member', admin: 'admin' } satisfies Record<string, P.Role>)) {
    store.put('users', { ...services.resource('user', { email: `${userId}@example.org`, displayName: userId, avatarAttachmentId: null, preferences, notifications: { enabled: true, sound: false, previews: false, completed: true, needsInput: true } }), id: userId });
    store.put('members', services.resource('member', { userId, displayName: userId, email: `${userId}@example.org`, role, enabled: true }));
  }
  const owner: Principal = { kind: 'user', id: 'owner', userId: 'owner', workspaceId: workspace.id, role: 'owner', sessionId: null, botId: null, deviceId: null };
  const outsider: Principal = { ...owner, id: 'outsider', userId: 'outsider', role: 'member' };
  const admin: Principal = { ...owner, id: 'admin', userId: 'admin', role: 'admin' };
  for (const machineId of ['machine_a', 'machine_b']) store.put('machines', { ...services.resource('machine', { name: machineId, nodeName: machineId, nodeId: `node_${machineId}`, ownerUserId: owner.userId, accessUserIds: [], status: 'online', lastSeenAtMs: services.now(), labels: {}, botIds: ['bot'] }), id: machineId } satisfies P.Machine);
  store.put('bots', { ...services.resource('bot', { ownerUserId: owner.userId, managerUserIds: [], machineId: 'machine_a', profileId: 'lb-host-test', name: 'Bot', title: '', job: '', instructions: '', avatar: { kind: 'character', shape: 'round', color: 'yellow', attachmentId: null }, voice, language: null, visibility: 'personal', published: false, required: false, skillIds: [], referenceAttachmentIds: [], mainConversationId: 'main', sidebar: { pinned: false, hidden: false, sectionId: null, rank: 0, unread: false, notificationsEnabled: true }, activity: 'idle', activeRunIds: [] }), id: 'bot' } satisfies P.Bot);
  let behavior = 'normal';
  const cmd = (): P.HostDriverCommand => ({ argv: [process.execPath, join(directory, 'driver.ts'), directory, 'apply', behavior], probeArgv: [process.execPath, join(directory, 'driver.ts'), directory, 'probe', behavior], cwd: directory, timeoutMs: 10000 });
  const setBehavior = (value: string) => {
    behavior = value;
    operator.hostDrivers = ['machine_a', 'machine_b'].map(machineId => ({ machineId, provider: 'custom', environmentRoot: join(directory, 'environment'), actions: { update: cmd(), recover: cmd(), restart_worker: cmd(), stop_worker: cmd(), suspend: cmd(), recreate_environment: cmd(), delete_environment: cmd() }, networkApply: cmd(), egressApply: cmd(), setupRun: cmd(), runtimeDestinations: [] }));
  };
  setBehavior(behavior);
  const policy = createPolicyServices(services);
  const governance: P.Governance = { revision: 1, groupAccess: 'all', allowedDirectoryGroupIds: [], allowSudo: false, allowEgress: true, lockNetworkForGroups: true, requireReview: true, allowedChannelAdapters: [], xMentionsEnabled: false, emailEnabled: false, contentExportEnabled: false, inactiveHostPolicy: { enabled: false, afterDays: 30, action: 'suspend' } };
  store.setMetadata('governance', governance);
  const host = createHostServices(services), routes = createHostRoutes(services, host);
  const requests = new Set<Promise<unknown>>();
  const result: Fixture = {
    services, store, host, routes, owner, outsider, admin, directory, lemon, setBehavior,
    async request<T>(method: string, path: string, body?: unknown, actor = owner): Promise<T> {
      let params: Record<string, string> = {};
      const route = routes.find(r => {
        if (r.method !== method) return false;
        const names: string[] = [], pattern = r.path.replace(/:([A-Za-z]+)/g, (_, name: string) => { names.push(name); return '([^/]+)'; });
        const match = new URL(`https://product.example${path}`).pathname.match(new RegExp(`^${pattern}$`)); if (!match) return false;
        params = Object.fromEntries(names.map((name, i) => [name, match[i + 1]!])); return true;
      });
      if (!route) throw new Error(`Missing route ${method} ${path}`);
      const context: RequestContext = { request: new Request(`https://product.example${path}`, { method }), params, query: new URL(`https://product.example${path}`).searchParams, body, user: actor, services, requestId: 'host_test', route, nonceResourceIds: [] };
      const request = (method === 'GET' || route.mutation === false ? Promise.resolve(route.handler(context)) : services.mutations.execute(context, () => route.handler(context)));
      requests.add(request);
      let value: unknown;
      try { value = await request; } finally { requests.delete(request); }
      // Routes declare their exact protocol resource output; individual tests inspect it.
      return value as T;
    },
    async log() { try { return (await readFile(join(directory, 'driver.log'), 'utf8')).trim().split('\n').filter(Boolean).map(line => JSON.parse(line)); } catch { return []; } },
    async close() {
      await host.dispose();
      // Mutation receipts settle outside the host worker. Keep the store/key
      // alive until those callers have persisted their own durable receipts.
      while (requests.size) await Promise.allSettled([...requests]);
      await lemon.close();
      store.close(); key.fill(0); await rm(directory, { recursive: true, force: true });
    },
  };
  fixtures.push(result); return result;
}
const intent = (value: string) => `host_test_nonce_${value.padEnd(16, '_')}`;
async function startOperation(h: Fixture, action: P.HostAction = 'update', machineIds = ['machine_a']) {
  const preview = await h.request<P.Confirmation>('POST', '/v1/host-operations/preview', { clientNonce: intent(`preview_${action}`), machineIds, action });
  return h.request<P.HostOperation>('POST', '/v1/host-operations', { clientNonce: intent(`start_${action}`), machineIds, action, revision: preview.revision, confirmationToken: preview.confirmationToken, confirmName: preview.confirmName });
}

describe('trusted owned-host driver over actual node PTY', () => {
  test('runs immutable argv with JSON stdin and records verified disk-preserving outcome', async () => {
    const h = await fixture(), operation = await startOperation(h);
    await h.host.work(`operation:${operation.id}`, async () => {});
    const value = await h.request<P.HostOperation>('GET', `/v1/host-operations/${operation.id}`);
    expect(value.state).toBe('completed'); expect(value.results[0]?.state).toBe('succeeded');
    const effect = JSON.parse(await readFile(join(h.directory, 'host-effect.json'), 'utf8'));
    expect(effect.action).toBe('update'); expect(effect.retainSSH).toBe(true); expect(effect.requireSafePoint).toBe(true);
    expect(effect).not.toHaveProperty('operatorToken');
    expect(h.lemon.calls.every(c => c.method.startsWith('node.shell.'))).toBe(true);
    const inputs = h.lemon.calls.filter(c => c.method === 'node.shell.input').map(c => Buffer.from(String(c.params.dataBase64), 'base64').toString('utf8'));
    expect(inputs.length).toBeGreaterThan(1);
    expect(inputs.every(input => Buffer.byteLength(input, 'utf8') < 1024)).toBe(true);
    expect(inputs.filter(input => input.includes('printf \'%s\\n\' "$lb_host_json" | "$@"'))).toHaveLength(1);
    expect((await h.log()).filter(entry => entry.mode === 'apply')).toHaveLength(1);
    await Promise.all([...h.lemon.shells.values()].map(shell => shell.streamed));
    expect(h.lemon.shells.size).toBe(0);
    const page = await h.request<P.Page<P.HostOperation>>('GET', '/v1/host-operations'); expect(page.items.map(o => o.id)).toContain(operation.id);
  });
  test('dispose stops native shell staging and drains operation settlement before store teardown', async () => {
    const h = await fixture();
    let resolveConsumed!: () => void, output = '';
    const consumed = new Promise<void>(resolve => { resolveConsumed = resolve; });
    const unsubscribe = h.lemon.onEvent((event, payload) => {
      if (event !== 'node.shell.output') return;
      const parsed = z.object({ dataBase64: z.string() }).parse(payload);
      output += Buffer.from(parsed.dataBase64, 'base64').toString('utf8');
      if (output.includes('\x1e') && output.includes('\x1f')) resolveConsumed();
    });
    const operation = await startOperation(h);
    await consumed; unsubscribe();
    const shells = [...h.lemon.shells.values()];
    expect(shells).toHaveLength(1);
    const disposal = h.host.dispose();
    expect(h.host.dispose()).toBe(disposal);
    await disposal;
    expect(h.store.require<P.HostOperation>('hostOperations', operation.id).state).toBe('outcome_unknown');
    expect(await h.log()).toHaveLength(0);
    expect(h.lemon.calls.filter(call => call.method === 'node.shell.close')).toHaveLength(1);
    expect(h.lemon.shells.size).toBe(0);
    for (const shell of shells) expect(shell.process.exitCode).toBe(0);
    await expect(h.host.reconcile()).rejects.toThrow('Host services are disposed.');
  });
  test('lost acknowledgment retains operation ID across restart and probes without redispatch/reset storm', async () => {
    const h = await fixture(); h.setBehavior('lose');
    const operation = await startOperation(h, 'recover'); await h.host.work(`operation:${operation.id}`, async () => {});
    expect(h.store.require<P.HostOperation>('hostOperations', operation.id).state).toBe('outcome_unknown');
    const logBefore = await h.log(); expect(logBefore.filter(l => l.mode === 'apply')).toHaveLength(1);
    await expect(startOperation(h, 'update')).rejects.toMatchObject({ code: 'conflict' });
    await h.host.dispose(); const restarted = createHostServices(h.services);
    try { await restarted.reconcile(); } finally { await restarted.dispose(); }
    expect(h.store.require<P.HostOperation>('hostOperations', operation.id).state).toBe('completed');
    const logs = await h.log(); expect(logs.filter(l => l.mode === 'apply')).toHaveLength(1); expect(logs.filter(l => l.mode === 'probe').map(l => l.id)).toContain(logBefore[0]!.id);
  });
  test('wrong exact operation receipt and absent safe point never report completed', async () => {
    const h = await fixture(); h.setBehavior('wrong');
    const operation = await startOperation(h); await h.host.work(`operation:${operation.id}`, async () => {});
    expect(h.store.require<P.HostOperation>('hostOperations', operation.id).state).toBe('outcome_unknown');
    await h.host.reconcile(); expect(h.store.require<P.HostOperation>('hostOperations', operation.id).state).toBe('completed');
    const second = await fixture(); second.setBehavior('unsafe'); const unsafe = await startOperation(second); await second.host.work(`operation:${unsafe.id}`, async () => {});
    expect(second.store.require<P.HostOperation>('hostOperations', unsafe.id).state).toBe('outcome_unknown');
  });
  test('bulk exact preview binds sorted targets, config and machine revisions, max1000, one operation', async () => {
    const h = await fixture();
    const body = { clientNonce: intent('preview_bulk'), machineIds: ['machine_b', 'machine_a'], action: 'update' };
    const preview = await h.request<P.Confirmation>('POST', '/v1/host-operations/preview', body); expect(preview.confirmName).toBe('UPDATE 2 machines');
    h.setBehavior('wrong');
    await expect(h.request('POST', '/v1/host-operations', { ...body, clientNonce: intent('stale_config'), revision: preview.revision, confirmationToken: preview.confirmationToken, confirmName: preview.confirmName })).rejects.toMatchObject({ code: 'confirmation_required' });
    expect(h.store.list('hostOperations')).toHaveLength(0); expect(await h.log()).toHaveLength(0);
    await expect(h.request('POST', '/v1/host-operations/preview', { ...body, clientNonce: intent('too_many'), machineIds: Array.from({ length: 1001 }, (_, i) => `machine_${i}`) })).rejects.toMatchObject({ code: 'invalid_request' });
    const next = await h.request<P.Confirmation>('POST', '/v1/host-operations/preview', { ...body, clientNonce: intent('machine_preview') });
    const m = h.store.require<P.Machine>('machines', 'machine_a'); h.store.put('machines', h.services.update(m, { name: 'changed' }));
    await expect(h.request('POST', '/v1/host-operations', { ...body, clientNonce: intent('stale_machine'), revision: next.revision, confirmationToken: next.confirmationToken, confirmName: next.confirmName })).rejects.toMatchObject({ code: 'confirmation_required' });
  });
  test('same nonce is durable exact receipt with one real dispatch, never a second bulk start', async () => {
    const h = await fixture();
    const preview = await h.request<P.Confirmation>('POST', '/v1/host-operations/preview', { clientNonce: intent('idem_preview'), machineIds: ['machine_a'], action: 'restart_worker' });
    const body = { clientNonce: intent('idem_start'), revision: preview.revision, confirmationToken: preview.confirmationToken, confirmName: preview.confirmName, machineIds: ['machine_a'], action: 'restart_worker' };
    const first = await h.request<P.HostOperation>('POST', '/v1/host-operations', body); await h.host.work(`operation:${first.id}`, async () => {});
    const repeat = await h.request<P.HostOperation>('POST', '/v1/host-operations', body); expect(repeat).toEqual(first); expect((await h.log()).filter(l => l.mode === 'apply')).toHaveLength(1);
    expect(h.services.auth.canRead(h.owner, 'hostOperations', h.store.require('hostOperations', first.id))).toBe(true);
    const membership = h.services.auth.member(h.owner.userId);
    h.store.put('members', h.services.update(membership, { role: 'admin' }));
    const machine = h.store.require<P.Machine>('machines', 'machine_a');
    h.store.put('machines', h.services.update(machine, { ownerUserId: h.outsider.userId }));
    await expect(h.request('POST', '/v1/host-operations', body)).rejects.toMatchObject({ code: 'not_found' });
    expect((await h.log()).filter(l => l.mode === 'apply')).toHaveLength(1);
    h.store.put('machines', h.services.update(h.store.require<P.Machine>('machines', machine.id), { ownerUserId: h.owner.userId }));
    expect(await h.request('POST', '/v1/host-operations', body)).toEqual(first);
    h.store.put('members', h.services.update(h.services.auth.member(h.owner.userId), { enabled: false }));
    await expect(h.request('POST', '/v1/host-operations', body)).rejects.toMatchObject({ code: 'not_found' });
    expect((await h.log()).filter(l => l.mode === 'apply')).toHaveLength(1);
  });
  test('host resource visibility requires current management authority over every exact target', async () => {
    const h = await fixture(), operation = await startOperation(h, 'update', ['machine_a', 'machine_b']);
    await h.host.work(`operation:${operation.id}`, async () => {});
    const first = h.store.require<P.Machine>('machines', 'machine_a'), second = h.store.require<P.Machine>('machines', 'machine_b');
    h.store.put('machines', h.services.update(first, { ownerUserId: h.admin.userId }));
    expect(h.host.canReadResource(h.admin, 'hostOperations', operation)).toBe(false);
    h.store.put('machines', h.services.update(second, { ownerUserId: h.admin.userId }));
    expect(h.host.canReadResource(h.admin, 'hostOperations', operation)).toBe(true);
    expect(h.host.canReadResource(h.admin, 'setupManifests', { machineIds: ['machine_a', 'machine_b'] })).toBe(true);
    expect(h.host.canReadResource(h.admin, 'policyApplications', { value: { machineId: 'machine_a' } })).toBe(true);
    expect(h.host.canReadResource(h.admin, 'policyApplications', { machineId: 'machine_a' })).toBe(true);
    expect(h.host.canReadResource(h.admin, 'egressRoutes', { ownerUserId: h.admin.userId, machineId: 'machine_a', throughMachineId: 'machine_b' })).toBe(true);
    h.store.put('machines', h.services.update(h.store.require<P.Machine>('machines', second.id), { ownerUserId: h.owner.userId, accessUserIds: [h.admin.userId] }));
    expect(h.host.canReadResource(h.admin, 'hostOperations', operation)).toBe(false);
    expect(h.host.canReadResource(h.admin, 'setupManifests', { machineIds: ['machine_a', 'machine_b'] })).toBe(false);
    expect(h.host.canReadResource(h.admin, 'setupRuns', { machineId: 'machine_b' })).toBe(false);
    expect(h.host.canReadResource(h.admin, 'egressRoutes', { ownerUserId: h.admin.userId, machineId: 'machine_a', throughMachineId: 'machine_b' })).toBe(false);
    expect(h.host.canReadResource(h.admin, 'hostOperations', { results: [] })).toBe(false);
    expect(h.host.canReadResource(h.admin, 'unownedCollection', operation)).toBeUndefined();
    h.store.put('members', h.services.update(h.services.auth.member(h.admin.userId), { role: 'member' }));
    expect(h.host.canReadResource(h.admin, 'hostOperations', { results: [{ machineId: 'machine_a' }] })).toBe(false);
    expect(h.host.canReadResource(h.admin, 'networkPolicies', { scope: 'workspace', directoryGroupId: null })).toBe(false);
    expect(h.host.canReadResource(h.owner, 'networkPolicies', { scope: 'workspace', directoryGroupId: null })).toBe(true);
    expect(h.host.canReadResource(h.owner, 'networkPolicies', { scope: 'directory_group', directoryGroupId: 'absent' })).toBe(false);
  });
  test('long Unicode and shell metacharacters remain exact immutable argv words', async () => {
    const h = await fixture(), argument = `${"漢字'".repeat(3000)}; touch argv-injected`;
    h.services.config.operator.hostDrivers[0]!.actions.update!.argv.push(argument);
    const operation = await startOperation(h); await h.host.work(`operation:${operation.id}`, async () => {});
    expect(h.store.require<P.HostOperation>('hostOperations', operation.id).state).toBe('completed');
    expect((await h.log()).find(l => l.mode === 'apply')?.argv.at(-1)).toBe(argument);
    await expect(readFile(join(h.directory, 'argv-injected'))).rejects.toMatchObject({ code: 'ENOENT' });
    const inputs = h.lemon.calls.filter(c => c.method === 'node.shell.input').map(c => Buffer.from(String(c.params.dataBase64), 'base64'));
    const lines = Buffer.concat(inputs).toString('utf8').split('\n');
    expect(lines.every(line => Buffer.byteLength(line, 'utf8') < 1024)).toBe(true);
  });
  test.each(['wrong_config', 'wrong_input'])('rejects %s receipt and probes the original effect without redispatch', async behavior => {
    const h = await fixture(); h.setBehavior(behavior);
    const operation = await startOperation(h); await h.host.work(`operation:${operation.id}`, async () => {});
    expect(h.store.require<P.HostOperation>('hostOperations', operation.id).state).toBe('outcome_unknown');
    await h.host.reconcile();
    expect(h.store.require<P.HostOperation>('hostOperations', operation.id).state).toBe('completed');
    const log = await h.log();
    expect(log.filter(l => l.mode === 'apply')).toHaveLength(1);
    expect(log.filter(l => l.mode === 'probe').map(l => l.id)).toEqual([log[0]!.id]);
  });
  test('verified existing no-op is skipped with a concrete reason, never reported as success', async () => {
    const h = await fixture(); h.setBehavior('skip'); expect(createHostServices(h.services)).toBe(h.host);
    const operation = await startOperation(h); await h.host.work(`operation:${operation.id}`, async () => {});
    expect(h.store.require<P.HostOperation>('hostOperations', operation.id).results[0]).toMatchObject({ state: 'skipped', reason: 'Driver verified no action needed: already_current.' });
    expect((await h.log()).filter(l => l.kind === 'host' && l.mode === 'apply')).toHaveLength(1);
  });
  test('unsupported bulk target is explicitly skipped and expired previews have no start effects', async () => {
    const h = await fixture(); delete h.services.config.operator.hostDrivers[1]!.actions.update;
    const operation = await startOperation(h, 'update', ['machine_a', 'machine_b']); await h.host.work(`operation:${operation.id}`, async () => {});
    const result = h.store.require<P.HostOperation>('hostOperations', operation.id);
    expect(result.results.find(r => r.machineId === 'machine_b')).toMatchObject({ state: 'skipped', reason: 'Action not configured for this host.' });
    const preview = await h.request<P.Confirmation>('POST', '/v1/host-operations/preview', { clientNonce: intent('expiring_preview'), machineIds: ['machine_a'], action: 'recover' });
    h.services.now = () => preview.expiresAtMs;
    await expect(h.request('POST', '/v1/host-operations', { clientNonce: intent('expired_start'), machineIds: ['machine_a'], action: 'recover', revision: preview.revision, confirmationToken: preview.confirmationToken, confirmName: preview.confirmName })).rejects.toMatchObject({ code: 'expired' });
    expect(h.store.list('hostOperations')).toHaveLength(1);
  });
  test('isolated-root deletion requires measured root and retains home/SSH in preview', async () => {
    const h = await fixture();
    expect(() => h.host.snapshot(h.owner, ['machine_a'], 'delete_environment')).toThrow('Probe and verify');
    await h.host.management(h.owner, 'machine_a');
    const preview = await h.request<P.Confirmation>('POST', '/v1/host-operations/preview', { clientNonce: intent('delete_reviewed'), machineIds: ['machine_a'], action: 'delete_environment' });
    expect(preview.effects.join(' ')).toContain('SSH'); expect(preview.affected.some(a => a.operation === 'delete')).toBe(true); expect(preview.effects.join(' ')).toContain(h.directory);
    await writeFile(join(h.directory, 'retain-ssh'), 'operator-owned');
    await mkdir(join(h.directory, 'environment')); await writeFile(join(h.directory, 'environment', 'lemon-owned'), 'isolated');
    const operation = await h.request<P.HostOperation>('POST', '/v1/host-operations', { clientNonce: intent('delete_confirm'), machineIds: ['machine_a'], action: 'delete_environment', revision: preview.revision, confirmationToken: preview.confirmationToken, confirmName: preview.confirmName });
    await h.host.work(`operation:${operation.id}`, async () => {});
    expect(h.store.require<P.HostOperation>('hostOperations', operation.id).state).toBe('completed');
    expect(await readFile(join(h.directory, 'retain-ssh'), 'utf8')).toBe('operator-owned');
    await expect(readFile(join(h.directory, 'environment', 'lemon-owned'))).rejects.toMatchObject({ code: 'ENOENT' });
    h.services.config.operator.hostDrivers[0]!.environmentRoot = '/Users/operator';
    await expect(h.request('POST', '/v1/host-operations/preview', { clientNonce: intent('home_delete'), machineIds: ['machine_a'], action: 'delete_environment' })).rejects.toMatchObject({ code: 'policy_denied' });
  });
  test('inactive policy skips awake and active hosts; verified sleeping stops once without access revocation', async () => {
    const h = await fixture(), governance = h.store.metadata<P.Governance>('governance')!;
    h.store.setMetadata('governance', { ...governance, inactiveHostPolicy: { enabled: true, afterDays: 30, action: 'suspend' } });
    await h.host.processInactiveHosts(); expect(h.store.list('hostOperations')).toHaveLength(0);
    await writeFile(join(h.directory, 'inspection.json'), JSON.stringify({ hostState: 'sleeping', inactiveSinceMs: 1700000000000 }));
    const bot = h.store.require<P.Bot>('bots', 'bot'); h.store.put('bots', h.services.update(bot, { activeRunIds: ['active'] }));
    // Second machine is also eligible, so explicitly remove its suspend support.
    delete h.services.config.operator.hostDrivers[1]!.actions.suspend;
    await h.host.processInactiveHosts(); expect(h.store.list('hostOperations')).toHaveLength(0);
    h.store.put('bots', h.services.update(h.store.require<P.Bot>('bots', 'bot'), { activeRunIds: [] }));
    await h.host.processInactiveHosts(); const operations = h.store.list<P.HostOperation>('hostOperations'); expect(operations).toHaveLength(1); expect(operations[0]?.state).toBe('completed');
    await h.host.processInactiveHosts(); expect(h.store.list('hostOperations')).toHaveLength(1); expect(h.store.require<P.Machine>('machines', 'machine_a').status).toBe('online');
  });
});

describe('applied network policy and encrypted egress', () => {
  test('strict canonical domain/CIDR/port rules reject broad substring matching and host bits', () => {
    const domain: P.NetworkRule = { kind: 'domain', value: '*.example.org', ports: [443], protocol: 'tcp' };
    expect(canonicalNetworkRule(domain)).toBe(true); expect(canonicalNetworkRule({ ...domain, value: '*example.org' })).toBe(false);
    expect(canonicalNetworkRule({ ...domain, kind: 'ip_cidr', value: '10.0.0.0/8' })).toBe(true); expect(canonicalNetworkRule({ ...domain, kind: 'ip_cidr', value: '10.0.0.1/8' })).toBe(false);
    expect(canonicalNetworkRule({ ...domain, kind: 'ip_cidr', value: '2001:db8::/32' })).toBe(true); expect(canonicalNetworkRule({ ...domain, kind: 'ip_cidr', value: '2001:0db8::/32' })).toBe(false);
    expect(canonicalNetworkRule({ ...domain, ports: [0] })).toBe(false);
  });
  test('admission refuses pending/offline/stale driver; actual applied revision includes required runtime allowance', async () => {
    const h = await fixture();
    const policy = await h.request<P.NetworkPolicy>('POST', '/v1/network-policies', { clientNonce: intent('create_policy'), scope: 'workspace', mode: 'allowlist_only', rules: [] });
    await expect(h.host.admission(h.owner, 'bot')).rejects.toMatchObject({ code: 'policy_denied' });
    const result = await h.request<P.Page<P.PolicyApplication>>('POST', `/v1/network-policies/${policy.id}/apply`, { clientNonce: intent('apply_policy'), machineIds: ['machine_a'] });
    expect(result.items[0]?.appliedRevision).toBe(policy.revision); expect(result.items[0]?.state).toBe('applied'); await h.host.admission(h.owner, 'bot');
    const applied = JSON.parse(await readFile(join(h.directory, 'firewall.json'), 'utf8')); expect(applied.policy.requiredRuntimeDestinations).toEqual(h.services.config.operator.requiredRuntimeDestinations); expect(applied.lockNetworkForGroups).toBe(true);
    h.services.config.operator.hostDrivers[0]!.runtimeDestinations.push({ kind: 'domain', value: 'new.example', ports: [443], protocol: 'tcp' });
    await expect(h.host.admission(h.owner, 'bot')).rejects.toMatchObject({ code: 'policy_denied' });
  });
  test('offline reserved apply dispatches once on return, uncertain apply only probes', async () => {
    const h = await fixture(); const policy = await h.request<P.NetworkPolicy>('POST', '/v1/network-policies', { clientNonce: intent('offline_policy'), scope: 'workspace', mode: 'allowlist_only', rules: [] });
    const m = h.store.require<P.Machine>('machines', 'machine_a'); h.store.put('machines', h.services.update(m, { status: 'offline' }));
    const page = await h.host.applyNetwork(h.owner, policy, ['machine_a']); expect(page.items[0]?.state).toBe('offline'); expect(await h.log()).toHaveLength(0);
    h.store.put('machines', h.services.update(h.store.require<P.Machine>('machines', m.id), { status: 'online' })); await h.host.reconcile(); await h.host.admission(h.owner, 'bot');
    expect((await h.log()).filter(l => l.mode === 'apply')).toHaveLength(1);
  });
  test('group hard lock chooses workspace policy; unlocked multiple group policies intersect', async () => {
    const h = await fixture();
    const workspace = h.services.resource('network_policy', { scope: 'workspace' as const, directoryGroupId: null, mode: 'allowlist_only' as const, rules: [], requiredRuntimeDestinations: [] }); h.store.put('networkPolicies', workspace);
    for (const groupId of ['g1', 'g2']) {
      h.store.put('directoryGroups', { ...h.services.resource('directory_group', { name: groupId, externalId: null, source: 'local' as const, memberUserIds: ['owner'] }), id: groupId });
      const policy = h.services.resource('network_policy', { scope: 'directory_group' as const, directoryGroupId: groupId, mode: 'allowlist_only' as const, rules: [], requiredRuntimeDestinations: [] }); h.store.put('networkPolicies', policy);
      h.store.put('groupPolicies', h.services.resource('group_policy', { directoryGroupId: groupId, productAccess: true, defaultBotIds: [], capabilityModes: {}, requiredRuleIds: [], localExecutionCeiling: 'allow', allowEgress: true, allowSudo: false, networkPolicyId: policy.id, reviewExempt: false }));
    }
    expect((await h.services.integrations.effectivePolicy(h.owner, 'bot')).networkPolicies.map(p => p.id)).toEqual([workspace.id]);
    h.store.setMetadata('governance', { ...h.store.metadata<P.Governance>('governance')!, lockNetworkForGroups: false });
    const effective = await h.services.integrations.effectivePolicy(h.owner, 'bot'); expect(effective.networkPolicies).toHaveLength(2); expect(effective.networkPolicies.every(p => p.scope === 'directory_group')).toBe(true);
  });
  test('network deletion removes actual enforcement before deleting the resource, including uncertain reconciliation', async () => {
    const h = await fixture();
    const policy = await h.request<P.NetworkPolicy>('POST', '/v1/network-policies', { clientNonce: intent('delete_policy_create'), scope: 'workspace', mode: 'allowlist_only', rules: [] });
    await h.host.applyNetwork(h.owner, policy, ['machine_a']); h.setBehavior('lose');
    await expect(h.request('DELETE', `/v1/network-policies/${policy.id}`, { clientNonce: intent('delete_policy_remove'), revision: policy.revision })).rejects.toMatchObject({ code: 'outcome_unknown' });
    expect(h.store.get('networkPolicies', policy.id)).not.toBeNull();
    await h.host.reconcile(); expect(h.store.get('networkPolicies', policy.id)).toBeNull();
    const installed = JSON.parse(await readFile(join(h.directory, 'firewall.json'), 'utf8'));
    expect(installed.removePolicyId).toBe(policy.id); expect(installed.policy.requiredRuntimeDestinations).toEqual(h.services.config.operator.requiredRuntimeDestinations);
    const logs = await h.log(); expect(logs.filter(l => l.mode === 'apply' && l.kind === 'network')).toHaveLength(2);
  });
  test('an unauthenticated/unencrypted driver receipt cannot activate a route', async () => {
    const h = await fixture(); h.setBehavior('unencrypted');
    const route = await h.request<P.EgressRoute>('POST', '/v1/egress-routes', { clientNonce: intent('insecure_egress'), machineId: 'machine_a', throughMachineId: 'machine_b', enabled: true });
    expect(route.state).toBe('connecting'); await expect(h.host.admission(h.owner, 'bot')).rejects.toMatchObject({ code: 'policy_denied' });
    await h.host.reconcile(); expect(h.store.require<P.EgressRoute>('egressRoutes', route.id).state).not.toBe('active');
    expect((await h.log()).filter(l => l.kind === 'egress' && l.mode === 'apply')).toHaveLength(1);
  });
  test('egress requires authority on both hosts; central deny acknowledges stop and restores only prior authorized preference', async () => {
    const h = await fixture();
    const group = h.services.resource('directory_group', { name: 'egress', externalId: null, source: 'local' as const, memberUserIds: ['owner'] }); h.store.put('directoryGroups', group);
    h.store.put('groupPolicies', h.services.resource('group_policy', { directoryGroupId: group.id, productAccess: true, defaultBotIds: [], capabilityModes: {}, requiredRuleIds: [], localExecutionCeiling: 'allow', allowEgress: true, allowSudo: false, networkPolicyId: null, reviewExempt: false }));
    await expect(h.host.authorizeEgress(h.admin, 'machine_a', 'machine_b', true)).rejects.toMatchObject({ code: 'not_found' });
    const route = await h.request<P.EgressRoute>('POST', '/v1/egress-routes', { clientNonce: intent('egress_create'), machineId: 'machine_a', throughMachineId: 'machine_b', enabled: true }); expect(route.state).toBe('active');
    const previous = h.store.metadata<P.Governance>('governance')!, denied = { ...previous, revision: 2, allowEgress: false }; h.store.setMetadata('governance', denied); await h.host.governanceChanged(previous, denied);
    const stopped = h.store.require<P.EgressRoute>('egressRoutes', route.id); expect(stopped.state).toBe('disabled'); expect(stopped.rememberedPreference).toBe(true); expect(stopped.enabled).toBe(false);
    expect(JSON.parse(await readFile(join(h.directory, 'route.json'), 'utf8')).enabled).toBe(false);
    h.store.setMetadata('governance', previous); await h.host.governanceChanged(denied, previous); expect(h.store.require<P.EgressRoute>('egressRoutes', route.id).state).toBe('active');
    await h.host.governanceChanged(previous, denied); const through = h.store.require<P.Machine>('machines', 'machine_b'); h.store.put('machines', h.services.update(through, { status: 'revoked' }));
    h.store.setMetadata('governance', previous); await h.host.governanceChanged(denied, previous); expect(h.store.require<P.EgressRoute>('egressRoutes', route.id).enabled).toBe(false);
  });
});

describe('reviewed sequential destination setup', () => {
  test('large Unicode reviewed input survives canonical PTY limits with exact stdin framing', async () => {
    const reviewed: ReviewedSetup = { name: 'large', directoryGroupId: null, machineIds: ['machine_a'], entries: [{ id: 'unicode', setupScript: `# ${"漢字'".repeat(5000)}\ntouch large.done`, checkScript: null, secretNames: [], timeoutMs: 10000 }] };
    const h = await fixture([reviewed]);
    const manifest = await h.request<P.SetupManifest>('POST', '/v1/setup-manifests', { clientNonce: intent('large_create'), ...reviewed, directoryGroupId: undefined, enabled: true });
    const page = await h.request<P.Page<P.SetupRun>>('POST', `/v1/setup-manifests/${manifest.id}/run`, { clientNonce: intent('large_run'), machineIds: ['machine_a'] });
    await h.host.work(`setup:${page.items[0]!.id}`, async () => {});
    expect(h.store.require<P.SetupRun>('setupRuns', page.items[0]!.id).state).toBe('succeeded');
    expect(await readFile(join(h.directory, 'large.done'), 'utf8')).toBe('');
  });
  test('check→setup→recheck and later entries execute in order; output/secret values stay private', async () => {
    const reviewed: ReviewedSetup = { name: 'reviewed', directoryGroupId: null, machineIds: ['machine_a'], entries: [{ id: 'first', checkScript: 'test -f first.done', setupScript: 'printf "%s" "$TEAM_SECRET"; touch first.done', secretNames: ['TEAM_SECRET'], timeoutMs: 10000 }, { id: 'second', checkScript: 'test -f second.done', setupScript: 'test -f first.done && touch second.done', secretNames: [], timeoutMs: 10000 }] };
    const h = await fixture([reviewed]);
    const manifest = await h.request<P.SetupManifest>('POST', '/v1/setup-manifests', { clientNonce: intent('setup_create'), ...reviewed, directoryGroupId: undefined, enabled: true });
    const page = await h.request<P.Page<P.SetupRun>>('POST', `/v1/setup-manifests/${manifest.id}/run`, { clientNonce: intent('setup_run'), machineIds: ['machine_a'] }); const run = page.items[0]!;
    await h.host.work(`setup:${run.id}`, async () => {});
    const finished = h.store.require<P.SetupRun>('setupRuns', run.id); expect(finished.state).toBe('succeeded'); expect(finished.entryResults.map(e => e.state)).toEqual(['succeeded', 'succeeded']);
    expect((await h.log()).filter(l => l.kind === 'setup').map(l => l.phase)).toEqual(['check', 'setup', 'recheck', 'check', 'setup', 'recheck']);
    expect(JSON.stringify(finished)).not.toContain('destination-only-private-value'); expect(JSON.stringify(h.store.list('hostDriverJobs'))).not.toContain('destination-only-private-value');
    const listed = await h.request<P.Page<P.SetupRun>>('GET', `/v1/setup-runs?manifestId=${manifest.id}`); expect(listed.items[0]?.id).toBe(run.id);
    await expect(h.request('POST', '/v1/setup-manifests', { clientNonce: intent('unreviewed'), ...reviewed, directoryGroupId: undefined, enabled: true, entries: [{ ...reviewed.entries[0], setupScript: 'rm -rf /' }] })).rejects.toMatchObject({ code: 'policy_denied' });
    const rerun = await h.request<P.Page<P.SetupRun>>('POST', `/v1/setup-manifests/${manifest.id}/run`, { clientNonce: intent('setup_rerun'), machineIds: ['machine_a'] });
    await h.host.work(`setup:${rerun.items[0]!.id}`, async () => {});
    expect(h.store.require<P.SetupRun>('setupRuns', rerun.items[0]!.id).state).toBe('skipped');
    expect((await h.log()).filter(l => l.kind === 'setup' && l.phase === 'setup')).toHaveLength(2);
    expect(h.services.events.replay(h.admin, '0').some(e => e.event === 'setup_manifest.upserted' || e.event === 'setup_run.upserted')).toBe(false);
    const patched = await h.request<P.SetupManifest>('PATCH', `/v1/setup-manifests/${manifest.id}`, { clientNonce: intent('setup_disable'), revision: manifest.revision, enabled: false });
    await expect(h.request('POST', `/v1/setup-manifests/${manifest.id}/run`, { clientNonce: intent('disabled_run'), machineIds: ['machine_a'] })).rejects.toMatchObject({ code: 'policy_denied' });
    const deleted = await h.request<P.Deleted>('DELETE', `/v1/setup-manifests/${manifest.id}`, { clientNonce: intent('setup_delete'), revision: patched.revision });
    expect(deleted.deleted).toBe(true);
  });
  test('setup failure never advances to later entries', async () => {
    const reviewed: ReviewedSetup = { name: 'failure', directoryGroupId: null, machineIds: ['machine_a'], entries: [{ id: 'fails', setupScript: 'exit 7', checkScript: null, secretNames: [], timeoutMs: 10000 }, { id: 'never', setupScript: 'touch should-not-exist', checkScript: null, secretNames: [], timeoutMs: 10000 }] };
    const h = await fixture([reviewed]); const manifest = await h.request<P.SetupManifest>('POST', '/v1/setup-manifests', { clientNonce: intent('failure_create'), ...reviewed, directoryGroupId: undefined, enabled: true });
    const page = await h.request<P.Page<P.SetupRun>>('POST', `/v1/setup-manifests/${manifest.id}/run`, { clientNonce: intent('failure_run'), machineIds: ['machine_a'] }); await h.host.work(`setup:${page.items[0]!.id}`, async () => {});
    const run = h.store.require<P.SetupRun>('setupRuns', page.items[0]!.id); expect(run.state).toBe('failed'); expect(run.entryResults[0]?.exitCode).toBe(7); expect(run.entryResults[1]?.state).toBe('pending'); expect((await h.log()).filter(l => l.kind === 'setup')).toHaveLength(1);
  });
  test('lost setup result reconciles each exact phase without executing any phase twice', async () => {
    const reviewed: ReviewedSetup = { name: 'uncertain', directoryGroupId: null, machineIds: ['machine_a'], entries: [{ id: 'one', setupScript: 'touch verified.done', checkScript: 'test -f verified.done', secretNames: [], timeoutMs: 10000 }] };
    const h = await fixture([reviewed]); h.setBehavior('lose');
    const manifest = await h.request<P.SetupManifest>('POST', '/v1/setup-manifests', { clientNonce: intent('unknown_setup_create'), ...reviewed, directoryGroupId: undefined, enabled: true });
    const page = await h.request<P.Page<P.SetupRun>>('POST', `/v1/setup-manifests/${manifest.id}/run`, { clientNonce: intent('unknown_setup_run'), machineIds: ['machine_a'] });
    const runId = page.items[0]!.id; await h.host.work(`setup:${runId}`, async () => {});
    expect(h.store.require<P.SetupRun>('setupRuns', runId).state).toBe('outcome_unknown');
    for (let phase = 0; phase < 3; phase++) await h.host.reconcile();
    expect(h.store.require<P.SetupRun>('setupRuns', runId).state).toBe('succeeded');
    const applied = (await h.log()).filter(l => l.mode === 'apply' && l.kind === 'setup');
    expect(applied.map(l => l.phase)).toEqual(['check', 'setup', 'recheck']);
    expect(new Set(applied.map(l => l.id)).size).toBe(3);
  });
  test('entry PTY timeout stays uncertain with the fixed job ID and never redispatches', async () => {
    const reviewed: ReviewedSetup = { name: 'bounded', directoryGroupId: null, machineIds: ['machine_a'], entries: [{ id: 'slow', setupScript: 'sleep 3', checkScript: null, secretNames: [], timeoutMs: 1000 }] };
    const h = await fixture([reviewed]);
    const manifest = await h.request<P.SetupManifest>('POST', '/v1/setup-manifests', { clientNonce: intent('timeout_create'), ...reviewed, directoryGroupId: undefined, enabled: true });
    const page = await h.request<P.Page<P.SetupRun>>('POST', `/v1/setup-manifests/${manifest.id}/run`, { clientNonce: intent('timeout_run'), machineIds: ['machine_a'] });
    const runId = page.items[0]!.id; await h.host.work(`setup:${runId}`, async () => {});
    expect(h.store.require<P.SetupRun>('setupRuns', runId).state).toBe('outcome_unknown');
    const original = (await h.log()).filter(l => l.kind === 'setup' && l.mode === 'apply');
    await h.host.reconcile();
    const after = await h.log(); expect(after.filter(l => l.kind === 'setup' && l.mode === 'apply')).toHaveLength(1);
    expect(after.filter(l => l.kind === 'setup' && l.mode === 'probe').map(l => l.id)).toContain(original[0]!.id);
  });
  test('config refuses cross-team reuse of destination secret names and hostless admins cannot read scripts', async () => {
    const first: ReviewedSetup = { name: 'one', directoryGroupId: 'group_one', machineIds: ['machine_a'], entries: [{ id: 'a', setupScript: 'true', checkScript: null, secretNames: ['TEAM_SECRET'], timeoutMs: 10000 }] };
    const second: ReviewedSetup = { ...first, name: 'two', directoryGroupId: 'group_two' };
    const h = await fixture([first, second]); for (const groupId of ['group_one', 'group_two']) h.store.put('directoryGroups', { ...h.services.resource('directory_group', { name: groupId, externalId: null, source: 'local', memberUserIds: ['owner'] }), id: groupId });
    await expect(h.request('POST', '/v1/setup-manifests', { clientNonce: intent('cross_team'), ...first, enabled: true })).rejects.toMatchObject({ code: 'policy_denied' });
    await expect(h.request('POST', '/v1/setup-manifests', { clientNonce: intent('hostless_admin'), ...first, enabled: true }, h.admin)).rejects.toMatchObject({ code: 'not_found' });
    expect(h.store.list('setupManifests')).toHaveLength(0);
  });
});
