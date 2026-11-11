import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext } from '../core/services';
import { ApiError, fail } from '../core/errors';

export interface MachineSshCommand {
  argv: string[];
  env: Record<string, string>;
  stdin: string;
  timeoutMs: number;
}
export interface MachineSshResult { exitCode: number; stdout: string; stderr: string; timedOut?: boolean }
export type MachineSshRunner = (command: MachineSshCommand) => Promise<MachineSshResult>;
export interface MachineSshHooks {
  issue(context: RequestContext, machine: P.Machine, options: { tunnelPort?: number }): Promise<P.MachineInvite>;
  revokeInvite(actor: Principal, invitation: P.MachineInvite): Promise<void>;
  refreshMachines(): Promise<void>;
  ensureMachineRuntimeReady(machine: P.Machine): Promise<unknown>;
  run?: MachineSshRunner;
}
interface Preview { reachability: 'loopback_only' | 'routable'; nodeGateway?: { available: boolean; port: number | null } }
interface SetupBinding { userId: string; nonce: string; fingerprint: string }
interface Lifecycle { schema: 1; persistence: P.MachineSetup['persistence']; units: { role: string; name: string | null; state: string; detail: string | null }[] }
const outputLimit = 65_536;
const installStarted = 'LEMON_SSH_INSTALL_STARTED';
const sshOptions = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ForwardAgent=no', '-o', 'ForwardX11=no', '-o', 'ControlMaster=no', '-o', 'ControlPath=none', '-o', 'PermitLocalCommand=no', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3'];
const tunnelDetails: Record<P.MachineLinkDetail, true> = { ssh_auth_failed: true, host_key_changed: true, host_unreachable: true, forward_refused: true, remote_port_in_use: true };
const messages: Record<P.MachineSetupFailure, string> = {
  ssh_unreachable: 'The destination could not be reached over SSH.',
  ssh_auth_failed: 'SSH sign-in failed. Make sure SSH works without a password.',
  ssh_host_key_changed: 'The SSH host identity changed. Check its key before reconnecting.',
  unsupported_host: 'The destination does not support this Lemon installation.',
  port_in_use: 'A required destination loopback port is already in use.',
  forward_refused: 'The SSH server refused the secure link.',
  runtime_install_failed: 'Lemon could not be installed on the destination.',
  enroll_failed: 'Enrollment failed. The invite must not be reused.',
  enroll_outcome_unknown: 'Enrollment may have completed. Reconcile this machine before issuing a repair invite.',
  service_failed: 'The worker service did not become online.',
  not_bot_ready: 'The worker is connected but is not ready to run Bots.',
  controller_unavailable: 'The controller or its node gateway is unavailable.',
  interrupted: 'Setup was interrupted by a backend restart. Reconnect to repair it.',
};
class SetupFailure extends Error {
  constructor(readonly code: P.MachineSetupFailure, readonly detail: string | null = null) { super(messages[code]); }
}
function quote(value: string): string { return `'${value.replaceAll("'", "'\\''")}'`; }
function loopback(url: string): boolean {
  try { return ['localhost', '127.0.0.1', '[::1]', '::1'].includes(new URL(url).hostname); } catch { return false; }
}
function port(value: unknown): value is number { return Number.isInteger(value) && Number(value) > 0 && Number(value) <= 65535; }
export function machineSshEnvironment(environment: NodeJS.ProcessEnv = process.env): Record<string, string> {
  const result: Record<string, string> = { LC_ALL: 'C' };
  for (const name of ['HOME', 'USER', 'LOGNAME', 'PATH', 'SSH_AUTH_SOCK']) if (environment[name] !== undefined) result[name] = environment[name]!;
  return result;
}
/** Output is bounded while draining both streams, so a noisy remote cannot exhaust backend memory. */
export const runMachineSshCommand: MachineSshRunner = async command => {
  const child = Bun.spawn(command.argv, { env: command.env, stdin: new Blob([command.stdin]), stdout: 'pipe', stderr: 'pipe' });
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, command.timeoutMs);
  async function collect(stream: ReadableStream<Uint8Array>): Promise<string> {
    const reader = stream.getReader(); const decoder = new TextDecoder(); let text = '';
    try { for (;;) { const { done, value } = await reader.read(); if (done) break; text = (text + decoder.decode(value, { stream: true })).slice(-outputLimit); } return (text + decoder.decode()).slice(-outputLimit); }
    finally { reader.releaseLock(); }
  }
  try { const [exitCode, stdout, stderr] = await Promise.all([child.exited, collect(child.stdout), collect(child.stderr)]); return { exitCode, stdout, stderr, timedOut }; }
  finally { clearTimeout(timer); }
};
function diagnostic(text: string, secrets: string[]): string | null {
  let safe = text.slice(-outputLimit);
  for (const secret of secrets) if (secret) safe = safe.replaceAll(secret, '[redacted]');
  safe = safe.replace(/[A-Za-z0-9_-]{43,}/g, '[redacted]').replace(/\u001b\[[0-9;]*[A-Za-z]/g, '').replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '');
  const lines = safe.split(/\r?\n/).filter(line => line.trim() && !/code=|token|authorization|bearer|password|BEGIN .*PRIVATE KEY/i.test(line));
  return lines.slice(-8).join('\n').slice(-2048) || null;
}
function sshFailure(result: MachineSshResult): P.MachineSetupFailure {
  if (/REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed|host_key_changed/i.test(result.stderr)) return 'ssh_host_key_changed';
  if (/Permission denied|Authentication failed|Too many authentication failures|ssh_auth_failed/i.test(result.stderr)) return 'ssh_auth_failed';
  if (/remote_port_in_use/i.test(result.stderr)) return 'port_in_use';
  if (/remote port forwarding failed|forward_refused|administratively prohibited/i.test(result.stderr)) return 'forward_refused';
  return 'ssh_unreachable';
}
function lifecycle(stdout: string): Lifecycle | null {
  try {
    const value = JSON.parse(stdout.trim().split(/\r?\n/).at(-1) ?? '');
    if (value.schema !== 1 || !['login', 'boot', 'session', 'none'].includes(value.persistence) || !Array.isArray(value.units)) return null;
    if (!value.units.every((unit: unknown) => typeof unit === 'object' && unit !== null && 'state' in unit && typeof unit.state === 'string' && 'role' in unit && typeof unit.role === 'string')) return null;
    return value as Lifecycle;
  } catch { return null; }
}
export function machineSshPreview(services: BackendServices, preview: Preview): P.MachineEnrollmentPreview & { ssh: NonNullable<P.MachineEnrollmentPreview['ssh']> } {
  const reason = !loopback(services.config.controlUrl) ? 'controller_remote' : !preview.nodeGateway?.available || !port(preview.nodeGateway.port) ? 'node_gateway_unavailable' : !services.config.runtimeLauncher ? 'launcher_unavailable' : null;
  return { reachability: preview.reachability, ssh: { available: reason === null, reason } };
}
function sshCommand(destination: string, script: string, timeoutMs: number): MachineSshCommand {
  return { argv: ['/usr/bin/ssh', ...sshOptions, '-T', '--', destination, 'sh', '-s'], env: machineSshEnvironment(), stdin: script, timeoutMs };
}
function launcherCommand(services: BackendServices, args: string[], timeoutMs = 30_000): MachineSshCommand {
  if (!services.config.runtimeLauncher) throw new SetupFailure('controller_unavailable');
  return { argv: [services.config.runtimeLauncher, 'service', ...args, '--json'], env: machineSshEnvironment(), stdin: '', timeoutMs };
}
function destination(input: string): string {
  const value = input.trim().replace(/^ssh\s+/, '');
  if (!value || value.length > 255 || !/^[a-zA-Z0-9._@:[\]%-]+$/.test(value) || /^[-@]|@$/.test(value)) fail('invalid_request', 'Enter a valid SSH destination such as me@studio.');
  return value;
}
function nodeName(host: string): string { return host.toLowerCase().replace(/[^a-z0-9_.-]/g, '').replace(/^[^a-z0-9]+/, '').slice(0, 64) || 'lemon-host'; }
function probeScript(productPort: number | null): string {
  return `set -eu
command -v curl >/dev/null 2>&1 || { echo unsupported_host >&2; exit 1; }
printf 'host=%s\\n' "$(hostname -s 2>/dev/null || hostname)"
printf 'computer=%s\\n' "$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null || hostname)"
printf 'os=%s\\narch=%s\\n' "$(uname -s)" "$(uname -m)"
service=none; linger=unknown
if [ "$(uname -s)" = Darwin ] && command -v launchctl >/dev/null 2>&1; then service=launchd
elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
 service=systemd
 linger=$(loginctl show-user "$(id -u)" -p Linger --value 2>/dev/null || echo unknown)
fi
printf 'service=%s\\nlinger=%s\\n' "$service" "$linger"
for p in ${Array.from({ length: 20 }, (_, index) => index + 4044).concat(productPort === null ? [] : [productPort]).filter((value, index, values) => values.indexOf(value) === index).join(' ')}; do
 rc=0; curl --noproxy '*' -s -m 2 -o /dev/null "http://127.0.0.1:$p/" || rc=$?
 [ "$rc" -ne 7 ] || printf 'free=%s\\n' "$p"
done
`;
}
/** Parse only the controller's quoted data arguments; never execute its join command. */
function invitationArguments(command: string): Map<string, string> {
  const words: string[] = []; let word = ''; let active = false; let quoted = false;
  for (let index = 0; index < command.length; index++) {
    const char = command[index]!;
    if (char === "'") { quoted = !quoted; active = true; }
    else if (!quoted && char === '\\') { const next = command[++index]; if (next === undefined) throw new SetupFailure('runtime_install_failed'); word += next; active = true; }
    else if (!quoted && /\s/.test(char)) { if (active) { words.push(word); word = ''; active = false; } }
    else { word += char; active = true; }
  }
  if (quoted) throw new SetupFailure('runtime_install_failed');
  if (active) words.push(word);
  const args = new Map<string, string>();
  for (let index = 0; index < words.length; index++) if (['--name', '--controller', '--source', '--version', '--base-url'].includes(words[index]!)) {
    const key = words[index]!; const value = words[++index];
    if (value === undefined || args.has(key) || /[\u0000-\u001f\u007f]/.test(value)) throw new SetupFailure('runtime_install_failed');
    args.set(key, value);
  }
  return args;
}
function installationScript(machine: P.Machine, invitation: P.MachineInvite, expectedController: string | null): string {
  const args = invitationArguments(invitation.joinCommand);
  const controller = args.get('--controller') ?? '';
  const source = args.get('--source') ?? ''; const version = args.get('--version') ?? ''; const base = args.get('--base-url') ?? '';
  if (!/^[A-Za-z0-9_-]{43}$/.test(invitation.inviteCode) || args.get('--name') !== machine.nodeName || (expectedController !== null && controller !== expectedController)) throw new SetupFailure('runtime_install_failed');
  try { const url = new URL(controller); if (url.username || url.password || url.search || url.hash || !(url.protocol === 'wss:' || url.protocol === 'ws:' && loopback(controller))) throw new Error(); }
  catch { throw new SetupFailure('runtime_install_failed'); }
  if (source ? !source.startsWith('/') : !/^\d+\.\d+\.\d+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?$/.test(version)) throw new SetupFailure('runtime_install_failed');
  if (!source) { try { const url = new URL(base); if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) throw new Error(); } catch { throw new SetupFailure('runtime_install_failed'); } }
  return `set -eu
umask 077
name=${quote(machine.nodeName)}
controller=${quote(controller)}
source=${quote(source)}
version=${quote(version)}
base_url=${quote(base.replace(/\/$/, ''))}
code=${quote(invitation.inviteCode)}
tmp=$(mktemp) || exit 1
trap 'rm -f "$tmp"' EXIT HUP INT TERM
if [ -n "$source" ]; then
 cp "$source/scripts/join-node.sh" "$tmp" || exit 1
else
 curl --noproxy '*' -fsSL --proto '=https' --proto-redir '=https' "$base_url/releases/download/v$version/join-node.sh" -o "$tmp" || exit 1
fi
set -- --name "$name" --controller "$controller" --cwd "$HOME" --code-stdin --json
[ -z "$source" ] || set -- "$@" --source "$source"
[ -z "$version" ] || set -- "$@" --version "$version"
[ -z "$base_url" ] || set -- "$@" --base-url "$base_url"
printf '%s\\n' '${installStarted}'
printf '%s\\n' "$code" | bash "$tmp" "$@"
`;
}

