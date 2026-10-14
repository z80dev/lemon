import { isIP } from 'node:net';
import { posix } from 'node:path';
import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext, Route } from '../core/services';
import { fail } from '../core/errors';
import { integrationConfiguration } from '../integrations/config';

/**
 * Trusted driver protocol (version 1): argv/cwd/probeArgv are operator-owned.
 * Stdin is one JSON operation; stdout must contain a JSON line with type
 * lemon_bot_host_result, matching operationId/machineId/configDigest/inputDigest.
 * A successful exit without that exact verified receipt is outcome_unknown.
 * Probes use the SAME ID/input and never execute the action again. No raw output
 * is persisted, audited, or returned. Destination drivers own secret resolution,
 * child environment wiping, firewall installation, encrypted tunnels and safe
 * points; their verified receipts attest these concrete effects.
 */
const id = z.string().min(1).max(256).refine(v => !/[\x00-\x1f/]/.test(v));
const nonce = z.string().regex(/^[A-Za-z0-9_-]{16,128}$/);
const mutation = z.object({ clientNonce: nonce }).strict();
const update = mutation.extend({ revision: z.number().int().positive().max(Number.MAX_SAFE_INTEGER) });
const machineIds = z.array(id).min(1).max(1000).refine(v => new Set(v).size === v.length);
const action = z.enum(['update', 'recover', 'restart_worker', 'stop_worker', 'suspend', 'recreate_environment', 'delete_environment']);
const command = z.object({ argv: z.array(z.string().min(1).max(32768)).min(1).max(128), cwd: z.string().startsWith('/'), timeoutMs: z.number().int().min(1000).max(1800000), probeArgv: z.array(z.string().min(1).max(32768)).min(1).max(128) }).strict();
const entry = z.object({ id, setupScript: z.string().min(1).max(262144), checkScript: z.string().min(1).max(262144).nullable(), secretNames: z.array(z.string().regex(/^[A-Za-z_][A-Za-z0-9_]{0,127}$/)).max(100).refine(v => new Set(v).size === v.length), timeoutMs: z.number().int().min(1000).max(1800000) }).strict();
const entries = z.array(entry).min(1).max(100).refine(v => new Set(v.map(e => e.id)).size === v.length);
const reviewed = z.object({ name: z.string().min(1).max(120), directoryGroupId: id.nullable(), machineIds, entries }).strict();
export type ReviewedSetup = z.infer<typeof reviewed>;
export interface HostOptions { reviewedSetups?: ReviewedSetup[] }
const receiptSchema = z.object({
  type: z.literal('lemon_bot_host_result'), version: z.literal(1), operationId: id, machineId: id,
  configDigest: z.string(), inputDigest: z.string(), state: z.enum(['succeeded', 'skipped', 'failed', 'pending', 'not_found']),
  exitCode: z.number().int().nullable(), appliedRevision: z.number().int().positive().optional(),
  skipReason: z.enum(['already_current', 'already_stopped', 'environment_absent', 'unsupported']).optional(),
  authenticated: z.boolean().optional(), encrypted: z.boolean().optional(), enabled: z.boolean().optional(),
  destinationSecretsOnly: z.boolean().optional(), secretsWiped: z.boolean().optional(),
  safePoint: z.boolean().optional(), retainedUserHome: z.boolean().optional(), retainedSSH: z.boolean().optional(),
  retainedDisk: z.boolean().optional(), retainedIdentity: z.boolean().optional(),
  isolatedEnvironment: z.boolean().optional(),
  environmentRoot: z.string().nullable().optional(), lastBackupAtMs: z.number().int().nonnegative().nullable().optional(),
  hostState: z.enum(['awake', 'idle', 'sleeping']).optional(), inactiveSinceMs: z.number().int().nonnegative().optional(),
}).strict();
type Receipt = z.infer<typeof receiptSchema>;
type JobKind = 'host' | 'network' | 'egress' | 'setup' | 'inspect';
interface DriverJob extends P.Resource {
  kind: JobKind; targetId: string; machineId: string; command: P.HostDriverCommand;
  configDigest: string; inputDigest: string; encryptedInput: string;
  state: 'reserved' | 'dispatched' | 'unknown' | 'succeeded' | 'skipped' | 'failed'; receipt: Receipt | null;
}
interface ApplicationRecord { id: string; policyId: string; jobId: string | null; configDigest: string; principal: Principal; value: P.PolicyApplication }
interface SetupExecution { id: string; principal: Principal; manifest: P.SetupManifest; machineRevision: number; index: number; phase: 'check' | 'setup' | 'recheck'; jobId: string | null }
interface OperationBinding { id: string; principal: Principal; snapshot: unknown; inactivePolicy?: { afterDays: number } }
export interface HostSnapshot {
  id: string; revision: number; nodeId: string | null; name: string;
  configDigest: string; environmentRoot: string | null;
  backup: { lastBackupAtMs: number | null } | null;
}
export interface HostServices {
  admission(p: Principal, botId: string): Promise<void>;
  appliedPolicyAdmission(p: Principal, botId: string): Promise<void>;
  governanceChanged(previous: P.Governance, next: P.Governance): Promise<void>;
  reconcile(): Promise<void>;
  processInactiveHosts(): Promise<void>;
  dispose(): void;
  driver(machineId: string): P.HostDriverConfig | null;
  management(p: Principal, machineId: string): Promise<P.HostManagement>;
  machine(p: Principal, machineId: string, manage?: boolean): P.Machine;
  online(m: P.Machine): void;
  reserve(kind: JobKind, targetId: string, m: P.Machine, cmd: P.HostDriverCommand, input: Record<string, unknown>): DriverJob;
  runJob(job: DriverJob): Promise<DriverJob>;
  applyNetwork(p: Principal, policy: P.NetworkPolicy, ids: string[], removing?: boolean): Promise<P.Page<P.PolicyApplication>>;
  deleteNetwork(p: Principal, policy: P.NetworkPolicy): Promise<P.Deleted | null>;
  authorizeEgress(p: Principal, source: string, through: string, enabling: boolean): Promise<P.Machine>;
  changeEgress(p: Principal, route: P.EgressRoute, enabled: boolean, central?: boolean): Promise<P.EgressRoute>;
  authorizeManifest(p: Principal, manifest: Pick<P.SetupManifest, 'name' | 'directoryGroupId' | 'machineIds' | 'entries'>): void;
  reviewSetups(): ReviewedSetup[];
  snapshot(p: Principal, ids: string[], act: P.HostAction): HostSnapshot[];
  operationTarget(p: Principal): { id: string; revision: number };
  saveOperation(o: P.HostOperation): P.HostOperation;
  launchOperation(o: P.HostOperation): Promise<void>;
  saveRun(r: P.SetupRun): P.SetupRun;
  setupStep(execution: SetupExecution): Promise<void>;
  work(key: string, fn: () => Promise<void>): Promise<void>;
  saveEgress(r: P.EgressRoute): P.EgressRoute;
}
const activeOperation = (o: P.HostOperation) => ['queued', 'running', 'outcome_unknown'].includes(o.state);
const parse = <T>(schema: z.ZodType<T>, body: unknown): T => {
  const result = schema.safeParse(body);
  if (!result.success) fail('invalid_request', 'Invalid host management request.');
  return result.data;
};
const principal = (c: RequestContext): Principal => {
  if (!c.user) fail('unauthenticated', 'Sign in to manage hosts.');
  return c.user;
};
const quote = (value: string) => `'${value.replace(/'/g, `'\\''`)}'`;

/** Canonical CIDR rejects host bits, ambiguous IPv4 and noncanonical IPv6. */
export function canonicalNetworkRule(rule: P.NetworkRule): boolean {
  if (!rule.ports.length || new Set(rule.ports).size !== rule.ports.length || rule.ports.some(p => !Number.isInteger(p) || p < 1 || p > 65535)) return false;
  if (rule.kind === 'domain') return /^(\*\.)?(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(rule.value);
  const [address, prefix, extra] = rule.value.split('/');
  if (!address || prefix === undefined || extra !== undefined || !/^(0|[1-9][0-9]*)$/.test(prefix)) return false;
  const family = isIP(address), bits = Number(prefix);
  if (!family || bits > (family === 4 ? 32 : 128)) return false;
  let number = 0n;
  if (family === 4) for (const part of address.split('.')) number = (number << 8n) | BigInt(part);
  else {
    if (!/^[0-9a-f:]+$/.test(address)) return false;
    const [left, right] = address.split('::');
    const l = left ? left.split(':') : [], r = right ? right.split(':') : [];
    const groups = right !== undefined ? [...l, ...Array<string>(8 - l.length - r.length).fill('0'), ...r] : l;
    if (groups.length !== 8) return false;
    for (const part of groups) number = (number << 16n) | BigInt(`0x${part}`);
    const url = new URL(`http://[${address}]/`);
    if (url.hostname.slice(1, -1) !== address) return false;
  }
  const hostBits = BigInt((family === 4 ? 32 : 128) - bits);
  return (number & ((1n << hostBits) - 1n)) === 0n;
}
const rule = z.object({ kind: z.enum(['domain', 'ip_cidr']), value: z.string().min(1).max(253), ports: z.array(z.number().int().min(1).max(65535)).min(1).max(65535), protocol: z.enum(['tcp', 'udp', 'both']) }).strict().refine(canonicalNetworkRule);
const rules = z.array(rule).max(1000);
const hostServices = new WeakMap<BackendServices, HostServices>();

