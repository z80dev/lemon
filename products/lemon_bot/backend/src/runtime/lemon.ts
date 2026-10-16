import type { BackendConfiguration, LemonService } from '../core/services';
import type { ErrorCode, JSONObject } from '../../../contracts/protocol';
import { ApiError } from '../core/errors';
import { z } from '../core/validation';

export interface ControlSocket {
  send(text: string): void;
  close(): void;
  listen(handlers: { open(): void; frame(data: unknown): void; closed(): void }): void;
}
export interface LemonOptions {
  socket?: (url: string) => ControlSocket;
  requestTimeoutMs?: number;
  handshakeTimeoutMs?: number;
  reconnectMinMs?: number;
  reconnectMaxMs?: number;
  random?: () => number;
}
export interface ConnectedLemonService extends LemonService {
  onDisconnected(listener: () => void): () => void;
}
const object = z.record(z.string(), z.unknown());
const frameSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('hello-ok'), protocol: z.literal(1), features: z.object({ methods: z.array(z.string()) }).passthrough(), auth: z.object({ role: z.string(), scopes: z.array(z.string()).optional() }).passthrough(), policy: z.object({ maxPayload: z.number().int().positive().optional() }).passthrough().optional() }).passthrough(),
  z.object({ type: z.literal('res'), id: z.string(), ok: z.boolean(), payload: z.unknown().optional(), error: z.object({ code: z.string(), details: z.unknown().optional(), message: z.string().optional() }).passthrough().optional() }).passthrough(),
  z.object({ type: z.literal('event'), event: z.string(), seq: z.number().int().nonnegative(), payload: z.unknown().optional() }).passthrough(),
]);
function nativeSocket(url: string): ControlSocket {
  const socket = new WebSocket(url);
  return {
    send: text => socket.send(text), close: () => socket.close(),
    listen: handlers => {
      socket.addEventListener('open', handlers.open);
      socket.addEventListener('message', event => handlers.frame(event.data));
      socket.addEventListener('close', handlers.closed);
      socket.addEventListener('error', () => { socket.close(); handlers.closed(); });
    },
  };
}
const upstreamCodes: Record<string, ErrorCode> = { INVALID_REQUEST: 'invalid_request', INVALID_PARAMS: 'invalid_request', UNAUTHORIZED: 'upstream_unavailable', FORBIDDEN: 'forbidden', PERMISSION_DENIED: 'forbidden', NOT_FOUND: 'not_found', CONFLICT: 'conflict', RATE_LIMITED: 'rate_limited', METHOD_NOT_FOUND: 'capability_unavailable', NOT_IMPLEMENTED: 'capability_unavailable' };
const processAdmissionReasons = new Set(['process_receipt_limit', 'process_limit', 'process_busy']);
function upstreamFailure(code: string, details: Record<string, unknown> | undefined, mutation: boolean, ids: string[], method: string): ApiError {
  const processMethod = method === 'node.process.run' || method === 'node.process.get' || method === 'node.process.cancel';
  const reason = typeof details?.reason === 'string' ? details.reason : '';
  const processReason = processMethod && processAdmissionReasons.has(reason);
  const bindingRejection = (method === 'providers.management.device.complete' || method === 'node.providers.management.device.complete')
    && code === 'FORBIDDEN' && reason === 'provider_binding_rejected' && details?.retrySafe === false && details?.mutationMayHaveApplied === false;
  const verifiedNoEffect = bindingRejection || processReason && details?.mutationMayHaveApplied === false;
  const unknown = !verifiedNoEffect && (details?.retrySafe === false || details?.code === 'SUBMISSION_OUTCOME_UNKNOWN' || mutation && (details?.mutationMayHaveApplied === true || ['INTERNAL_ERROR', 'TIMEOUT'].includes(code)));
  const safeDetails: JSONObject = { resourceIds: ids };
  if (bindingRejection) {
    safeDetails.reason = 'provider_binding_rejected';
    safeDetails.mutationMayHaveApplied = false;
    return new ApiError('forbidden', 'The provider login binding was rejected by its execution target.', false, safeDetails);
  }
  if (processMethod) {
    if (processReason) safeDetails.reason = reason;
    if (typeof details?.mutationMayHaveApplied === 'boolean') safeDetails.mutationMayHaveApplied = details.mutationMayHaveApplied;
    if (typeof details?.preDispatch === 'boolean') safeDetails.preDispatch = details.preDispatch;
  } else if (typeof details?.runId === 'string') safeDetails.runId = details.runId;
  if (unknown && mutation) return new ApiError('outcome_unknown', 'The runtime may have applied this operation. Reconcile its reserved resources; do not resubmit.', false, safeDetails);
  if (verifiedNoEffect) return new ApiError('upstream_unavailable', 'Destination process admission capacity is unavailable.', false, safeDetails);
  let mapped: ErrorCode;
  if (reason === 'not_found' || reason === 'shell_not_found') mapped = 'not_found';
  else if (reason === 'permission_denied' || reason === 'path_not_allowed') mapped = 'forbidden';
  else if (reason === 'already_exists' || reason === 'directory_not_empty') mapped = 'conflict';
  else if (reason === 'revision_conflict') mapped = 'revision_conflict';
  else if (reason === 'invalid_confirmation_token' || reason === 'stale_preview') mapped = 'confirmation_required';
  else if (reason === 'confirmation_expired') mapped = 'expired';
  else if (reason === 'atomic_move_unavailable') mapped = 'capability_unavailable';
  else if (reason === 'content_too_large' || reason === 'preview_too_large') mapped = 'too_large';
  else mapped = upstreamCodes[code] ?? 'upstream_unavailable';
  // Remote messages/details can contain paths, prompts, credentials or exception terms.
  return new ApiError(mapped, 'The runtime rejected or could not complete this operation.', details?.retrySafe !== false && (mutation ? !unknown : true), safeDetails);
}

