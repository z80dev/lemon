import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext } from '../core/services';
import type { ConnectedLemonService } from './lemon';
import { ApiError, fail } from '../core/errors';
import { z } from '../core/validation';

export type TerminalFrame = Extract<P.RealtimeServerFrame, { type: 'terminal_output' | 'terminal_exit' | 'terminal_gap' }>;
export interface TerminalService {
  open(principal: Principal, machine: P.Machine, input: P.TerminalOpen, context?: RequestContext): Promise<P.Terminal>;
  require(principal: Principal, terminalId: string, deviceId?: string): P.Terminal;
  input(principal: Principal, terminalId: string, dataBase64: string): Promise<P.Empty>;
  resize(principal: Principal, terminalId: string, cols: number, rows: number): Promise<P.Terminal>;
  close(principal: Principal, terminalId: string): Promise<P.Terminal>;
  subscribe(principal: Principal, deviceId: string, terminalId: string, afterSeq: number, send: (frame: TerminalFrame) => void): () => void;
  revokeUser(userId: string): Promise<void>;
  revokeSession(sessionId: string): Promise<void>;
  closeMachine(machineId: string): Promise<void>;
  dispose(): void;
}
interface ShellBinding { shellId: string | null; sessionId: string | null }
interface Spool { chunks: Extract<TerminalFrame, { type: 'terminal_output' }>[]; bytes: number; latest: number; listeners: Set<(frame: TerminalFrame) => void>; grace: NodeJS.Timeout | undefined }
const outputSchema = z.object({ shellId: z.string(), seq: z.number().int().positive(), dataBase64: z.string().max(21_848) }).strict();
const exitSchema = z.object({ shellId: z.string(), code: z.number().int() }).strict();
const servicesByBackend = new WeakMap<BackendServices, TerminalService>();