export function createHostServices(s: BackendServices, options: HostOptions = {}): HostServices {
  const existing = hostServices.get(s);
  if (existing) return existing;
  const inFlight = new Map<string, Promise<DriverJob>>();
  const workers = new Map<string, Promise<void>>();
  let disposed = false;
  const putJob = (j: DriverJob) => s.store.put('hostDriverJobs', j);
  const driver = (machineId: string): P.HostDriverConfig | null => s.config.operator.hostDrivers.find(d => d.machineId === machineId) ?? null;
  const validCommand = (cmd: P.HostDriverCommand): P.HostDriverCommand => {
    const value = parse(command, cmd);
    if ([...value.argv, ...value.probeArgv, value.cwd].some(v => v.includes('\0')) || !value.argv[0]?.startsWith('/') || !value.probeArgv[0]?.startsWith('/')) fail('capability_unavailable', 'Configure absolute reviewed driver executables and probe commands.');
    return value;
  };
  const machine = (p: Principal, machineId: string, manage = true) => s.auth.machine(p, machineId, manage);
  const online = (m: P.Machine) => {
    if (!s.lemon.connected || m.status !== 'online' || !m.nodeId) fail('machine_offline', 'The selected host must be online.');
    if (!['node.shell.open', 'node.shell.input', 'node.shell.close'].every(method => s.lemon.methods.includes(method))) fail('capability_unavailable', 'The destination requires node shell PTY support.');
  };
  const requiredCommand = (m: P.Machine, kind: 'networkApply' | 'egressApply' | 'setupRun'): P.HostDriverCommand => {
    const cmd = driver(m.id)?.[kind];
    if (!cmd) fail('capability_unavailable', `Configure the destination ${kind} host driver.`);
    return validCommand(cmd);
  };
  const runtimeRules = (m: P.Machine): P.NetworkRule[] => {
    const values = [...s.config.operator.requiredRuntimeDestinations, ...(driver(m.id)?.runtimeDestinations ?? [])];
    parse(rules, values);
    return [...new Map(values.map(r => [s.mutations.digest(r), r])).values()];
  };
  const reserve = (kind: JobKind, targetId: string, m: P.Machine, cmd: P.HostDriverCommand, input: Record<string, unknown>): DriverJob => {
    const configDigest = s.mutations.digest(driver(m.id));
    const inputDigest = s.mutations.digest(input);
    return putJob(s.resource('host_job', { kind, targetId, machineId: m.id, command: validCommand(cmd), configDigest, inputDigest, encryptedInput: s.encrypt(input), state: 'reserved' as const, receipt: null }));
  };
  const executePTY = async (j: DriverJob, probe: boolean): Promise<Receipt | null> => {
    const m = s.store.require<P.Machine>('machines', j.machineId);
    online(m);
    const input = s.decrypt<Record<string, unknown>>(j.encryptedInput);
    const json = JSON.stringify({ ...input, version: 1, operationId: j.id, machineId: j.machineId, configDigest: j.configDigest, inputDigest: j.inputDigest, probe });
    let shellId: string | null = null, output = '', bytes = 0, seq = 0, receipt: Receipt | null = null, exited = false;
    const early: { event: string; payload: unknown }[] = [];
    let settled = false;
    let settle!: (result: Receipt | null) => void;
    const done = new Promise<Receipt | null>(resolve => { settle = result => { if (!settled) { settled = true; resolve(result); } }; });
    const accept = (event: string, payload: unknown) => {
      if (!shellId) { if (early.length < 128) early.push({ event, payload }); return; }
      if (!payload || typeof payload !== 'object' || !('shellId' in payload) || payload.shellId !== shellId) return;
      if (event === 'node.shell.output') {
        const chunk = z.object({ shellId: z.string(), dataBase64: z.string(), seq: z.number().int().positive() }).safeParse(payload);
        if (!chunk.success || chunk.data.seq !== seq + 1) { settle(null); return; }
        seq = chunk.data.seq;
        const data = Buffer.from(chunk.data.dataBase64, 'base64');
        bytes += data.length;
        if (bytes > 1048576) { settle(null); return; }
        output += data.toString('utf8');
        let newline: number;
        while ((newline = output.indexOf('\n')) >= 0) {
          const line = output.slice(0, newline).trim(); output = output.slice(newline + 1);
          if (!line.startsWith('{')) continue;
          try {
            const parsed = receiptSchema.safeParse(JSON.parse(line));
            if (parsed.success && parsed.data.operationId === j.id && parsed.data.machineId === j.machineId && parsed.data.configDigest === j.configDigest && parsed.data.inputDigest === j.inputDigest) receipt = parsed.data;
          } catch { /* Non-protocol stdout is discarded, never exposed. */ }
        }
        data.fill(0);
      } else if (event === 'node.shell.exit') {
        exited = true;
        const exit = z.object({ shellId: z.string(), code: z.number().int().nullable() }).safeParse(payload);
        settle(exit.success && exit.data.code === 0 && receipt ? receipt : null);
      }
    };
    const unsubscribe = s.lemon.onEvent(accept);
    const timer = setTimeout(() => settle(null), probe ? Math.min(j.command.timeoutMs, 60000) : j.command.timeoutMs);
    try {
      const opened = parse(z.object({ shellId: z.string().min(1) }), await s.lemon.call('node.shell.open', { nodeId: m.nodeId, cwd: j.command.cwd, cols: 80, rows: 24 }, { mutation: true, resourceIds: [j.id], timeoutMs: Math.min(j.command.timeoutMs, 30000) }));
      shellId = opened.shellId;
      for (const event of early) accept(event.event, event.payload);
      const argv = probe ? j.command.probeArgv : j.command.argv;
      // Keep each canonical PTY input line below its kernel limit. JSON is
      // streamed through fixed printf builtins, never interpreted as shell code.
      const pieces: string[] = [];
      let piece = '';
      for (const character of json) {
        if (piece.length + character.length > 512) { pieces.push(piece); piece = ''; }
        piece += character;
      }
      if (piece) pieces.push(piece);
      const text = `PS1= PS2=; unset PROMPT_COMMAND; stty -echo\n{\n${pieces.map(value => `printf '%s' ${quote(value)}`).join('\n')}\nprintf '\\n'\n} | ${argv.map(quote).join(' ')}; exit\n`;
      const buffer = Buffer.from(text);
      try {
        for (let offset = 0; offset < buffer.length; offset += 16384) {
          if (settled) break;
          await s.lemon.call('node.shell.input', { shellId, dataBase64: buffer.subarray(offset, offset + 16384).toString('base64') }, { mutation: true, resourceIds: [j.id], timeoutMs: 30000 });
        }
      } finally { buffer.fill(0); }
      return await done;
    } catch { return null; }
    finally {
      clearTimeout(timer); unsubscribe(); output = ''; early.length = 0;
      if (shellId && !exited) await s.lemon.call('node.shell.close', { shellId }, { mutation: true, resourceIds: [j.id] }).catch(() => undefined);
    }
  };
  const runJob = (job: DriverJob): Promise<DriverJob> => {
    const current = s.store.require<DriverJob>('hostDriverJobs', job.id);
    if (['succeeded', 'skipped', 'failed'].includes(current.state)) return Promise.resolve(current);
    const running = inFlight.get(job.id); if (running) return running;
    const work = (async () => {
      const m = s.store.require<P.Machine>('machines', current.machineId);
      if (!s.lemon.connected || m.status !== 'online' || !m.nodeId) return current;
      online(m);
      const probe = current.state !== 'reserved';
      if (!probe) {
        if (current.configDigest !== s.mutations.digest(driver(m.id))) return putJob(s.update(current, { state: 'failed' }));
        putJob(s.update(current, { state: 'dispatched' }));
      }
      const answer = await executePTY(current, probe).catch(() => null);
      const input = s.decrypt<Record<string, unknown>>(current.encryptedInput);
      let verified = answer?.state === 'succeeded' && (current.kind === 'setup' || answer.exitCode === 0);
      if (verified && current.kind === 'host') {
        verified = answer?.safePoint === true && answer.retainedUserHome === true && answer.retainedSSH === true && (!['recreate_environment', 'delete_environment'].includes(String(input.action)) || (answer.environmentRoot === input.environmentRoot && answer.isolatedEnvironment === true));
        if (verified && input.preserveDisk === true) verified = answer?.retainedDisk === true && answer.retainedIdentity === true;
        if (verified && input.inactivePolicy) {
          const policy = parse(z.object({ afterDays: z.number().int().positive() }), input.inactivePolicy);
          verified = !!answer && ['idle', 'sleeping'].includes(answer.hostState ?? '') && answer.inactiveSinceMs !== undefined && s.now() - answer.inactiveSinceMs >= policy.afterDays * 86400000;
        }
      }
      if (verified && current.kind === 'egress') verified = answer?.enabled === input.enabled && (input.enabled !== true || (answer?.authenticated === true && answer.encrypted === true));
      if (verified && current.kind === 'network') verified = answer?.appliedRevision === parse(z.object({ revision: z.number().int() }).passthrough(), input.policy).revision;
      if (verified && current.kind === 'setup') verified = answer?.destinationSecretsOnly === true && answer.secretsWiped === true && answer.exitCode !== null;
      const skipped = current.kind === 'host' && answer?.state === 'skipped' && answer.exitCode === 0 && answer.skipReason !== undefined;
      const next = s.update(s.store.require<DriverJob>('hostDriverJobs', job.id), {
        state: verified ? 'succeeded' : skipped ? 'skipped' : answer?.state === 'failed' ? 'failed' : 'unknown',
        receipt: answer,
      });
      putJob(next); return next;
    })().finally(() => inFlight.delete(job.id));
    inFlight.set(job.id, work); return work;
  };
  const saveOperation = (o: P.HostOperation) => s.store.transaction(() => {
    s.store.put('hostOperations', o); s.events.emit('host_operation.upserted', o, { userIds: [o.ownerUserId] }); return o;
  });
  const saveRun = (r: P.SetupRun) => s.store.transaction(() => {
    const execution = s.store.get<SetupExecution>('setupExecutions', r.id);
    s.store.put('setupRuns', r); s.events.emit('setup_run.upserted', r, { userIds: execution ? [execution.principal.userId] : [] }); return r;
  });
  const saveEgress = (r: P.EgressRoute) => s.store.transaction(() => {
    s.store.put('egressRoutes', r); s.events.emit('egress.upserted', r, { userIds: [r.ownerUserId] }); return r;
  });
  const applicationId = (policyId: string, machineId: string) => `${policyId}:${machineId}`;
  const saveApplication = (record: ApplicationRecord) => s.store.transaction(() => {
    s.store.put('policyApplications', record); s.events.emit('policy_application.upserted', record.value, { userIds: [record.principal.userId] }); return record.value;
  });
  const networkFingerprint = (machineId: string) => s.mutations.digest({ driver: driver(machineId), requiredRuntimeDestinations: s.config.operator.requiredRuntimeDestinations, governanceRevision: s.store.metadata<P.Governance>('governance')?.revision ?? 1, groupPolicies: s.store.list<P.GroupPolicy>('groupPolicies'), networkPolicies: s.store.list<P.NetworkPolicy>('networkPolicies').map(p => ({ id: p.id, revision: p.revision })) });
  const settleNetwork = (record: ApplicationRecord, j: DriverJob) => {
    const current = s.store.get<ApplicationRecord>('policyApplications', record.id);
    if (!current) return record.value;
    if (current.jobId !== j.id) return current.value;
    record = current;
    const applied = j.state === 'succeeded' ? j.receipt?.appliedRevision ?? null : record.value.appliedRevision;
    const ok = applied === record.value.desiredRevision && j.state === 'succeeded' && record.configDigest === networkFingerprint(record.value.machineId);
    const m = s.store.require<P.Machine>('machines', record.value.machineId);
    return saveApplication({ ...record, jobId: j.state === 'succeeded' && !ok ? null : record.jobId, value: { ...record.value, appliedRevision: applied, state: ok ? 'applied' : m.status !== 'online' ? 'offline' : j.state === 'failed' ? 'failed' : 'pending', error: ok ? null : j.state === 'failed' ? 'Host firewall application failed.' : 'Awaiting verified firewall revision.', measuredAtMs: s.now() } });
  };
  const appliedPolicyAdmission = async (p: Principal, botId: string) => {
    const b = s.auth.bot(p, botId);
    const effective = await s.integrations.effectivePolicy(p, botId);
    const egress = s.store.list<P.EgressRoute>('egressRoutes', r => r.machineId === b.machineId && (r.enabled || r.state === 'connecting' || r.state === 'failed'));
    for (const route of egress) {
      if ((!effective.allowEgress && route.state !== 'disabled') || route.state === 'connecting' || route.state === 'failed') fail('policy_denied', 'Host egress requires current authorization and a verified route/stop acknowledgment.');
    }
    for (const policy of effective.networkPolicies) {
      const record = s.store.get<ApplicationRecord>('policyApplications', applicationId(policy.id, b.machineId));
      if (!record || record.value.state !== 'applied' || record.value.appliedRevision !== policy.revision || record.configDigest !== networkFingerprint(b.machineId)) fail('policy_denied', 'Required network policy is not verified at the current revision on this host.');
    }
  };
  const applyNetwork = async (p: Principal, policy: P.NetworkPolicy, ids: string[], removing = false) => {
    s.auth.requireRole(p, 'admin');
    const machines = ids.map(value => machine(p, value));
    if (policy.directoryGroupId) s.store.require<P.DirectoryGroup>('directoryGroups', policy.directoryGroupId);
    const values: P.PolicyApplication[] = [];
    for (const m of machines) {
      const config = driver(m.id), key = applicationId(policy.id, m.id);
      const existing = s.store.get<ApplicationRecord>('policyApplications', key);
      if (existing?.value.state === 'applied' && existing.value.appliedRevision === policy.revision && existing.configDigest === networkFingerprint(m.id)) { values.push(existing.value); continue; }
      if (existing?.jobId && existing.value.desiredRevision === policy.revision && ['pending', 'offline'].includes(existing.value.state)) {
        values.push(settleNetwork(existing, await runJob(s.store.require<DriverJob>('hostDriverJobs', existing.jobId)))); continue;
      }
      const record: ApplicationRecord = { id: key, policyId: policy.id, jobId: null, configDigest: networkFingerprint(m.id), principal: p, value: { machineId: m.id, desiredRevision: policy.revision, appliedRevision: existing?.value.appliedRevision ?? null, state: !config?.networkApply ? 'unsupported' : m.status !== 'online' ? 'offline' : 'pending', error: !config?.networkApply ? 'Configure destination network enforcement driver.' : m.status !== 'online' ? 'Host is offline.' : null, measuredAtMs: s.now() } };
      if (!config?.networkApply) { values.push(saveApplication(record)); continue; }
      const unsettled = s.store.list<DriverJob>('hostDriverJobs', j => j.kind === 'network' && j.machineId === m.id && ['dispatched', 'unknown'].includes(j.state));
      if (unsettled.length) fail('outcome_unknown', 'A previous firewall operation must be reconciled before applying another revision.', false, { resourceIds: unsettled.map(j => j.id) });
      const j = reserve('network', policy.id, m, config.networkApply, { kind: 'network', policy: { ...policy, requiredRuntimeDestinations: runtimeRules(m) }, ...(removing ? { removePolicyId: policy.id } : {}), enforceRuntimeAllowance: true, composition: 'intersection', lockNetworkForGroups: s.store.metadata<P.Governance>('governance')?.lockNetworkForGroups ?? true, policies: s.store.list<P.NetworkPolicy>('networkPolicies', v => !removing || v.id !== policy.id), groupPolicies: s.store.list<P.GroupPolicy>('groupPolicies') });
      record.jobId = j.id; saveApplication(record);
      values.push(m.status === 'online' ? settleNetwork(record, await runJob(j)) : record.value);
    }
    return { items: values, nextCursor: null };
  };
  const deleteNetwork = async (p: Principal, policy: P.NetworkPolicy): Promise<P.Deleted | null> => {
    const records = s.store.list<ApplicationRecord>('policyApplications', a => a.policyId === policy.id);
    const prior = s.store.get<{ id: string; principal: Principal; policy: P.NetworkPolicy }>('networkPolicyDeletes', policy.id);
    s.store.put('networkPolicyDeletes', prior ?? { id: policy.id, principal: p, policy });
    if (prior && records.some(a => a.value.state === 'failed' && a.value.desiredRevision === policy.revision + 1)) return null;
    for (const record of records) {
      if (record.jobId && record.value.desiredRevision !== policy.revision + 1) {
        const job = await runJob(s.store.require<DriverJob>('hostDriverJobs', record.jobId));
        settleNetwork(record, job);
        if (!['succeeded', 'failed'].includes(job.state)) return null;
      }
    }
    if (records.length) {
      const removal: P.NetworkPolicy = { ...policy, revision: policy.revision + 1, mode: 'allow_all', rules: [] };
      const page = await applyNetwork(p, removal, records.map(a => a.value.machineId), true);
      if (page.items.some(a => a.state !== 'applied')) return null;
    }
    return s.store.transaction(() => {
      for (const record of records) s.store.remove('policyApplications', record.id);
      s.store.remove('networkPolicies', policy.id); s.store.remove('networkPolicyDeletes', policy.id);
      const deleted: P.Deleted = { id: policy.id, deleted: true };
      s.events.emit('network_policy.deleted', deleted, { userIds: [p.userId] });
      s.audit(p, 'network.delete', policy.id, 'succeeded'); return deleted;
    });
  };
  const ownerPrincipal = (userId: string): Principal => {
    const member = s.auth.member(userId);
    if (!member.enabled) fail('forbidden', 'Route owner is no longer enabled.');
    return { kind: 'user', id: userId, userId, workspaceId: s.store.metadata<string>('workspaceId') ?? '', role: member.role, sessionId: null, botId: null, deviceId: null };
  };
  const authorizeEgress = async (p: Principal, source: string, through: string, enabling: boolean) => {
    const m = machine(p, source), target = machine(p, through);
    if (source === through) fail('invalid_request', 'Source and through hosts must differ.');
    if (p.role !== 'admin' && p.role !== 'owner' && (m.ownerUserId !== p.userId || target.ownerUserId !== p.userId)) fail('forbidden', 'Egress requires ownership or explicit administrator host authority on both hosts.');
    if (enabling) {
      const policy = await s.integrations.effectivePolicy(p);
      if (!policy.productAccess || !policy.allowEgress) fail('policy_denied', 'Egress is centrally disabled for this principal.');
    }
    requiredCommand(m, 'egressApply'); if (enabling) { online(m); online(target); }
    return m;
  };
  const settleEgress = (route: P.EgressRoute, j: DriverJob, enabled: boolean) => {
    const current = s.store.get<P.EgressRoute>('egressRoutes', route.id);
    if (!current) return route;
    if (s.store.metadata<string>(`egressJob:${route.id}`) !== j.id) return current;
    const verified = j.state === 'succeeded' && j.receipt?.enabled === enabled && (!enabled || (j.receipt.authenticated === true && j.receipt.encrypted === true));
    const state = verified ? enabled ? 'active' : 'disabled' : j.state === 'failed' ? 'failed' : 'connecting';
    const error = verified ? null : j.state === 'failed' ? 'Encrypted host route application failed.' : 'Awaiting verified host route acknowledgment.';
    if (current.state === state && current.enabled === enabled && current.error === error) return current;
    return saveEgress(s.update(current, { state, enabled, error }));
  };
  const changeEgress = async (p: Principal, route: P.EgressRoute, enabled: boolean, central = false) => {
    const m = central ? s.store.require<P.Machine>('machines', route.machineId) : await authorizeEgress(p, route.machineId, route.throughMachineId, enabled);
    const currentJobId = s.store.metadata<string>(`egressJob:${route.id}`);
    const pending = currentJobId ? s.store.require<DriverJob>('hostDriverJobs', currentJobId) : null;
    if (pending && !['succeeded', 'failed'].includes(pending.state)) {
      const oldInput = s.decrypt<{ enabled: boolean }>(pending.encryptedInput);
      // A central deny is a NEW monotonic stop intent, never a replay of an
      // uncertain enable. Drivers must reject older routeRevision intents.
      if (!(central && !enabled && oldInput.enabled)) {
        const j = await runJob(pending);
        const current = settleEgress(route, j, oldInput.enabled);
        if (!['succeeded', 'failed'].includes(j.state) || oldInput.enabled === enabled) return current;
        route = current;
      }
    }
    const cmd = requiredCommand(m, 'egressApply');
    s.mutations.checkRevision(s.store.require<P.EgressRoute>('egressRoutes', route.id), route.revision);
    const through = s.store.get<P.Machine>('machines', route.throughMachineId);
    if (enabled && !through) fail('not_found', 'Through host is no longer attached.');
    const routeRevision = route.revision + 1;
    const j = reserve('egress', route.id, m, { ...cmd, timeoutMs: central ? Math.min(cmd.timeoutMs, 60000) : cmd.timeoutMs }, { kind: 'egress', routeId: route.id, routeRevision, throughMachineId: route.throughMachineId, throughNodeId: through?.nodeId ?? null, enabled, requireAuthenticatedEncryption: true, applyToNewConnections: true });
    s.store.transaction(() => {
      s.store.setMetadata(`egressJob:${route.id}`, j.id);
      saveEgress(s.update(route, { enabled, rememberedPreference: central ? route.rememberedPreference || route.enabled : enabled, state: 'connecting', error: null }));
    });
    return settleEgress(s.store.require<P.EgressRoute>('egressRoutes', route.id), await runJob(j), enabled);
  };
  const governanceChanged = async (_previous: P.Governance, next: P.Governance) => {
    for (const record of s.store.list<ApplicationRecord>('policyApplications')) {
      if (record.configDigest !== networkFingerprint(record.value.machineId)) {
        const job = record.jobId ? s.store.require<DriverJob>('hostDriverJobs', record.jobId) : null;
        saveApplication({ ...record, jobId: job && ['dispatched', 'unknown'].includes(job.state) ? job.id : null, value: { ...record.value, state: 'pending', error: 'Host/governance configuration changed; verified enforcement required.', measuredAtMs: s.now() } });
      }
    }
    await Promise.all(s.store.list<P.EgressRoute>('egressRoutes').map(async original => {
      const route = s.store.require<P.EgressRoute>('egressRoutes', original.id);
      try {
        const p = ownerPrincipal(route.ownerUserId);
        const policy = await s.integrations.effectivePolicy(p);
        const allowed = next.allowEgress && policy.productAccess && policy.allowEgress;
        if (!allowed && (route.enabled || route.state === 'active' || route.state === 'connecting')) await changeEgress(p, route, false, true);
        else if (allowed && route.rememberedPreference && !route.enabled && !s.store.get('egressDeletes', route.id)) { await authorizeEgress(p, route.machineId, route.throughMachineId, true); await changeEgress(p, route, true, true); }
      } catch {
        if (route.enabled || route.state === 'active') {
          try { await changeEgress({ kind: 'integration', id: 'governance', userId: route.ownerUserId, workspaceId: '', role: 'admin', sessionId: null, botId: null, deviceId: null }, route, false, true); }
          catch { saveEgress(s.update(route, { enabled: false, rememberedPreference: route.rememberedPreference || route.enabled, state: 'failed', error: 'Central stop awaits destination acknowledgment; new admission is denied.' })); }
        }
      }
    }));
  };
  const reviewSetups = (): ReviewedSetup[] => parse(z.array(reviewed), options.reviewedSetups ?? integrationConfiguration(s).reviewedSetupManifests);
  const authorizeManifest = (p: Principal, manifest: Pick<P.SetupManifest, 'name' | 'directoryGroupId' | 'machineIds' | 'entries'>) => {
    s.auth.requireRole(p, 'admin'); manifest.machineIds.forEach(value => machine(p, value));
    if (manifest.directoryGroupId) s.store.require<P.DirectoryGroup>('directoryGroups', manifest.directoryGroupId);
    const approved = reviewSetups().find(r => r.name === manifest.name && r.directoryGroupId === manifest.directoryGroupId && s.mutations.digest([...r.machineIds].sort()) === s.mutations.digest([...manifest.machineIds].sort()) && s.mutations.digest(r.entries) === s.mutations.digest(manifest.entries));
    if (!approved) fail('policy_denied', 'Setup scripts, destinations and secret names must exactly match a reviewed private operator manifest.');
    for (const other of reviewSetups()) {
      if (other.directoryGroupId === approved.directoryGroupId) continue;
      if (other.machineIds.some(value => approved.machineIds.includes(value)) && other.entries.some(e => e.secretNames.some(name => approved.entries.some(a => a.secretNames.includes(name))))) fail('policy_denied', 'Destination secret names cannot be shared across setup ownership scopes.');
    }
  };
  const setupStep = async (execution: SetupExecution): Promise<void> => {
    let run = s.store.require<P.SetupRun>('setupRuns', execution.id);
    const m = s.store.require<P.Machine>('machines', run.machineId);
    authorizeManifest(execution.principal, execution.manifest);
    if (!execution.jobId && m.revision !== execution.machineRevision) { saveRun(s.update(run, { state: 'failed' })); return; }
    while (execution.index < execution.manifest.entries.length) {
      const e = execution.manifest.entries[execution.index]!;
      if (execution.phase === 'check' && !e.checkScript) execution.phase = 'setup';
      if (!execution.jobId) {
        const cmd = requiredCommand(m, 'setupRun'); online(m);
        const job = reserve('setup', run.id, m, { ...cmd, timeoutMs: Math.min(cmd.timeoutMs, e.timeoutMs) }, { kind: 'setup', manifestId: execution.manifest.id, manifestRevision: execution.manifest.revision, directoryGroupId: execution.manifest.directoryGroupId, machineRevision: execution.machineRevision, entryId: e.id, phase: execution.phase, script: execution.phase === 'setup' ? e.setupScript : e.checkScript, secretNames: e.secretNames, secretScope: { workspaceId: execution.principal.workspaceId, directoryGroupId: execution.manifest.directoryGroupId }, destinationSecretsOnly: true, wipeChildEnvironment: true, timeoutMs: e.timeoutMs });
        execution.jobId = job.id; s.store.put('setupExecutions', execution);
      }
      saveRun(s.update(run, { state: 'running' }));
      const job = await runJob(s.store.require<DriverJob>('hostDriverJobs', execution.jobId));
      if (!['succeeded', 'failed'].includes(job.state)) { saveRun(s.update(s.store.require<P.SetupRun>('setupRuns', run.id), { state: job.state === 'reserved' ? 'queued' : 'outcome_unknown' })); return; }
      const safe = job.receipt?.destinationSecretsOnly === true && job.receipt.secretsWiped === true;
      const exitCode = job.receipt?.exitCode ?? null;
      const passed = job.state === 'succeeded' && exitCode === 0 && safe;
      if (execution.phase === 'check' && !passed && safe && exitCode !== null) { execution.phase = 'setup'; execution.jobId = null; s.store.put('setupExecutions', execution); continue; }
      if (execution.phase === 'setup' && passed && e.checkScript) { execution.phase = 'recheck'; execution.jobId = null; s.store.put('setupExecutions', execution); continue; }
      const state = passed ? execution.phase === 'check' ? 'skipped' : 'succeeded' : 'failed';
      run = s.store.require<P.SetupRun>('setupRuns', run.id);
      run = saveRun(s.update(run, { entryResults: run.entryResults.map(r => r.entryId === e.id ? { entryId: e.id, state, exitCode, summary: passed ? state === 'skipped' ? 'Existing setup verified; skipped.' : 'Setup verified.' : 'Setup/check failed; output withheld.' } : r), state: passed ? 'running' : 'failed' }));
      execution.index++; execution.phase = 'check'; execution.jobId = null; s.store.put('setupExecutions', execution);
      if (!passed) return;
    }
    saveRun(s.update(run, { state: run.entryResults.every(e => e.state === 'skipped') ? 'skipped' : 'succeeded' }));
  };
  const work = (key: string, fn: () => Promise<void>) => {
    if (workers.has(key)) return workers.get(key)!;
    const promise = fn().finally(() => workers.delete(key)); workers.set(key, promise); return promise;
  };
  const management = async (p: Principal, machineId: string): Promise<P.HostManagement> => {
    const m = machine(p, machineId, false), d = driver(m.id);
    const cmd = d ? Object.values(d.actions).find(value => value !== undefined) ?? d.networkApply ?? d.egressApply ?? d.setupRun : null;
    if (cmd && m.status === 'online' && s.lemon.connected) {
      const inspection = reserve('inspect', m.id, m, cmd, { kind: 'inspect', environmentRoot: d?.environmentRoot });
      putJob(s.update(inspection, { state: 'unknown' }));
      const measured = await runJob(s.store.require<DriverJob>('hostDriverJobs', inspection.id));
      if (measured.state !== 'succeeded') fail('capability_unavailable', 'The configured host management probe did not return a verified inspection.');
      if (measured.state === 'succeeded' && measured.receipt) {
        s.store.setMetadata(`hostInspection:${m.id}`, { lastBackupAtMs: measured.receipt.lastBackupAtMs ?? null });
        s.store.setMetadata(`hostVerified:${m.id}`, { configDigest: measured.configDigest, measuredAtMs: s.now(), environmentRoot: measured.receipt.environmentRoot ?? null, isolatedEnvironment: measured.receipt.isolatedEnvironment === true });
      }
    }
    const cached = s.store.metadata<{ lastBackupAtMs: number | null }>(`hostInspection:${m.id}`);
    return { machineId: m.id, supportedActions: d ? Object.keys(d.actions) as P.HostAction[] : [], provider: d?.provider ?? 'custom', supportsNetworkPolicy: !!d?.networkApply, supportsEgress: !!d?.egressApply, supportsSetup: !!d?.setupRun, lastBackupAtMs: cached?.lastBackupAtMs ?? null, environmentRoot: d?.environmentRoot ?? null };
  };
  const isolatedRoot = (root: string | null) => root !== null && root.startsWith('/') && posix.normalize(root) === root && root !== '/' && !/^\/(home|Users|root|etc|var|usr|bin|sbin|tmp)(\/[^/]+)?\/?$/.test(root) && !root.split('/').some(part => part === '.ssh' || part === '..');
  const snapshot = (p: Principal, ids: string[], act: P.HostAction) => {
    const machines = [...ids].sort().map(value => machine(p, value));
    if (!machines.some(m => driver(m.id)?.actions[act])) fail('capability_unavailable', 'No selected host has a configured driver for this action.');
    return machines.map(m => {
      const d = driver(m.id);
      if (d?.actions[act]) validCommand(d.actions[act]!);
      if ((act === 'recreate_environment' || act === 'delete_environment') && d?.actions[act] && !isolatedRoot(d.environmentRoot)) fail('policy_denied', 'Environment actions require an isolated Lemon-owned root, never a user home or SSH root.');
      const verified = s.store.metadata<{ configDigest: string; environmentRoot: string | null; isolatedEnvironment: boolean }>(`hostVerified:${m.id}`);
      if (d?.actions[act] && ['recreate_environment', 'delete_environment'].includes(act) && (!verified || !verified.isolatedEnvironment || verified.configDigest !== s.mutations.digest(d) || verified.environmentRoot !== d.environmentRoot)) fail('capability_unavailable', 'Probe and verify the exact isolated environment root before previewing deletion or recreation.');
      return { id: m.id, revision: m.revision, nodeId: m.nodeId, name: m.name, configDigest: s.mutations.digest(d), environmentRoot: d?.environmentRoot ?? null, backup: s.store.metadata<{ lastBackupAtMs: number | null }>(`hostInspection:${m.id}`) };
    });
  };
  const operationTarget = (p: Principal) => ({ id: `host-operations:${p.workspaceId}`, revision: s.store.metadata<number>('hostOperationRevision') ?? 1 });
  const operationWork = async (operationId: string) => {
    let o = s.store.require<P.HostOperation>('hostOperations', operationId);
    const binding = s.store.require<OperationBinding>('hostOperationBindings', o.id);
    for (const result of o.results) {
      if (!['queued', 'running', 'outcome_unknown'].includes(result.state)) continue;
      const m = s.store.require<P.Machine>('machines', result.machineId), d = driver(m.id), cmd = d?.actions[o.action];
      let existing = s.store.list<DriverJob>('hostDriverJobs', j => j.kind === 'host' && j.targetId === o.id && j.machineId === m.id)[0];
      let state: P.HostOperation['results'][number]['state'], reason: string | null = null;
      if (!existing && !cmd) { state = 'skipped'; reason = 'Action not configured for this host.'; }
      else {
        if (!existing) {
          machine(binding.principal, m.id); online(m);
          // Exact snapshot is rechecked before EACH first dispatch, not after response loss.
          const approved = parse(z.array(z.object({ id: z.string(), revision: z.number(), configDigest: z.string() }).passthrough()), binding.snapshot).find(v => v.id === m.id);
          if (!approved || approved.revision !== m.revision || approved.configDigest !== s.mutations.digest(d)) { state = 'failed'; reason = 'Host/configuration changed before dispatch.'; }
          else {
            existing = reserve('host', o.id, m, cmd!, { kind: 'host', action: o.action, environmentRoot: d?.environmentRoot, requireSafePoint: true, retainUserHome: true, retainSSH: true, preserveDisk: !['recreate_environment', 'delete_environment'].includes(o.action), snapshot: approved, ...(binding.inactivePolicy ? { inactivePolicy: binding.inactivePolicy } : {}) });
            state = 'running';
          }
        } else state = 'running';
        if (existing) {
          o = saveOperation(s.update(o, { state: 'running', results: o.results.map(r => r.machineId === m.id ? { ...r, state: 'running' } : r) }));
          if (existing.state === 'reserved' && binding.inactivePolicy) {
            const bots = s.store.list<P.Bot>('bots', b => b.machineId === m.id);
            if (bots.some(b => b.activeRunIds.length)) { putJob(s.update(existing, { state: 'failed' })); existing = s.store.require<DriverJob>('hostDriverJobs', existing.id); }
          }
          const job = await runJob(existing);
          const verified = job.state === 'succeeded' && job.receipt?.safePoint === true && job.receipt.retainedUserHome === true && job.receipt.retainedSSH === true && (!['recreate_environment', 'delete_environment'].includes(o.action) || job.receipt.environmentRoot === d?.environmentRoot);
          state = verified ? 'succeeded' : job.state === 'skipped' ? 'skipped' : job.state === 'failed' ? 'failed' : 'outcome_unknown';
          reason = verified ? null : job.state === 'skipped' ? `Driver verified no action needed: ${job.receipt?.skipReason}.` : job.state === 'failed' ? 'Driver refused or failed action; no verified completion.' : 'Awaiting exact operation receipt; do not start another operation.';
        }
      }
      o = saveOperation(s.update(o, { results: o.results.map(r => r.machineId === m.id ? { machineId: m.id, state, reason } : r) }));
      if (state !== 'skipped') s.audit(binding.principal, `host.${o.action}`, m.id, state === 'succeeded' ? 'succeeded' : state === 'failed' ? 'failed' : 'outcome_unknown', { operationId: o.id });
    }
    saveOperation(s.update(o, { state: o.results.some(r => r.state === 'outcome_unknown') ? 'outcome_unknown' : o.results.some(r => r.state === 'failed') ? 'failed' : 'completed' }));
  };
  const launchOperation = (o: P.HostOperation) => work(`operation:${o.id}`, () => operationWork(o.id).catch(() => {
    const current = s.store.require<P.HostOperation>('hostOperations', o.id);
    saveOperation(s.update(current, { state: 'outcome_unknown', results: current.results.map(r => ['running', 'queued'].includes(r.state) ? { ...r, state: 'outcome_unknown', reason: 'Host authority or availability changed; reconciliation required.' } : r) }));
  }));
  const processInactiveHosts = async () => {
    const governance = s.store.metadata<P.Governance>('governance');
    if (!governance?.inactiveHostPolicy.enabled || s.store.list<P.HostOperation>('hostOperations', activeOperation).length) return;
    for (const m of s.store.list<P.Machine>('machines', v => v.status === 'online')) {
      const d = driver(m.id), cmd = d?.actions[governance.inactiveHostPolicy.action];
      if (!cmd || s.store.metadata(`inactiveHostProcessed:${m.id}:${m.revision}`)) continue;
      const bots = s.store.list<P.Bot>('bots', b => b.machineId === m.id);
      if (bots.some(b => b.activeRunIds.length) || s.store.list<P.Run>('runs', r => bots.some(b => b.id === r.botId) && ['reserved', 'queued', 'running', 'awaiting_input', 'outcome_unknown'].includes(r.status)).length) continue;
      const inspection = reserve('inspect', m.id, m, cmd, { kind: 'inspect', action: governance.inactiveHostPolicy.action });
      // Inspect ONLY via probe; never dispatch an action to measure idle state.
      putJob(s.update(inspection, { state: 'unknown' }));
      const measured = await runJob(s.store.require<DriverJob>('hostDriverJobs', inspection.id));
      const answer = measured.receipt;
      if (!answer || measured.state !== 'succeeded' || !['idle', 'sleeping'].includes(answer.hostState ?? '') || answer.inactiveSinceMs === undefined || s.now() - answer.inactiveSinceMs < governance.inactiveHostPolicy.afterDays * 86400000) continue;
      const p = ownerPrincipal(m.ownerUserId); machine(p, m.id);
      const snap = snapshot(p, [m.id], governance.inactiveHostPolicy.action);
      const o = s.store.transaction(() => {
        if (s.store.list<P.HostOperation>('hostOperations', activeOperation).length) return null;
        const value = saveOperation(s.resource('host_operation', { action: governance.inactiveHostPolicy.action, ownerUserId: p.userId, state: 'queued' as const, results: [{ machineId: m.id, state: 'queued' as const, reason: null }] }));
        s.store.put('hostOperationBindings', { id: value.id, principal: p, snapshot: snap, inactivePolicy: { afterDays: governance.inactiveHostPolicy.afterDays } } satisfies OperationBinding);
        s.store.setMetadata(`inactiveHostProcessed:${m.id}:${m.revision}`, value.id); return value;
      });
      if (o) await launchOperation(o);
      return;
    }
  };
  const reconcile = async () => {
    if (disposed || !s.lemon.connected) return;
    const governance = s.store.metadata<P.Governance>('governance');
    if (governance) await governanceChanged(governance, governance);
    for (const deletion of s.store.list<{ id: string; principal: Principal; policy: P.NetworkPolicy }>('networkPolicyDeletes')) await deleteNetwork(deletion.principal, deletion.policy);
    for (const record of s.store.list<ApplicationRecord>('policyApplications', a => ['pending', 'offline'].includes(a.value.state))) {
      if (s.store.get('networkPolicyDeletes', record.policyId)) continue;
      if (record.jobId) {
        const job = s.store.require<DriverJob>('hostDriverJobs', record.jobId);
        settleNetwork(record, await runJob(job));
        const current = s.store.require<ApplicationRecord>('policyApplications', record.id);
        if (!current.jobId) {
          const policy = s.store.get<P.NetworkPolicy>('networkPolicies', record.policyId);
          if (policy) await applyNetwork(record.principal, policy, [record.value.machineId]);
        }
      } else {
        const policy = s.store.get<P.NetworkPolicy>('networkPolicies', record.policyId);
        if (policy) await applyNetwork(record.principal, policy, [record.value.machineId]);
      }
    }
    for (const route of s.store.list<P.EgressRoute>('egressRoutes', r => r.state === 'connecting')) {
      const jobId = s.store.metadata<string>(`egressJob:${route.id}`);
      if (jobId) {
        const job = s.store.require<DriverJob>('hostDriverJobs', jobId);
        settleEgress(route, await runJob(job), s.decrypt<{ enabled: boolean }>(job.encryptedInput).enabled);
      }
    }
    for (const deletion of s.store.list<{ id: string }>('egressDeletes')) {
      const route = s.store.get<P.EgressRoute>('egressRoutes', deletion.id);
      if (route?.state === 'disabled') { s.store.remove('egressRoutes', route.id); s.store.remove('egressDeletes', route.id); }
    }
    for (const o of s.store.list<P.HostOperation>('hostOperations', activeOperation)) await launchOperation(o);
    for (const r of s.store.list<P.SetupRun>('setupRuns', r => ['queued', 'running', 'outcome_unknown'].includes(r.state))) {
      const execution = s.store.require<SetupExecution>('setupExecutions', r.id);
      await work(`setup:${r.id}`, () => setupStep(execution).catch(() => { saveRun(s.update(s.store.require<P.SetupRun>('setupRuns', r.id), { state: execution.jobId ? 'outcome_unknown' : 'failed' })); }));
    }
    await processInactiveHosts();
  };
  // Long setup/recovery work must not hold the next firewall/central-stop sweep.
  // Per-operation workers and driver IDs deduplicate overlapping maintenance.
  const connected = s.lemon.onConnected(() => { void reconcile().catch(() => { s.audit(null, 'host.reconcile', 'hosts', 'failed'); }); });
  const timer = setInterval(() => { void reconcile().catch(() => { s.audit(null, 'host.reconcile', 'hosts', 'failed'); }); }, 45000); timer.unref?.();
  const service: HostServices = {
    admission: appliedPolicyAdmission, appliedPolicyAdmission, governanceChanged, reconcile, processInactiveHosts,
    dispose() { disposed = true; clearInterval(timer); connected(); if (hostServices.get(s) === service) hostServices.delete(s); },
    driver, management, machine, online, reserve, runJob, applyNetwork, deleteNetwork, authorizeEgress, changeEgress, authorizeManifest, reviewSetups,
    snapshot, operationTarget, saveOperation, launchOperation, saveRun, setupStep, work, saveEgress,
  };
  hostServices.set(s, service);
  return service;
}