export function createMachineSshSetup(services: BackendServices, hooks: MachineSshHooks) {
  const run = hooks.run ?? runMachineSshCommand;
  const jobs = new Set<Promise<void>>();
  function binding(id: string): SetupBinding { const value = services.store.metadata<SetupBinding>(`machineSshSetup:${id}`); if (!value) fail('not_found', 'Machine setup was not found.'); return value; }
  function save(value: P.MachineSetup, changes: Partial<P.MachineSetup>): P.MachineSetup {
    const next = services.update(value, changes); services.store.put('machineSetups', next);
    services.events.emit('machine_setup.upserted', next, { userIds: [binding(value.id).userId] }); return next;
  }
  for (const setup of services.store.list<P.MachineSetup>('machineSetups', value => value.state === 'running')) {
    save(setup, { state: 'failed', failure: { code: 'interrupted', message: messages.interrupted, detail: null }, finishedAtMs: services.now() });
  }
  function machineSave(value: P.Machine): P.Machine { services.store.put('machines', value); services.events.emit('machine.upserted', value, { machineId: value.id }); return value; }
  async function execute(initial: P.MachineSetup, context: RequestContext, request: P.MachineSshSetupRequest, actor: Principal): Promise<void> {
    let setup = initial; let secret = '';
    const change = (changes: Partial<P.MachineSetup>) => { setup = save(setup, changes); };
    try {
      if (!services.lemon.connected) throw new SetupFailure('controller_unavailable');
      const preview = await services.lemon.call<Preview>('node.pair.preview');
      if (!preview || !['loopback_only', 'routable'].includes(preview.reachability) || !machineSshPreview(services, preview).ssh.available) throw new SetupFailure('controller_unavailable');
      const tunneled = preview.reachability === 'loopback_only';
      const publicUrl = new URL(services.config.publicUrl);
      const productLoopback = publicUrl.hostname === 'localhost' || publicUrl.hostname.endsWith('.localhost') || /^127\./.test(publicUrl.hostname) || publicUrl.hostname === '[::1]' || publicUrl.hostname === '0.0.0.0';
      // The tunnel binds and forwards only literal IPv4 loopback, not localhost or IPv6.
      if (tunneled && productLoopback && (publicUrl.protocol !== 'http:' || publicUrl.hostname !== '127.0.0.1' || publicUrl.username || publicUrl.password)) throw new SetupFailure('not_bot_ready', 'SSH product forwarding requires an HTTP origin on 127.0.0.1.');
      const productPort = tunneled && productLoopback ? Number(publicUrl.port || '80') : null;
      let machine = request.machineId ? services.store.require<P.Machine>('machines', request.machineId) : services.store.list<P.Machine>('machines', value => value.status !== 'revoked' && value.link?.kind === 'ssh_tunnel' && value.link.sshDestination === setup.sshDestination)[0];
      if (machine && machine.ownerUserId !== actor.userId && !['owner', 'admin'].includes(actor.role)) fail('forbidden', 'Only a machine manager can repair it.');
      if (machine?.status === 'revoked') fail('conflict', 'A detached machine cannot be repaired.');
      const probe = await run(sshCommand(setup.sshDestination, probeScript(productPort), 30_000));
      if (probe.exitCode !== 0 || probe.timedOut) throw new SetupFailure(/unsupported_host/.test(probe.stderr) ? 'unsupported_host' : sshFailure(probe), diagnostic(probe.stderr, [services.config.operatorToken]));
      const fields = new Map(probe.stdout.split(/\r?\n/).filter(line => !line.startsWith('free=')).map(line => { const at = line.indexOf('='); return [line.slice(0, at), line.slice(at + 1)]; }));
      if (!['Linux', 'Darwin'].includes(fields.get('os') ?? '') || !['x86_64', 'arm64', 'aarch64'].includes(fields.get('arch') ?? '') || !['launchd', 'systemd', 'none'].includes(fields.get('service') ?? '')) throw new SetupFailure('unsupported_host');
      const free = probe.stdout.split(/\r?\n/).filter(line => /^free=\d+$/.test(line)).map(line => Number(line.slice(5)));
      const previousLink = machine?.link?.kind === 'ssh_tunnel' ? machine.link : null;
      const nodePort = tunneled ? previousLink?.nodePort ?? free.find(value => value >= 4044 && value <= 4063 && value !== productPort) : null;
      if (tunneled && (!nodePort || productPort !== null && !free.includes(productPort) && previousLink?.productPort !== productPort)) throw new SetupFailure('port_in_use');
      const link: P.MachineLink = tunneled ? { kind: 'ssh_tunnel', sshDestination: setup.sshDestination, nodePort: nodePort!, productPort, tunnel: { state: 'unknown', detail: null, checkedAtMs: null } } : { kind: 'direct' };
      if (!machine) {
        const name = nodeName(fields.get('host') ?? '');
        if (services.store.list<P.Machine>('machines', value => value.nodeName === name).length) fail('conflict', 'This durable machine name is already attached. Retry that machine explicitly.');
        machine = machineSave(services.resource('machine', { nodeId: null, nodeName: name, name: request.name ?? (fields.get('computer') || fields.get('host') || name).slice(0, 120), ownerUserId: actor.userId, accessUserIds: [], status: 'pending', credential: 'unknown', lastSeenAtMs: null, labels: {}, botIds: [], link } satisfies Omit<P.Machine, keyof P.Resource>));
      } else machine = machineSave(services.update(machine, { link, ...(request.name ? { name: request.name } : {}) }));
      change({ machineId: machine.id });
      if (tunneled) {
        change({ step: 'opening_tunnel' });
        const args = ['install', 'tunnel', '--name', machine.nodeName, '--ssh', setup.sshDestination, '--node-port', String(nodePort), '--gateway-port', String(preview.nodeGateway!.port), ...(productPort === null ? [] : ['--product-port', String(productPort), '--backend-port', String(services.config.port)]), '--wait', '15'];
        const opened = await run(launcherCommand(services, args, 30_000));
        const receipt = lifecycle(opened.stdout); const unit = receipt?.units.find(value => value.role === 'tunnel' && value.name === machine!.nodeName);
        if (opened.exitCode !== 0 || opened.timedOut || unit?.state !== 'online') {
          const detail = `${opened.stderr}\n${unit?.detail ?? ''}`;
          throw new SetupFailure(unit?.detail === 'host_unreachable' ? 'ssh_unreachable' : sshFailure({ ...opened, stderr: detail }), diagnostic(detail, [services.config.operatorToken]));
        }
        const check = await run(sshCommand(setup.sshDestination, `set -eu\ncurl --noproxy '*' -fsS -m 3 http://127.0.0.1:${nodePort}/healthz\n${productPort === null ? '' : `printf '\\n'\ncurl --noproxy '*' -fsS -m 3 http://127.0.0.1:${productPort}/v1/setup\n`}`, 30_000));
        if (check.exitCode !== 0 || check.timedOut || !check.stdout.includes('lemon-node-gateway') || productPort !== null && !check.stdout.includes('lemon_bot')) throw new SetupFailure(check.exitCode === 255 ? sshFailure(check) : 'forward_refused', diagnostic(check.stderr, [services.config.operatorToken]));
        machine = machineSave(services.update(machine, { link: { ...link, kind: 'ssh_tunnel', sshDestination: setup.sshDestination, nodePort: nodePort!, productPort, tunnel: { state: 'online', detail: null, checkedAtMs: services.now() } } }));
      }
      change({ step: 'issuing_invite' });
      await hooks.refreshMachines();
      machine = services.store.require<P.Machine>('machines', machine.id);
      if (services.store.metadata<boolean>(`machineSshEnrollmentUncertain:${machine.id}`) && !machine.nodeId) throw new SetupFailure('enroll_outcome_unknown');
      for (const invite of services.store.list<P.MachineInvite>('machineInvites', value => value.machineId === machine!.id && value.status === 'pending')) await hooks.revokeInvite(actor, invite);
      const invitation = await hooks.issue(context, machine, nodePort === null ? {} : { tunnelPort: nodePort });
      secret = invitation.inviteCode;
      const script = installationScript(machine, invitation, nodePort === null ? null : `ws://127.0.0.1:${nodePort}/ws`);
      change({ step: 'installing' });
      // Persist before sending any enrollment bytes. A restart must reconcile, never replay this code.
      services.store.setMetadata(`machineSshEnrollmentUncertain:${machine.id}`, true);
      const installed = await run(sshCommand(setup.sshDestination, script, 600_000));
      const detail = diagnostic(installed.stderr, [secret, services.config.operatorToken]);
      const receipt = lifecycle(installed.stdout);
      if (receipt) change({ persistence: receipt.persistence });
      const worker = receipt?.units.find(value => value.role === 'worker' && value.name === machine!.nodeName);
      const serviceDetail = diagnostic([installed.stderr, worker?.detail ?? ''].join('\n'), [secret, services.config.operatorToken]);
      if (installed.timedOut || installed.exitCode === 255) {
        const code = sshFailure(installed);
        if (!installed.stdout.includes(installStarted) && !installed.timedOut && ['ssh_auth_failed', 'ssh_host_key_changed'].includes(code)) {
          services.store.setMetadata(`machineSshEnrollmentUncertain:${machine.id}`, false);
          throw new SetupFailure(code, detail);
        }
        // No start receipt is not proof that a disconnected SSH script never ran.
        throw new SetupFailure('enroll_outcome_unknown', detail);
      }
      if (installed.exitCode === 1) { services.store.setMetadata(`machineSshEnrollmentUncertain:${machine.id}`, false); throw new SetupFailure(/unsupported|not supported/i.test(installed.stderr) ? 'unsupported_host' : 'runtime_install_failed', detail); }
      if (installed.exitCode === 2) throw new SetupFailure('enroll_failed', serviceDetail);
      if (installed.exitCode === 3) throw new SetupFailure('service_failed', serviceDetail);
      if (installed.exitCode !== 0 || !receipt) throw new SetupFailure('enroll_outcome_unknown', detail);
      if (worker?.state !== 'online') throw new SetupFailure(worker && ['needs_enrollment', 'conflict'].includes(worker.state) ? 'enroll_failed' : 'service_failed', diagnostic(worker?.detail ?? '', [secret, services.config.operatorToken]));
      change({ step: 'verifying' });
      await hooks.refreshMachines();
      machine = services.store.require<P.Machine>('machines', machine.id);
      if (!machine.nodeId || machine.status === 'offline' || machine.status === 'revoked') throw new SetupFailure('service_failed');
      try { await hooks.ensureMachineRuntimeReady(machine); } catch (error) { throw new SetupFailure(error instanceof ApiError && error.code === 'upstream_unavailable' ? 'controller_unavailable' : 'not_bot_ready'); }
      if (machine.status !== 'online') throw new SetupFailure('service_failed');
      services.store.setMetadata(`machineSshEnrollmentUncertain:${machine.id}`, false);
      change({ step: 'online', state: 'succeeded', failure: null, finishedAtMs: services.now() });
    } catch (error) {
      const failure = error instanceof SetupFailure ? error : new SetupFailure(error instanceof ApiError && error.code === 'capability_unavailable' ? 'not_bot_ready' : error instanceof ApiError && error.code === 'outcome_unknown' ? 'enroll_outcome_unknown' : setup.step === 'installing' ? 'enroll_outcome_unknown' : 'controller_unavailable');
      change({ state: 'failed', failure: { code: failure.code, message: failure.message, detail: diagnostic(failure.detail ?? '', [secret, services.config.operatorToken]) }, finishedAtMs: services.now() });
    }
  }
  return {
    start(context: RequestContext, request: P.MachineSshSetupRequest): P.MachineSetup {
      const actor = context.user;
      if (!actor || actor.kind !== 'user' || !['owner', 'admin'].includes(actor.role)) fail('forbidden', 'Only an owner or administrator may add a machine over SSH.');
      const dest = destination(request.sshDestination);
      if (!request.clientNonce || request.clientNonce.length > 200 || request.name !== undefined && (!request.name.trim() || request.name.length > 120 || /[\u0000-\u001f\u007f]/.test(request.name))) fail('invalid_request', 'Invalid machine setup request.');
      const fingerprint = services.mutations.digest({ sshDestination: dest, name: request.name ?? null, machineId: request.machineId ?? null });
      const result = services.store.transaction(() => {
        for (const setup of services.store.list<P.MachineSetup>('machineSetups')) {
          const previous = binding(setup.id);
          if (previous.userId === actor.userId && previous.nonce === request.clientNonce) { if (previous.fingerprint !== fingerprint) fail('conflict', 'This nonce belongs to another machine setup request.'); return { setup, created: false }; }
        }
        const target = request.machineId ? services.store.require<P.Machine>('machines', request.machineId) : services.store.list<P.Machine>('machines', value => value.status !== 'revoked' && value.link?.kind === 'ssh_tunnel' && value.link.sshDestination === dest)[0];
        if (target) {
          if (target.ownerUserId !== actor.userId && !['owner', 'admin'].includes(actor.role)) fail('forbidden', 'Only a machine manager can repair it.');
          if (target.status === 'revoked') fail('conflict', 'A detached machine cannot be repaired.');
          if (target.link?.kind === 'ssh_tunnel' && target.link.sshDestination !== dest) fail('conflict', 'Reconnect must use the machine’s existing SSH destination.');
        }
        if (services.store.list<P.MachineSetup>('machineSetups', value => value.state === 'running' && (value.sshDestination === dest || target !== undefined && value.machineId === target.id)).length) fail('conflict', 'A setup is already running for this destination or machine.');
        const setup: P.MachineSetup = services.resource('machine_setup', { machineId: target?.id ?? null, sshDestination: dest, step: 'checking_ssh', state: 'running', failure: null, persistence: null, finishedAtMs: null });
        services.store.setMetadata(`machineSshSetup:${setup.id}`, { userId: actor.userId, nonce: request.clientNonce, fingerprint } satisfies SetupBinding);
        services.store.put('machineSetups', setup); services.events.emit('machine_setup.upserted', setup, { userIds: [actor.userId] }); return { setup, created: true };
      });
      context.nonceResourceIds.push(result.setup.id);
      if (result.created) { const job = Promise.resolve().then(() => execute(result.setup, context, { ...request, sshDestination: dest, ...(result.setup.machineId ? { machineId: result.setup.machineId } : {}) }, actor)); jobs.add(job); void job.finally(() => jobs.delete(job)); }
      return result.setup;
    },
    get(actor: Principal, id: string): P.MachineSetup {
      const setup = services.store.require<P.MachineSetup>('machineSetups', id);
      if (actor.kind !== 'user' || actor.userId !== binding(id).userId && actor.role !== 'owner') fail('not_found', 'Machine setup was not found.');
      return setup;
    },
    async drain(): Promise<void> { await Promise.all(jobs); },
  };
}

const tunnelCache = new WeakMap<BackendServices, { checkedAtMs: number; pending: Promise<void> }>();
export async function refreshMachineTunnelStatus(services: BackendServices, run: MachineSshRunner = runMachineSshCommand): Promise<void> {
  const previous = tunnelCache.get(services);
  if (previous && services.now() - previous.checkedAtMs < 10_000) return previous.pending;
  const machines = services.store.list<P.Machine>('machines', value => value.status !== 'revoked' && value.link?.kind === 'ssh_tunnel');
  if (!machines.length) return;
  const pending = (async () => {
    let receipt: Lifecycle | null = null;
    try { const result = await run(launcherCommand(services, ['status'])); if (result.exitCode === 0 && !result.timedOut) receipt = lifecycle(result.stdout); } catch { /* An unmeasurable tunnel is unknown, never offline. */ }
    for (const original of machines) {
      const machine = services.store.require<P.Machine>('machines', original.id);
      if (machine.link?.kind !== 'ssh_tunnel') continue;
      const unit = receipt?.units.find(value => value.role === 'tunnel' && value.name === machine.nodeName);
      const state: P.MachineLinkState = unit && ['online', 'reconnecting', 'failed', 'stopped'].includes(unit.state) ? unit.state as P.MachineLinkState : 'unknown';
      const detail = unit?.detail && Object.hasOwn(tunnelDetails, unit.detail) ? unit.detail as P.MachineLinkDetail : null;
      const next = services.update(machine, { link: { ...machine.link, tunnel: { state, detail, checkedAtMs: services.now() } } }); services.store.put('machines', next);
      if (machine.link.tunnel.state !== state || machine.link.tunnel.detail !== detail) services.events.emit('machine.upserted', next, { machineId: next.id });
    }
  })();
  tunnelCache.set(services, { checkedAtMs: services.now(), pending }); await pending;
}
export async function uninstallMachineTunnel(services: BackendServices, actor: Principal, machine: P.Machine, run: MachineSshRunner = runMachineSshCommand): Promise<void> {
  if (machine.link?.kind !== 'ssh_tunnel') return;
  try { const result = await run(launcherCommand(services, ['uninstall', 'tunnel', '--name', machine.nodeName])); if (result.exitCode !== 0 || result.timedOut) throw new Error('uninstall_failed'); services.audit(actor, 'machine.tunnel_uninstall', machine.id, 'succeeded'); }
  catch { services.audit(actor, 'machine.tunnel_uninstall', machine.id, 'failed'); }
}
