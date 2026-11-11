import { randomBytes } from 'node:crypto';
import { access, readFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import { hostname, homedir, userInfo } from 'node:os';
import { isAbsolute, join } from 'node:path';
import type { AuthResult, InstanceStatus, Machine, MachineAttachResult, MachineInvite, Page } from '../../../contracts/protocol';
import { createPrivateCodec, isLoopback, loadConfiguration, readManagedToken } from '../core/config';
import { productVersion } from '../core/version';
import { fileURLToPath } from 'node:url';
import { terminal, type ConnectTerminal } from './connect';
import { prepareController } from './lemon-runtime';
import { service, spawn, type Spawn, type ServiceStatus, type ServiceResult } from './lifecycle';

const nodePattern = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/;
const nonce = () => randomBytes(24).toString('base64url');
const serviceDetails = ['port_in_use_foreign', 'unhealthy_recorded_runtime', 'gui_session_required', 'unit_foreign', 'daemon_ownership_unverified', 'enrollment_outcome_unknown', 'invite_rejected', 'node_authentication_failed', 'restore_in_progress', 'timeout', 'exec_wrapper_missing'];
type Step = 'runtime' | 'controller_choice' | 'setup' | 'units' | 'linger' | 'owner' | 'machine' | 'worker';
export type UpStatus = 'ready' | 'runtime_missing' | 'setup_required' | 'service_failed' | 'enroll_failed' | 'needs_attention';
export interface UpResult {
  type: 'result'; status: UpStatus; port: number; machineId: string | null;
  manager: string; persistence: string; installCommand?: string;
}
export interface HostIdentity { nodeName: string; displayName: string; ownerName: string }
export interface UpDependencies {
  spawn: Spawn; fetch: typeof fetch; terminal: ConnectTerminal;
  load: typeof loadConfiguration; executable(path: string): Promise<boolean>; readKey(path: string): string;
  prepareController: typeof prepareController;
  hostIdentity(): Promise<HostIdentity>; stdout(value: string): void; stderr(value: string): void;
  sleep(ms: number): Promise<void>; environment: Record<string, string | undefined>;
  botPath: string;
}

export function nodeName(host: string): string {
  return host.toLowerCase().replace(/[^a-z0-9_.-]/g, '').replace(/^[^a-z0-9]+/, '').slice(0, 64) || 'lemon-host';
}

/** Parse, never execute, the backend's credential-free join recipe. Preserve the exact bound URL. */
export function joinTarget(command: string): { name: string; controller: string } {
  const words = Array.from(command.matchAll(/'([^']*)'/g), match => match[1]!);
  const options: Record<string, string> = {};
  for (let i = 0; i < words.length; i++) {
    if (words[i]!.startsWith('--') && i + 1 < words.length) {
      const option = words[i]!;
      if (option in options) throw new Error('Invalid invitation.');
      options[option] = words[++i]!;
    }
  }
  const name = options['--name'], controller = options['--controller'];
  if (!name || !nodePattern.test(name) || !controller || controller.length > 2048
      || !/^(wss:\/\/[A-Za-z0-9.\[\]:-]+|ws:\/\/(localhost|127\.0\.0\.1|\[::1\])(:[0-9]{1,5})?)(\/[A-Za-z0-9._~/-]*)?$/.test(controller)) throw new Error('Invalid invitation.');
  // Match the former native parser's source/release constraints, even though installation is now local.
  const source = options['--source'], version = options['--version'], base = options['--base-url'];
  if (version && !/^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?$/.test(version)) throw new Error('Invalid invitation.');
  if (source) {
    if (!source.startsWith('/') || source.length > 4096 || base || /[\x00-\x1f\x7f]/.test(source)) throw new Error('Invalid invitation.');
  } else if (!version || !base || base.length > 2048 || !/^https:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?(\/[A-Za-z0-9._~/-]*)?$/.test(base)) throw new Error('Invalid invitation.');
  return { name, controller };
}

async function hostIdentity(): Promise<HostIdentity> {
  const host = hostname().replace(/\.local$/, '');
  const command = async (executable: string, args: string[]) => {
    try { const result = await spawn(executable, args); return result.exitCode === 0 ? result.stdout.trim() : ''; } catch { return ''; }
  };
  const shortHost = await command('hostname', ['-s']) || host;
  const username = userInfo().username;
  let ownerName = username;
  if (process.platform === 'darwin') ownerName = await command('/usr/bin/id', ['-F']) || username;
  else if (process.platform === 'linux') {
    try { ownerName = (await readFile('/etc/passwd', 'utf8')).split('\n').find(line => line.startsWith(`${username}:`))?.split(':')[4]?.split(',')[0] || username; } catch { /* Username is always available. */ }
  }
  const displayName = (process.platform === 'darwin' ? await command('/usr/sbin/scutil', ['--get', 'ComputerName']) : '') || shortHost;
  return { nodeName: nodeName(shortHost), displayName: displayName.slice(0, 120), ownerName: ownerName.slice(0, 120) };
}

const sourceBot = fileURLToPath(new URL('../../bin/lemon-bot-source', import.meta.url));
const defaults: UpDependencies = {
  spawn, fetch, terminal: terminal(process.stderr), load: loadConfiguration, prepareController,
  executable: async path => { try { await access(path, constants.X_OK); return true; } catch { return false; } },
  readKey(path) { const result = readManagedToken(path); if (!('token' in result)) throw new Error('Local access unavailable.'); return result.token; },
  hostIdentity, stdout: value => { process.stdout.write(value); }, stderr: value => { process.stderr.write(value); },
  sleep: ms => Bun.sleep(ms), environment: process.env,
  botPath: import.meta.path.includes('/$bunfs/') ? process.execPath : sourceBot,
};

class ProductError extends Error { constructor(readonly code: string) { super(code); } }
type ProductRequest = <T>(path: string, token?: string, body?: unknown) => Promise<T>;
function product(fetcher: typeof fetch, origin: string): ProductRequest {
  return async function request<T>(path: string, token?: string, body?: unknown): Promise<T> {
    let response: Response;
    try {
      response = await fetcher(`${origin}/v1${path}`, { method: body === undefined ? 'GET' : 'POST',
        headers: { Accept: 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }), redirect: 'manual', credentials: 'omit', cache: 'no-store', signal: AbortSignal.timeout(10_000) });
    } catch { throw new ProductError('outcome_unknown'); }
    if (response.redirected || response.status >= 300 && response.status < 400 || !/^application\/json(?:;|$)/i.test(response.headers.get('content-type') ?? '')) {
      await response.body?.cancel(); throw new ProductError('invalid_response');
    }
    const reader = response.body?.getReader();
    if (!reader) throw new ProductError('invalid_response');
    let size = 0, text = '';
    const decoder = new TextDecoder('utf-8', { fatal: true });
    let value: T & { error?: { code?: string } };
    try {
      for (;;) {
        const chunk = await reader.read(); if (chunk.done) break;
        size += chunk.value.byteLength;
        if (size > 1_048_576) { await reader.cancel(); throw new Error(); }
        text += decoder.decode(chunk.value, { stream: true });
      }
      value = JSON.parse(text + decoder.decode()) as typeof value;
    } catch { throw new ProductError('invalid_response'); } finally { reader.releaseLock(); }
    if (!response.ok) throw new ProductError(value.error?.code ?? 'request_failed');
    return value;
  };
}