export function createHostRoutes(s: BackendServices, host: HostServices = createHostServices(s)): Route[] {
  const networkCreate = mutation.extend({ scope: z.enum(['workspace', 'directory_group']), directoryGroupId: id.optional(), mode: z.enum(['allow_all', 'defaults_plus_allowlist', 'allowlist_only']), rules }).strict();
  const networkUpdate = update.extend({ mode: z.enum(['allow_all', 'defaults_plus_allowlist', 'allowlist_only']).optional(), rules: rules.optional() }).strict();
  const manifestCreate = mutation.extend({ name: z.string().min(1).max(120), directoryGroupId: id.optional(), machineIds, entries, enabled: z.boolean() }).strict();
  const manifestUpdate = update.extend({ entries: entries.optional(), enabled: z.boolean().optional(), machineIds: machineIds.optional() }).strict();
  const bulk = mutation.extend({ machineIds, action }).strict();
  const confirm = bulk.extend({ revision: z.number().int().positive(), confirmationToken: z.string().min(1), confirmName: z.string().min(1) }).strict();
  const ensureAdmin = (c: RequestContext) => { const p = principal(c); s.auth.requireRole(p, 'admin'); return p; };
  const ensureRoute = (c: RequestContext): P.EgressRoute => {
    const p = principal(c), r = s.store.require<P.EgressRoute>('egressRoutes', c.params.id!);
    if (r.ownerUserId !== p.userId && p.role !== 'owner' && p.role !== 'admin') fail('not_found', 'Route not found.');
    host.machine(p, r.machineId); host.machine(p, r.throughMachineId); return r;
  };
  const manifest = (c: RequestContext) => { const value = s.store.require<P.SetupManifest>('setupManifests', c.params.id!); host.authorizeManifest(ensureAdmin(c), value); return value; };
  const changedPolicy = (value: P.NetworkPolicy) => s.store.transaction(() => {
    s.store.put('networkPolicies', value); s.events.emit('network_policy.upserted', value, { admin: true });
    for (const a of s.store.list<ApplicationRecord>('policyApplications', a => a.policyId === value.id)) s.store.put('policyApplications', { ...a, value: { ...a.value, desiredRevision: value.revision, state: 'pending', error: 'Policy changed; verified application required.' } });
    return value;
  });
  const routes: Route[] = [
    { method: 'GET', path: '/v1/network-policies', auth: 'admin', handler: c => s.page(c, s.store.list<P.NetworkPolicy>('networkPolicies')) },
    { method: 'POST', path: '/v1/network-policies', auth: 'admin', status: 201, handler: c => {
      const body = parse(networkCreate, c.body); ensureAdmin(c);
      if ((body.scope === 'directory_group') !== !!body.directoryGroupId) fail('invalid_request', 'Directory scope requires exactly one directory group.');
      if (body.directoryGroupId) s.store.require<P.DirectoryGroup>('directoryGroups', body.directoryGroupId);
      if (s.store.list<P.NetworkPolicy>('networkPolicies', p => p.scope === body.scope && p.directoryGroupId === (body.directoryGroupId ?? null)).length) fail('conflict', 'This scope already has a network policy.');
      return changedPolicy(s.resource('network_policy', { scope: body.scope, directoryGroupId: body.directoryGroupId ?? null, mode: body.mode, rules: body.rules, requiredRuntimeDestinations: s.config.operator.requiredRuntimeDestinations }));
    } },
    { method: 'PATCH', path: '/v1/network-policies/:id', auth: 'admin', handler: c => {
      ensureAdmin(c); const body = parse(networkUpdate, c.body), value = s.store.require<P.NetworkPolicy>('networkPolicies', c.params.id!); s.mutations.checkRevision(value, body.revision);
      if (s.store.get('networkPolicyDeletes', value.id)) fail('conflict', 'This policy has a pending acknowledged removal.');
      return changedPolicy(s.update(value, { ...(body.mode !== undefined ? { mode: body.mode } : {}), ...(body.rules !== undefined ? { rules: body.rules } : {}), requiredRuntimeDestinations: s.config.operator.requiredRuntimeDestinations }));
    } },
    { method: 'DELETE', path: '/v1/network-policies/:id', auth: 'admin', handler: async c => {
      const p = ensureAdmin(c), body = parse(update, c.body), value = s.store.require<P.NetworkPolicy>('networkPolicies', c.params.id!); s.mutations.checkRevision(value, body.revision);
      if (s.store.list<P.GroupPolicy>('groupPolicies', g => g.networkPolicyId === value.id).length) fail('conflict', 'Remove group policy references before deleting this policy.');
      c.nonceResourceIds.push(value.id);
      const deleted = await host.deleteNetwork(p, value);
      if (!deleted) fail('outcome_unknown', 'Policy removal awaits host acknowledgment.', false, { resourceIds: [value.id] });
      return deleted;
    } },
    { method: 'GET', path: '/v1/network-policies/:id/applications', auth: 'admin', handler: c => {
      const p = ensureAdmin(c); s.store.require<P.NetworkPolicy>('networkPolicies', c.params.id!);
      const records = s.store.list<ApplicationRecord>('policyApplications', a => a.policyId === c.params.id); records.forEach(a => host.machine(p, a.value.machineId));
      return s.page(c, records.map(a => a.value), { key: value => value.machineId });
    } },
    { method: 'POST', path: '/v1/network-policies/:id/apply', auth: 'admin', handler: c => { const body = parse(mutation.extend({ machineIds }).strict(), c.body); return host.applyNetwork(ensureAdmin(c), s.store.require<P.NetworkPolicy>('networkPolicies', c.params.id!), body.machineIds); } },
    { method: 'GET', path: '/v1/egress-routes', auth: 'member', handler: c => { const p = principal(c); return s.page(c, s.store.list<P.EgressRoute>('egressRoutes', r => (r.ownerUserId === p.userId || p.role !== 'member') && s.auth.canRead(p, 'machines', s.store.get('machines', r.machineId)) && s.auth.canRead(p, 'machines', s.store.get('machines', r.throughMachineId)))); } },
    { method: 'POST', path: '/v1/egress-routes', auth: 'member', status: 201, handler: async c => {
      const p = principal(c), body = parse(mutation.extend({ machineId: id, throughMachineId: id, enabled: z.boolean() }).strict(), c.body);
      await host.authorizeEgress(p, body.machineId, body.throughMachineId, body.enabled);
      if (s.store.list<P.EgressRoute>('egressRoutes', r => r.machineId === body.machineId).length) fail('conflict', 'The source host already has an egress route.');
      const r = host.saveEgress(s.resource('egress', { machineId: body.machineId, throughMachineId: body.throughMachineId, ownerUserId: p.userId, state: 'disabled' as const, enabled: false, rememberedPreference: body.enabled, error: null })); c.nonceResourceIds.push(r.id);
      return host.changeEgress(p, r, body.enabled);
    } },
    { method: 'PATCH', path: '/v1/egress-routes/:id', auth: 'member', handler: c => { const body = parse(update.extend({ enabled: z.boolean() }).strict(), c.body), r = ensureRoute(c); s.mutations.checkRevision(r, body.revision); return host.changeEgress(principal(c), r, body.enabled); } },
    { method: 'DELETE', path: '/v1/egress-routes/:id', auth: 'member', handler: async c => {
      const body = parse(update, c.body), r = ensureRoute(c); s.mutations.checkRevision(r, body.revision);
      c.nonceResourceIds.push(r.id); s.store.put('egressDeletes', { id: r.id });
      const stopped = await host.changeEgress(principal(c), r, false);
      if (stopped.state !== 'disabled') fail('outcome_unknown', 'Route removal awaits verified stop.', false, { resourceIds: [r.id] });
      s.store.remove('egressRoutes', r.id); s.store.remove('egressDeletes', r.id); return { id: r.id, deleted: true };
    } },
    { method: 'GET', path: '/v1/setup-manifests', auth: 'admin', handler: c => { const p = ensureAdmin(c); return s.page(c, s.store.list<P.SetupManifest>('setupManifests', m => m.machineIds.every(value => s.auth.canRead(p, 'machines', s.store.get('machines', value))))); } },
    { method: 'POST', path: '/v1/setup-manifests', auth: 'admin', status: 201, handler: c => {
      const body = parse(manifestCreate, c.body), p = ensureAdmin(c), fields = { name: body.name, directoryGroupId: body.directoryGroupId ?? null, machineIds: body.machineIds, entries: body.entries, enabled: body.enabled }; host.authorizeManifest(p, fields);
      const value = s.resource('setup_manifest', fields); return s.store.transaction(() => { s.store.put('setupManifests', value); s.events.emit('setup_manifest.upserted', value, { userIds: [p.userId] }); return value; });
    } },
    { method: 'PATCH', path: '/v1/setup-manifests/:id', auth: 'admin', handler: c => {
      const body = parse(manifestUpdate, c.body), value = manifest(c); s.mutations.checkRevision(value, body.revision);
      const next = s.update(value, { ...(body.entries !== undefined ? { entries: body.entries } : {}), ...(body.machineIds !== undefined ? { machineIds: body.machineIds } : {}), ...(body.enabled !== undefined ? { enabled: body.enabled } : {}) }); host.authorizeManifest(principal(c), next);
      return s.store.transaction(() => { s.store.put('setupManifests', next); s.events.emit('setup_manifest.upserted', next, { userIds: [principal(c).userId] }); return next; });
    } },
    { method: 'DELETE', path: '/v1/setup-manifests/:id', auth: 'admin', handler: c => {
      const body = parse(update, c.body), value = manifest(c); s.mutations.checkRevision(value, body.revision);
      if (s.store.list<P.SetupRun>('setupRuns', r => r.manifestId === value.id && ['queued', 'running', 'outcome_unknown'].includes(r.state)).length) fail('conflict', 'Setup execution is unresolved.');
      s.store.remove('setupManifests', value.id); return { id: value.id, deleted: true };
    } },
    { method: 'POST', path: '/v1/setup-manifests/:id/run', auth: 'admin', status: 202, handler: c => {
      const body = parse(mutation.extend({ machineIds }).strict(), c.body), value = manifest(c), p = principal(c);
      if (!value.enabled) fail('policy_denied', 'This setup manifest is disabled.');
      const targets = body.machineIds.map(valueId => { if (!value.machineIds.includes(valueId)) fail('forbidden', 'Host is outside this setup manifest.'); const m = host.machine(p, valueId); host.online(m); if (!host.driver(m.id)?.setupRun) fail('capability_unavailable', 'Configure the reviewed destination setup driver.'); return m; });
      const runs = s.store.transaction(() => targets.map(m => {
        if (s.store.list<P.SetupRun>('setupRuns', r => r.machineId === m.id && ['queued', 'running', 'outcome_unknown'].includes(r.state)).length) fail('conflict', 'A setup is already active on this host.');
        const r = s.resource('setup_run', { manifestId: value.id, machineId: m.id, state: 'queued' as const, entryResults: value.entries.map(e => ({ entryId: e.id, state: 'pending' as const, exitCode: null, summary: 'Awaiting sequential setup.' })) });
        s.store.put('setupExecutions', { id: r.id, principal: p, manifest: value, machineRevision: m.revision, index: 0, phase: 'check', jobId: null } satisfies SetupExecution); return host.saveRun(r);
      }));
      c.nonceResourceIds.push(...runs.map(r => r.id));
      for (const r of runs) void host.work(`setup:${r.id}`, () => host.setupStep(s.store.require<SetupExecution>('setupExecutions', r.id)).catch(() => { host.saveRun(s.update(s.store.require<P.SetupRun>('setupRuns', r.id), { state: 'outcome_unknown' })); }));
      return { items: runs, nextCursor: null };
    } },
    { method: 'GET', path: '/v1/setup-runs', auth: 'admin', handler: c => {
      const p = ensureAdmin(c); return s.page(c, s.store.list<P.SetupRun>('setupRuns', r => (!c.query.get('manifestId') || r.manifestId === c.query.get('manifestId')) && (!c.query.get('machineId') || r.machineId === c.query.get('machineId')) && s.auth.canRead(p, 'machines', s.store.get('machines', r.machineId))));
    } },
    { method: 'GET', path: '/v1/machines/:id/management', auth: 'member', handler: c => host.management(principal(c), c.params.id!) },
    { method: 'POST', path: '/v1/host-operations/preview', auth: 'admin', handler: async c => {
      const p = ensureAdmin(c), body = parse(bulk, c.body);
      if (['recreate_environment', 'delete_environment'].includes(body.action)) for (const machineId of body.machineIds) await host.management(p, machineId);
      const binding = host.snapshot(p, body.machineIds, body.action), name = binding.length === 1 ? binding[0]!.name : `${body.action.toUpperCase()} ${binding.length} machines`;
      const destructive = ['recreate_environment', 'delete_environment'].includes(body.action);
      const effects = binding.map(v => `${v.name}: ${body.action}; isolated environment ${v.environmentRoot ?? 'not configured'}; last backup ${v.backup?.lastBackupAtMs ?? 'not verified'}; backup age ${v.backup?.lastBackupAtMs !== null && v.backup?.lastBackupAtMs !== undefined ? Math.max(0, s.now() - v.backup.lastBackupAtMs) + ' ms' : 'unknown'}. ${destructive ? 'Environment files may be lost; newest unsaved data and external backups are not erased.' : 'Preserves disk and identity.'} User home, SSH, product history and access are retained. Active work requires a verified safe point.`);
      const affected: P.ScopeEffect[] = binding.flatMap((v, index) => [{ resourceType: 'machine', id: v.id, machineId: v.id, operation: destructive ? body.action === 'delete_environment' ? 'delete' : 'reset' : 'retain', explanation: effects[index]! }, { resourceType: 'user_home_ssh', id: v.id, machineId: v.id, operation: 'retain', explanation: 'User home and SSH remain accessible; this is not detach.' }]);
      return s.mutations.preview(p, host.operationTarget(p), body.action, name, effects, affected, { action: body.action, machines: binding });
    } },
    { method: 'POST', path: '/v1/host-operations', auth: 'admin', status: 202, handler: c => {
      const p = ensureAdmin(c), body = parse(confirm, c.body), binding = host.snapshot(p, body.machineIds, body.action);
      const value = s.store.transaction(() => {
        if (s.store.list<P.HostOperation>('hostOperations', activeOperation).length) fail('conflict', 'A host operation is already active or awaiting reconciliation.');
        s.mutations.confirm(p, host.operationTarget(p), body.action, body, { action: body.action, machines: binding });
        const o = host.saveOperation(s.resource('host_operation', { action: body.action, ownerUserId: p.userId, state: 'queued' as const, results: binding.map(v => ({ machineId: v.id, state: 'queued' as const, reason: null })) }));
        s.store.put('hostOperationBindings', { id: o.id, principal: p, snapshot: binding }); s.store.setMetadata('hostOperationRevision', host.operationTarget(p).revision + 1); return o;
      });
      c.nonceResourceIds.push(value.id); void host.launchOperation(value); return value;
    } },
    { method: 'GET', path: '/v1/host-operations', auth: 'admin', handler: c => { const p = ensureAdmin(c); return s.page(c, s.store.list<P.HostOperation>('hostOperations', o => o.results.every(r => s.auth.canRead(p, 'machines', s.store.get('machines', r.machineId))))); } },
    { method: 'GET', path: '/v1/host-operations/:id', auth: 'admin', handler: c => { const p = ensureAdmin(c), value = s.store.require<P.HostOperation>('hostOperations', c.params.id!); value.results.forEach(r => host.machine(p, r.machineId)); return value; } },
  ];
  return routes;
}