/** One authenticated connection. Nothing in pending requests is ever resent. */
export function createLemonService(config: Pick<BackendConfiguration, 'controlUrl' | 'operatorToken' | 'trustedOverlay'>, options: LemonOptions = {}): ConnectedLemonService {
  const url = new URL(config.controlUrl);
  if (!['ws:', 'wss:'].includes(url.protocol) || url.username || url.password || url.search || url.hash || !config.operatorToken || (url.protocol !== 'wss:' && !['localhost', '127.0.0.1', '[::1]'].includes(url.hostname) && !config.trustedOverlay)) throw new ApiError('invalid_request', 'Configure a secure controller URL and operator token.');
  const events = new Set<(event: string, payload: unknown) => void>();
  const connected = new Set<() => void>();
  const disconnected = new Set<() => void>();
  const pending = new Map<string, { resolve(value: unknown): void; reject(error: ApiError): void; timer: NodeJS.Timeout; mutation: boolean; ids: string[]; method: string }>();
  let socket: ControlSocket | null = null;
  let reconnect: NodeJS.Timeout | undefined;
  let handshake: NodeJS.Timeout | undefined;
  let running = false;
  let attempt = 0;
  let handshakeId = '';
  let lastSeq = -1;
  let maxPayload = 16_777_216;
  const service: ConnectedLemonService = {
    connected: false, methods: [],
    controller: { url: url.href, state: 'stopped', connectedAtMs: null, lastDisconnectedAtMs: null, lastError: null, nextRetryAtMs: null, methodCount: 0 },
    reconnect() {
      running = false; clearTimeout(reconnect); reconnect = undefined;
      const previous = socket; loseConnection(); previous?.close();
      attempt = 0; running = true; connect();
    },
    call<T = unknown>(method: string, params: Record<string, unknown> = {}, callOptions = {}): Promise<T> {
      if (!service.connected || !socket) return Promise.reject(new ApiError('upstream_unavailable', 'The controller is not connected.'));
      if (!service.methods.includes(method)) return Promise.reject(new ApiError('capability_unavailable', 'The controller does not advertise the required method.'));
      const opts = callOptions as { mutation?: boolean; timeoutMs?: number; resourceIds?: string[] };
      const requestId = crypto.randomUUID();
      const wire = JSON.stringify({ type: 'req', id: requestId, method, params });
      if (Buffer.byteLength(wire, 'utf8') > maxPayload) return Promise.reject(new ApiError('too_large', 'The request exceeds the controller’s negotiated payload limit.'));
      const { promise, resolve, reject } = Promise.withResolvers<unknown>();
      const item = { resolve, reject, method, mutation: opts.mutation === true, ids: opts.resourceIds ?? [], timer: setTimeout(() => {
        if (!pending.delete(requestId)) return;
        reject(uncertain(item.mutation, item.ids));
      }, opts.timeoutMs ?? options.requestTimeoutMs ?? 40_000) };
      pending.set(requestId, item);
      try { socket.send(wire); } catch {
        pending.delete(requestId); clearTimeout(item.timer);
        // A throwing send may have queued bytes before throwing; fail closed.
        reject(uncertain(item.mutation, item.ids));
        socket?.close(); loseConnection();
      }
      return promise as Promise<T>;
    },
    onEvent(listener) { events.add(listener); return () => { events.delete(listener); }; },
    onConnected(listener) { connected.add(listener); return () => { connected.delete(listener); }; },
    onDisconnected(listener) { disconnected.add(listener); return () => { disconnected.delete(listener); }; },
    start() { if (running) return; running = true; connect(); },
    close() { running = false; clearTimeout(reconnect); reconnect = undefined; const previous = socket; loseConnection(); previous?.close(); service.controller.state = 'stopped'; service.controller.nextRetryAtMs = null; },
  };
  function uncertain(mutation: boolean, ids: string[]) {
    return mutation ? new ApiError('outcome_unknown', 'The dispatched operation has an unknown outcome; do not resubmit.', false, { resourceIds: ids }) : new ApiError('upstream_unavailable', 'The controller response was interrupted.');
  }
  function loseConnection() {
    if (!socket) return;
    socket = null;
    clearTimeout(handshake); handshake = undefined;
    const wasConnected = service.connected;
    service.connected = false;
    service.controller.connectedAtMs = null;
    service.controller.lastDisconnectedAtMs = Date.now();
    service.methods = []; service.controller.methodCount = 0;
    if (running && !service.controller.lastError) linkError('controller_unreachable', `Nothing answered at ${url.href}.`);
    for (const item of pending.values()) { clearTimeout(item.timer); item.reject(uncertain(item.mutation, item.ids)); }
    pending.clear();
    if (wasConnected) for (const listener of disconnected) listener();
    scheduleReconnect();
  }
  function scheduleReconnect() {
    if (running && !reconnect) {
      const cap = Math.min(options.reconnectMaxMs ?? 30_000, (options.reconnectMinMs ?? 500) * 2 ** Math.min(attempt++, 16));
      const delay = cap * (0.5 + (options.random ?? Math.random)() * 0.5);
      service.controller.state = 'reconnecting'; service.controller.nextRetryAtMs = Date.now() + delay;
      reconnect = setTimeout(() => { reconnect = undefined; connect(); }, delay);
    }
  }
  function connect() {
    if (!running || socket) return;
    service.controller.state = attempt ? 'reconnecting' : 'connecting'; service.controller.nextRetryAtMs = null;
    let current: ControlSocket;
    try { current = (options.socket ?? nativeSocket)(config.controlUrl); } catch {
      // Use the same backoff even for constructor-level network errors.
      linkError('controller_unreachable', `Nothing answered at ${url.href}.`);
      scheduleReconnect(); return;
    }
    socket = current; lastSeq = -1;
    handshake = setTimeout(() => { if (socket === current) { linkError('controller_handshake_timeout', 'The controller did not finish connecting in time.'); loseConnection(); current.close(); } }, options.handshakeTimeoutMs ?? 10_000);
    current.listen({
      open() {
        if (socket !== current) return;
        handshakeId = crypto.randomUUID();
        try { current.send(JSON.stringify({ type: 'req', id: handshakeId, method: 'connect', params: { role: 'operator', client: { id: 'lemon_bot', version: '1' }, auth: { token: config.operatorToken } } })); } catch { current.close(); loseConnection(); }
      },
      closed() { if (socket === current) { if (!service.controller.lastError) linkError('controller_unreachable', `Nothing answered at ${url.href}.`); loseConnection(); } },
      frame(data) {
        if (socket !== current) return;
        if (typeof data !== 'string' || Buffer.byteLength(data, 'utf8') > maxPayload) { protocolFailure(current); return; }
        let decoded: unknown;
        try { decoded = JSON.parse(data); } catch { protocolFailure(current); return; }
        const result = frameSchema.safeParse(decoded);
        if (!result.success) { protocolFailure(current); return; }
        const frame = result.data;
        if (frame.type === 'hello-ok') {
          if (frame.auth.role !== 'operator' || !handshakeId) { running = false; linkError('controller_rejected', 'The controller rejected the operator token. Check LEMON_BOT_OPERATOR_TOKEN.'); service.controller.state = 'rejected'; loseConnection(); current.close(); return; }
          if (service.connected) { protocolFailure(current); return; }
          clearTimeout(handshake); handshake = undefined;
          maxPayload = frame.policy?.maxPayload ?? 16_777_216;
          service.methods = frame.features.methods; service.connected = true; attempt = 0;
          service.controller.state = 'connected'; service.controller.connectedAtMs = Date.now(); service.controller.lastError = null; service.controller.nextRetryAtMs = null; service.controller.methodCount = service.methods.length;
          for (const listener of connected) listener();
        } else if (frame.type === 'res') {
          if (!service.connected && frame.id === handshakeId) {
            // Invalid server credential needs operator repair, not a retry storm.
            if (frame.error?.code === 'UNAUTHORIZED' || frame.error?.code === 'FORBIDDEN') {
              running = false; service.controller.state = 'rejected';
              linkError('controller_rejected', 'The controller rejected the operator token. Check LEMON_BOT_OPERATOR_TOKEN.');
            } else linkError('controller_protocol_violation', 'The controller returned an invalid connection response.');
            loseConnection(); current.close(); return;
          }
          const item = pending.get(frame.id);
          if (!item) return;
          clearTimeout(item.timer); pending.delete(frame.id);
          if (frame.ok) item.resolve(frame.payload);
          else {
            const details = frame.error?.details;
            const structuredDetails = details !== null && typeof details === 'object' && !Array.isArray(details) ? details as Record<string, unknown> : undefined;
            item.reject(upstreamFailure(frame.error?.code ?? 'INTERNAL_ERROR', structuredDetails, item.mutation, item.ids, item.method));
          }
        } else if (service.connected && frame.seq > lastSeq) {
          lastSeq = frame.seq;
          for (const listener of events) listener(frame.event, frame.payload);
        }
      },
    });
  }
  function linkError(code: string, message: string) { service.controller.lastError = { code, message, atMs: Date.now() }; }
  function protocolFailure(current: ControlSocket) { linkError('controller_protocol_violation', 'The controller sent an invalid protocol message.'); loseConnection(); current.close(); }
  return service;
}