/** Exact padded RFC 4648 base64; Buffer's permissive decoder alone is not validation. */
export function decodeChunk(encoded: string, maxBytes: number) {
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) fail('invalid_request', 'Invalid base64 chunk.');
  const bytes = Buffer.from(encoded, 'base64');
  if (bytes.byteLength > maxBytes) fail('too_large', 'Decoded chunk exceeds its limit.');
  if (bytes.toString('base64') !== encoded) fail('invalid_request', 'Base64 chunk is not canonical.');
  return bytes;
}
export function getTerminalService(services: BackendServices): TerminalService {
  const existing = servicesByBackend.get(services);
  if (existing) return existing;
  const created = createTerminalService(services);
  servicesByBackend.set(services, created);
  return created;
}
export function createTerminalService(services: BackendServices, options: { graceMs?: number } = {}): TerminalService {
  const spool = new Map<string, Spool>();
  const shellToTerminal = new Map<string, string>();
  const openingOutput = new Map<string, { dataBase64: string; seq: number }[]>();
  let opening = 0;
  const openingExits = new Map<string, number>();
  let openingBytes = 0;
  const revokedSessions = new Set<string>();
  const revokedUsers = new Set<string>();
  function buffer(id: string): Spool {
    let value = spool.get(id);
    if (!value) { value = { chunks: [], bytes: 0, latest: 0, listeners: new Set(), grace: undefined }; spool.set(id, value); }
    return value;
  }
  function binding(id: string) { return services.store.metadata<ShellBinding>(`terminalShell:${id}`); }
  function persist(terminal: P.Terminal) { services.store.put('terminals', terminal); return terminal; }
  function finish(id: string, code: number | null) {
    const terminal = services.store.get<P.Terminal>('terminals', id);
    if (!terminal || terminal.state === 'closed') return terminal;
    const value = buffer(id); clearTimeout(value.grace); value.grace = undefined;
    const next = persist(services.update(terminal, { state: 'closed', exitCode: code }));
    const shell = binding(id); if (shell?.shellId) shellToTerminal.delete(shell.shellId);
    for (const send of value.listeners) send({ type: 'terminal_exit', terminalId: id, code });
    return next;
  }
  function output(id: string, seq: number, dataBase64: string) {
    const terminal = services.store.get<P.Terminal>('terminals', id);
    if (!terminal || terminal.state !== 'open') return;
    const session = binding(id)?.sessionId;
    if (revokedUsers.has(terminal.userId) || session !== null && session !== undefined && revokedSessions.has(session)) return;
    const value = buffer(id);
    if (seq <= value.latest) return;
    const size = decodeChunk(dataBase64, 16_384).byteLength;
    if (seq !== value.latest + 1) for (const send of value.listeners) send({ type: 'terminal_gap', terminalId: id, earliestSeq: seq, latestSeq: seq });
    value.latest = seq;
    const frame: Extract<TerminalFrame, { type: 'terminal_output' }> = { type: 'terminal_output', terminalId: id, seq, dataBase64 };
    value.chunks.push(frame); value.bytes += size;
    while (value.bytes > 1_048_576 || value.chunks.length > 10_000) value.bytes -= Buffer.from(value.chunks.shift()!.dataBase64, 'base64').byteLength;
    for (const send of value.listeners) send(frame);
  }
  const unlisten = services.lemon.onEvent((event, payload) => {
    if (event === 'node.shell.output') {
      const result = outputSchema.safeParse(payload); if (!result.success) return;
      const item = result.data; const id = shellToTerminal.get(item.shellId);
      if (id) { try { output(id, item.seq, item.dataBase64); } catch { finish(id, null); } }
      else if (opening > 0 && openingBytes + item.dataBase64.length <= 1_398_104) {
        const pending = openingOutput.get(item.shellId) ?? [];
        pending.push({ seq: item.seq, dataBase64: item.dataBase64 }); openingOutput.set(item.shellId, pending); openingBytes += item.dataBase64.length;
      }
    } else if (event === 'node.shell.exit') {
      const result = exitSchema.safeParse(payload); if (!result.success) return;
      const id = shellToTerminal.get(result.data.shellId); if (id) finish(id, result.data.code); else if (opening > 0 && openingExits.size < 64) openingExits.set(result.data.shellId, result.data.code);
    }
  });
  function connectionLost() { for (const terminal of services.store.list<P.Terminal>('terminals', item => item.state === 'open')) finish(terminal.id, null); }
  const lemon = services.lemon as Partial<ConnectedLemonService>;
  const unlost = lemon.onDisconnected?.(connectionLost) ?? (() => {});
  // The controller owns shells by connection, so a new handshake cannot resurrect one.
  const unconnected = services.lemon.onConnected(connectionLost);
  connectionLost();
  function own(principal: Principal, terminalId: string, deviceId?: string) {
    if (principal.kind !== 'user') fail('forbidden', 'A human device session is required for terminal access.');
    if (revokedUsers.has(principal.userId) || principal.sessionId !== null && revokedSessions.has(principal.sessionId)) fail('unauthenticated', 'The opening terminal session has been revoked.');
    const terminal = services.store.require<P.Terminal>('terminals', terminalId);
    if (terminal.userId !== principal.userId || (deviceId !== undefined && terminal.deviceId !== deviceId) || (principal.deviceId !== null && principal.deviceId !== terminal.deviceId)) fail('not_found', 'Terminal not found for this user and device.');
    services.auth.machine(principal, terminal.machineId);
    const device = services.store.require<P.Device>('devices', terminal.deviceId);
    if (device.userId !== principal.userId) fail('forbidden', 'Terminal device is not owned by this user.');
    const saved = binding(terminalId);
    if (terminal.state === 'open' && saved?.sessionId && revokedSessions.has(saved.sessionId)) fail('unauthenticated', 'The session that opened this terminal has been revoked.');
    if (saved && deviceId === undefined && principal.deviceId === null && principal.sessionId !== saved.sessionId) fail('forbidden', 'Terminal belongs to another authenticated device session.');
    return terminal;
  }
  function shell(principal: Principal, terminalId: string) {
    const terminal = own(principal, terminalId);
    if (terminal.state !== 'open') fail('conflict', 'Terminal is closed.');
    const saved = binding(terminalId);
    if (!saved?.shellId || !shellToTerminal.has(saved.shellId)) fail('upstream_unavailable', 'The opening controller connection is unavailable.');
    return { terminal, shellId: saved.shellId };
  }
  async function closeOwned(terminal: P.Terminal) {
    if (terminal.state === 'closed') return terminal;
    const saved = binding(terminal.id);
    if (!saved?.shellId || !shellToTerminal.has(saved.shellId)) return finish(terminal.id, null)!;
    await services.lemon.call('node.shell.close', { shellId: saved.shellId }, { mutation: true, resourceIds: [terminal.id] });
    return finish(terminal.id, null)!;
  }
  const service: TerminalService = {
    async open(principal, machine, input, context) {
      if (principal.kind !== 'user' || !principal.sessionId || revokedSessions.has(principal.sessionId) || revokedUsers.has(principal.userId)) fail('unauthenticated', 'A live human session is required to open a terminal.');
      services.auth.machine(principal, machine.id);
      const device = services.store.require<P.Device>('devices', input.deviceId);
      if (device.userId !== principal.userId || (principal.deviceId !== null && principal.deviceId !== device.id)) fail('forbidden', 'Choose this session’s owned registered device.');
      if (machine.status !== 'online' || !machine.nodeId) fail('machine_offline', 'The machine is not online.');
      let cwd = input.cwd;
      if (!cwd) {
        const host = z.object({ defaultCwd: z.string().min(1).max(16_384) }).passthrough().safeParse(await services.lemon.call('node.host.info', { nodeId: machine.nodeId }));
        if (!host.success) fail('upstream_unavailable', 'The destination returned no valid terminal working directory.');
        cwd = host.data.defaultCwd;
      }
      if (revokedSessions.has(principal.sessionId) || revokedUsers.has(principal.userId)) fail('unauthenticated', 'The opening session was revoked before terminal dispatch.');
      const terminal = persist(services.resource('terminal', { machineId: machine.id, userId: principal.userId, deviceId: device.id, cwd, cols: input.cols, rows: input.rows, state: 'open' as const, exitCode: null }));
      context?.nonceResourceIds.push(terminal.id);
      services.store.setMetadata(`terminalShell:${terminal.id}`, { shellId: null, sessionId: principal.sessionId } satisfies ShellBinding);
      opening++;
      try {
        const response = await services.lemon.call<{ shellId: string }>('node.shell.open', { nodeId: machine.nodeId, cwd, cols: input.cols, rows: input.rows }, { mutation: true, resourceIds: [terminal.id] });
        const parsed = z.object({ shellId: z.string().min(1) }).strict().safeParse(response);
        if (!parsed.success) throw new ApiError('outcome_unknown', 'The terminal may have opened but its receipt is invalid.', false, { resourceIds: [terminal.id] });
        services.store.setMetadata(`terminalShell:${terminal.id}`, { shellId: parsed.data.shellId, sessionId: principal.sessionId } satisfies ShellBinding);
        shellToTerminal.set(parsed.data.shellId, terminal.id);
        if (revokedUsers.has(principal.userId) || revokedSessions.has(principal.sessionId)) {
          await services.lemon.call('node.shell.close', { shellId: parsed.data.shellId }, { mutation: true, resourceIds: [terminal.id] });
          shellToTerminal.delete(parsed.data.shellId);
          finish(terminal.id, null); fail('unauthenticated', 'The terminal session was revoked while opening.');
        }
        const value = buffer(terminal.id);
        value.grace = setTimeout(() => { void closeOwned(terminal).catch(() => services.store.setMetadata(`terminalCloseUncertain:${terminal.id}`, { outcome: 'outcome_unknown', atMs: services.now() })); }, options.graceMs ?? 60_000);
        for (const chunk of openingOutput.get(parsed.data.shellId) ?? []) output(terminal.id, chunk.seq, chunk.dataBase64);
        const earlyExit = openingExits.get(parsed.data.shellId);
        if (earlyExit !== undefined) return finish(terminal.id, earlyExit)!;
        return terminal;
      } catch (error) { if (error instanceof ApiError && error.code === 'outcome_unknown') { services.lemon.close(); services.lemon.start(); } finish(terminal.id, null); throw error; }
      finally { if (--opening === 0) { openingOutput.clear(); openingExits.clear(); openingBytes = 0; } }
    },
    require: own,
    async input(principal, terminalId, dataBase64) {
      decodeChunk(dataBase64, 65_536);
      const target = shell(principal, terminalId);
      await services.lemon.call('node.shell.input', { shellId: target.shellId, dataBase64 }, { mutation: true, resourceIds: [terminalId] });
      return { ok: true };
    },
    async resize(principal, terminalId, cols, rows) {
      const target = shell(principal, terminalId);
      await services.lemon.call('node.shell.resize', { shellId: target.shellId, cols, rows }, { mutation: true, resourceIds: [terminalId] });
      return persist(services.update(target.terminal, { cols, rows }));
    },
    close: async (principal, terminalId) => closeOwned(own(principal, terminalId)),
    subscribe(principal, deviceId, terminalId, afterSeq, send) {
      const terminal = own(principal, terminalId, deviceId);
      if (!Number.isSafeInteger(afterSeq) || afterSeq < 0) fail('invalid_request', 'Invalid terminal sequence.');
      const value = buffer(terminalId); if (afterSeq > value.latest) fail('invalid_request', 'Terminal sequence exceeds its output watermark.');
      clearTimeout(value.grace); value.grace = undefined;
      const earliest = value.chunks[0]?.seq ?? value.latest + 1;
      if (afterSeq < earliest - 1) send({ type: 'terminal_gap', terminalId, earliestSeq: earliest, latestSeq: value.latest });
      let previous = Math.max(afterSeq, earliest - 1);
      for (const frame of value.chunks) if (frame.seq > afterSeq) { if (frame.seq !== previous + 1) send({ type: 'terminal_gap', terminalId, earliestSeq: frame.seq, latestSeq: value.latest }); send(frame); previous = frame.seq; }
      if (terminal.state === 'closed') send({ type: 'terminal_exit', terminalId, code: terminal.exitCode });
      value.listeners.add(send);
      return () => {
        value.listeners.delete(send);
        if (value.listeners.size === 0 && services.store.get<P.Terminal>('terminals', terminalId)?.state === 'open') value.grace = setTimeout(() => { void closeOwned(terminal).catch(() => services.store.setMetadata(`terminalCloseUncertain:${terminalId}`, { outcome: 'outcome_unknown', atMs: services.now() })); }, options.graceMs ?? 60_000);
      };
    },
    async revokeUser(userId) { revokedUsers.add(userId); for (const terminal of services.store.list<P.Terminal>('terminals', item => item.userId === userId && item.state === 'open')) await closeOwned(terminal); },
    async revokeSession(sessionId) { revokedSessions.add(sessionId); for (const terminal of services.store.list<P.Terminal>('terminals', item => item.state === 'open' && binding(item.id)?.sessionId === sessionId)) await closeOwned(terminal); },
    async closeMachine(machineId) { for (const terminal of services.store.list<P.Terminal>('terminals', item => item.machineId === machineId && item.state === 'open')) await closeOwned(terminal); },
    dispose() { unlisten(); unlost(); unconnected(); for (const value of spool.values()) clearTimeout(value.grace); spool.clear(); },
  };
  return service;
}