export async function runUpCli(args: string[], dependencies: UpDependencies = defaults, options: { chooseLemon?: boolean } = {}): Promise<number> {
  const d = dependencies;
  const flags = new Set<string>(); let name: string | undefined, wrapper: string | undefined;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!;
    if (flags.has(arg)) { d.stderr('Unsupported up argument. Use lemon-bot --help.\n'); return 2; }
    flags.add(arg);
    if (arg === '--name') name = args[++i];
    else if (arg === '--worker-wrapper') wrapper = args[++i];
    else if (!['--json', '--no-open', '--no-worker', '--this-machine'].includes(arg)) { d.stderr('Unsupported up argument. Use lemon-bot --help.\n'); return 2; }
    if (arg === '--name' && (!name || !nodePattern.test(name)) || arg === '--worker-wrapper' && (!wrapper || !isAbsolute(wrapper))) { d.stderr('Invalid up name or worker wrapper.\n'); return 2; }
  }
  const json = flags.has('--json');
  let step: Step = 'runtime';
  const emit = (current: Step, state: 'running' | 'ok' | 'skipped' | 'failed', detail: string | null = null) => {
    step = current;
    if (json) d.stdout(`${JSON.stringify({ type: 'step', step: current, state, detail })}\n`);
    if (!json || state === 'failed') d.stderr(`${current}: ${state}${detail ? ` (${detail})` : ''}\n`);
  };
  const result: UpResult = { type: 'result', status: 'service_failed', port: 4100, machineId: null, manager: 'none', persistence: 'none' };
  const finish = (status: UpStatus) => {
    result.status = status;
    if (json) d.stdout(`${JSON.stringify(result)}\n`);
    else { d.stderr(status === 'ready' ? `Lemon Bot is ready (persistence: ${result.persistence}).\n` : `Lemon Bot setup stopped: ${status}.\n`); if (result.installCommand) d.stderr(`Install with:\n  ${result.installCommand}\n`); }
    return status === 'ready' ? 0 : 1;
  };
  let session: string | undefined;
  let request: ProductRequest | undefined;
  let failure: UpStatus = 'service_failed';
  try {
    emit('runtime', 'running');
    const { config, key, controllerSource } = await d.load(d.environment);
    result.port = config.port;
    const home = d.environment.HOME || homedir();
    const stableBot = join(home, '.local/bin/lemon-bot');
    const botPath = await d.executable(stableBot) ? stableBot : d.botPath;
    const launcher = config.runtimeLauncher ?? join(home, '.lemon/bin/lemon');
    if (!await d.executable(launcher)) {
      result.installCommand = `curl -fsSL ${(d.environment.LEMON_INSTALL_BASE_URL || 'https://github.com/z80dev/lemon').replace(/\/$/, '')}/releases/download/v${productVersion}/install.sh | sh -s -- --profile bot`;
      emit('runtime', 'failed', 'runtime_missing'); return finish('runtime_missing');
    }
    const version = await d.spawn(launcher, ['version']);
    if (version.exitCode !== 0 || version.stdout.trim() !== productVersion) {
      emit('runtime', 'failed', 'version_mismatch');
      if (json) return finish('needs_attention');
      d.stderr(`Lemon and Lemon Bot versions differ; update both to ${productVersion}.\n`);
    } else emit('runtime', 'ok');
    emit('controller_choice', 'running');
    const previousController = { url: config.controlUrl, token: config.operatorToken, tokenFile: config.operatorTokenFile };
    if (d.terminal.interactive) {
      // Choice prompts go to stderr, keeping NDJSON stdout machine-readable.
      const io = { ...d.terminal, write: (text: string) => d.stderr(`${text}\n`) };
      await d.prepareController({ terminal: io, environment: d.environment, config, codec: createPrivateCodec(key), source: controllerSource, choose: options.chooseLemon === true, thisMachine: flags.has('--this-machine'), fetch: d.fetch });
    } else if (options.chooseLemon) { emit('controller_choice', 'failed', 'terminal_required'); return finish('needs_attention'); }
    emit('controller_choice', 'ok');
    const controllerChanged = previousController.url !== config.controlUrl || previousController.token !== config.operatorToken || previousController.tokenFile !== config.operatorTokenFile;
    const local = isLoopback(new URL(config.controlUrl).hostname);
    if (local && d.terminal.interactive) {
      emit('setup', 'running');
      // A missing model never blocks the Bot path: the browser offers "Connect a model".
      // Runtimes older than the flag reject it as a usage error (64); rerun them without it.
      let setup = await d.spawn(launcher, ['setup', '--if-required', '--model-optional'], { attached: true, diagnostics: json });
      if (setup.exitCode === 64) setup = await d.spawn(launcher, ['setup', '--if-required'], { attached: true, diagnostics: json });
      if (setup.exitCode !== 0) { emit('setup', 'failed', 'setup_required'); return finish('setup_required'); }
      emit('setup', 'ok');
    } else emit('setup', 'skipped', local ? 'non_interactive' : 'remote_controller');
    const environment = Object.fromEntries(Object.entries(d.environment).filter(([key]) => key.startsWith('LEMON_BOT_')));
    if (local) environment.LEMON_CONTROL_PLANE_PORT = new URL(config.controlUrl).port || (new URL(config.controlUrl).protocol === 'wss:' ? '443' : '80');
    const lifecycle = (args: string[], stdin?: string) => service(launcher, args, d.spawn, { environment, ...(stdin === undefined ? {} : { stdin }) });
    const remember = (status: ServiceStatus) => { result.manager = status.manager; result.persistence = status.persistence; };
    emit('units', 'running');
    const units = await lifecycle(['install', ...(local ? ['controller', 'backend'] : ['backend']), '--bot', botPath, '--wait', '120', ...(controllerChanged ? ['--restart-backend'] : [])]);
    if (units.status) remember(units.status);
    if (units.exitCode !== 0 || !units.status || !units.status.units.length || units.status.units.some(unit => unit.state !== 'ready')) {
      const detail = units.status?.units.find(unit => unit.detail !== null && serviceDetails.includes(unit.detail))?.detail ?? 'service_failed';
      emit('units', 'failed', detail); return finish('service_failed');
    }
    emit('units', 'ok');
    if (result.persistence === 'session' && d.terminal.interactive) {
      emit('linger', 'running');
      if (['', 'y', 'yes'].includes((await d.terminal.read('Keep Lemon running after you log out? [Y/n] ')).trim().toLowerCase())) {
        const linger = await lifecycle(['repair', '--enable-linger']);
        if (linger.status) remember(linger.status);
        if (result.persistence === 'session') d.stderr(`sudo loginctl enable-linger ${userInfo().username}\n`);
        if (linger.exitCode !== 0) { emit('linger', 'failed', 'linger_unavailable'); return finish('service_failed'); }
        emit('linger', 'ok');
      } else emit('linger', 'skipped', 'declined');
    } else emit('linger', 'skipped');
    emit('owner', 'running');
    const identity = await d.hostIdentity();
    request = product(d.fetch, `http://127.0.0.1:${config.port}`);
    const auth = await request<AuthResult>('/auth/local', d.readKey(join(config.dataDir, 'local-access.key')), { displayName: identity.ownerName });
    session = auth.token;
    if (!session) throw new Error('Local owner session unavailable.');
    let controllerReady = false;
    for (let attempt = 0; attempt < 30; attempt++) {
      const instance = await request<InstanceStatus>('/instance', session);
      if (instance.controller.url === config.controlUrl && instance.controller.state === 'connected') { controllerReady = true; break; }
      if (instance.controller.state === 'rejected') break;
      if (attempt < 29) await d.sleep(2000);
    }
    if (!controllerReady) { emit('owner', 'failed', 'controller_unavailable'); return finish('service_failed'); }
    emit('owner', 'ok');
    failure = 'enroll_failed';
    if (flags.has('--no-worker') || !local) {
      emit('machine', 'skipped', local ? 'no_worker' : 'remote_controller');
      emit('worker', 'skipped', local ? 'no_worker' : 'remote_controller');
    } else {
      emit('machine', 'running');
      const all: Machine[] = [];
      let cursor: string | null = null;
      do {
        const page: Page<Machine> = await request(`/machines?limit=200${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`, session);
        all.push(...page.items); cursor = page.nextCursor;
      } while (cursor);
      let machine = all.find(machine => machine.nodeName === (name ?? identity.nodeName) && machine.status !== 'revoked');
      let invitation: MachineInvite | undefined;
      let online = false;
      const workerOnline = (value: ServiceResult) => value.exitCode === 0 && value.status?.units.some(unit => unit.role === 'worker' && unit.name === machine?.nodeName && unit.state === 'online') === true;
      const refresh = async () => request!<Machine>(`/machines/${encodeURIComponent(machine!.id)}`, session);
      if (machine) {
        result.machineId = machine.id;
        const status = await lifecycle(['status', 'worker', '--name', machine.nodeName]);
        online = machine.status === 'online' && workerOnline(status);
        const currentWrapper = status.status?.units.find(unit => unit.role === 'worker' && unit.name === machine?.nodeName)?.execWrapper;
        const wrapperChanged = wrapper !== undefined && currentWrapper !== wrapper;
        if (!online || wrapperChanged) {
          const wasOnline = online;
          emit('worker', 'running', 'repair');
          const repaired = await lifecycle(['repair', 'worker', '--name', machine.nodeName, '--wait', '60', ...(wrapper ? ['--exec-wrapper', wrapper] : [])]);
          online = workerOnline(repaired) && (await refresh()).status === 'online';
          if (wasOnline && wrapperChanged && !online) {
            emit('worker', 'failed', 'service_failed'); return finish('service_failed');
          }
        }
        if (!online) invitation = await request<MachineInvite>(`/machines/${encodeURIComponent(machine.id)}/reconnect`, session, { clientNonce: nonce() });
      } else {
        const initial = name ?? identity.nodeName;
        for (let attempt = 1; attempt <= 4; attempt++) {
          const candidate = attempt === 1 ? initial : `${initial.slice(0, 60)}-${attempt}`;
          try {
            const attached = await request<MachineAttachResult>('/machines', session, { name: identity.displayName, nodeName: candidate, clientNonce: nonce() });
            machine = attached.machine; invitation = attached.invite; result.machineId = machine.id; break;
          } catch (error) { if (!(error instanceof ProductError) || error.code !== 'conflict' || attempt === 4) throw error; }
        }
      }
      if (!machine) throw new Error('Machine unavailable.');
      emit('machine', 'ok');
      if (online) emit('worker', 'skipped', 'already_online');
      else {
        emit('worker', 'running');
        // Each invitation is attempted exactly once, including on pipe/command/receipt failure.
        const install = async (invite: MachineInvite) => {
          const target = joinTarget(invite.joinCommand);
          if (target.name !== machine!.nodeName || !/^[A-Za-z0-9_-]{43}$/.test(invite.inviteCode)) throw new Error('Invalid invitation.');
          return lifecycle(['install', 'worker', '--name', target.name, '--controller', target.controller, '--cwd', home, '--invite-code-stdin', '--wait', '60', ...(wrapper ? ['--exec-wrapper', wrapper] : [])], `${invite.inviteCode}\n`);
        };
        const waitOnline = async () => {
          for (let attempt = 0; attempt < 30; attempt++) {
            if ((await refresh()).status === 'online') return true;
            if (attempt < 29) await d.sleep(2000);
          }
          return false;
        };
        if (!invitation) throw new Error('Invitation unavailable.');
        let installed = await install(invitation);
        const uncertain = !installed.status || installed.status.units.some(unit => unit.detail === 'enrollment_outcome_unknown');
        if (uncertain) {
          const invites = await request<Page<MachineInvite>>(`/machines/${encodeURIComponent(machine.id)}/invites?limit=200`, session);
          const observed = invites.items.find(invite => invite.id === invitation!.id);
          const current = await refresh();
          if (current.status === 'online') {
            const repaired = await lifecycle(['repair', 'worker', '--name', machine.nodeName, '--wait', '60', ...(wrapper ? ['--exec-wrapper', wrapper] : [])]);
            if (!workerOnline(repaired)) throw new Error('Worker supervision unavailable.');
            online = true;
          } else if (observed?.status === 'joined') {
            const repair = await request<MachineInvite>(`/machines/${encodeURIComponent(machine.id)}/reconnect`, session, { clientNonce: nonce() });
            installed = await install(repair);
          } else throw new Error('Enrollment outcome unresolved.');
        }
        if (!online && (installed.exitCode !== 0 || !workerOnline(installed) || !await waitOnline())) throw new Error('Enrollment not online.');
        emit('worker', 'ok');
      }
    }
  } catch {
    emit(step, 'failed', failure); return finish(failure);
  } finally {
    if (session && request) {
      try { await request('/auth/logout', session, { clientNonce: nonce() }); }
      catch { d.stderr('The temporary owner session could not be signed out. Revoke it in Settings → Account → Sessions.\n'); }
    }
  }
  // This is the only browser hand-off: the open command owns private tickets and inherits the tty.
  if (d.terminal.interactive && !flags.has('--no-open')) {
    try {
      const opened = await d.spawn(d.botPath, ['open', ...(d.environment.SSH_CONNECTION || d.environment.SSH_TTY ? ['--headless'] : [])], { attached: true, diagnostics: json, environment: d.environment });
      if (opened.exitCode !== 0) return finish('needs_attention');
    } catch { return finish('needs_attention'); }
  }
  return finish('ready');
}
