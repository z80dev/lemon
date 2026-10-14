import { describe, expect, test, vi } from 'bun:test';
import { createLemonService, type ControlSocket } from '../../src/runtime/lemon';
import { ApiError } from '../../src/core/errors';
interface RequestFrame { type: string; id: string; method: string; params: Record<string, unknown> }
class Socket implements ControlSocket {
  sent: RequestFrame[] = [];
  handlers: { open(): void; frame(data: unknown): void; closed(): void } | null = null;
  send(text: string) { this.sent.push(JSON.parse(text) as RequestFrame); }
  close() { this.handlers?.closed(); }
  listen(handlers: { open(): void; frame(data: unknown): void; closed(): void }) { this.handlers = handlers; }
  deliver(value: unknown) { this.handlers?.frame(JSON.stringify(value)); }
  handshake(methods = ['chat.send', 'nodes.list']) { this.handlers?.open(); this.deliver({ type: 'hello-ok', protocol: 1, server: {}, features: { methods, events: ['chat'] }, snapshot: {}, policy: {}, auth: { role: 'operator' } }); }
}
const config = { controlUrl: 'wss://controller.example/ws', operatorToken: 'server-only-test-token', trustedOverlay: false };

describe('long-lived operator connection', () => {
  test('uses the exact connect auth frame and correlates interleaved responses/events', async () => {
    const socket = new Socket(); const service = createLemonService(config, { socket: () => socket });
    const observed: unknown[] = []; service.onEvent((event, payload) => observed.push({ event, payload }));
    try {
      service.start(); socket.handshake();
      expect(socket.sent[0]?.method).toBe('connect');
      expect(socket.sent[0]?.params.auth).toEqual({ token: config.operatorToken });
      const first = service.call('nodes.list'); const second = service.call('chat.send', { runId: 'fixed_run', sessionKey: 'session', prompt: 'test' }, { mutation: true, resourceIds: ['fixed_run'] });
      socket.deliver({ type: 'event', event: 'chat', seq: 1, payload: { runId: 'other_run', text: 'data' } });
      socket.deliver({ type: 'res', id: socket.sent[2]!.id, ok: true, payload: { runId: 'fixed_run' } });
      socket.deliver({ type: 'res', id: socket.sent[1]!.id, ok: true, payload: { nodes: [] } });
      expect(await first).toEqual({ nodes: [] }); expect(await second).toEqual({ runId: 'fixed_run' });
      expect(observed).toEqual([{ event: 'chat', payload: { runId: 'other_run', text: 'data' } }]);
    } finally { service.close(); }
  });
  test('authentication failure never becomes connected or exposes credential diagnostics', async () => {
    vi.useFakeTimers();
    const socket = new Socket(); let opens = 0;
    const service = createLemonService(config, { socket: () => { opens++; return socket; }, reconnectMinMs: 1, reconnectMaxMs: 1 });
    service.start(); socket.handlers!.open();
    socket.deliver({ type: 'res', id: socket.sent[0]!.id, ok: false, error: { code: 'UNAUTHORIZED', message: 'raw secret diagnostic' } });
    expect(service.connected).toBe(false);
    await expect(service.call('nodes.list')).rejects.toMatchObject({ code: 'upstream_unavailable', retrySafe: true });
    vi.advanceTimersByTime(5); expect(opens).toBe(1); service.close(); vi.useRealTimers();
  });
  test('disconnect rejects dispatched mutation uncertain, reconnects without replay, and fails reads honestly', async () => {
    vi.useFakeTimers();
    const sockets: Socket[] = [];
    const service = createLemonService(config, { socket: () => { const socket = new Socket(); sockets.push(socket); return socket; }, reconnectMinMs: 1, reconnectMaxMs: 1, random: () => 0 });
    try {
      service.start(); sockets[0]!.handshake();
      const mutation = service.call('chat.send', { runId: 'run_fixed' }, { mutation: true, resourceIds: ['run_fixed'] }).catch(error => error as ApiError);
      const read = service.call('nodes.list').catch(error => error as ApiError);
      sockets[0]!.close();
      expect(await mutation).toMatchObject({ code: 'outcome_unknown', retrySafe: false, details: { resourceIds: ['run_fixed'] } });
      expect(await read).toMatchObject({ code: 'upstream_unavailable', retrySafe: true });
      vi.advanceTimersByTime(5); sockets[1]!.handshake();
      expect(sockets[1]!.sent.map(frame => frame.method)).toEqual(['connect']);
      expect(service.connected).toBe(true);
    } finally { service.close(); vi.useRealTimers(); }
  });
  test('known remote path rejection is not an uncertain mutation and raw values never escape', async () => {
    const socket = new Socket(); const service = createLemonService(config, { socket: () => socket });
    try {
      service.start(); socket.handshake(['node.fs.write']);
      const result = service.call('node.fs.write', { nodeId: 'node', path: '/outside', dataBase64: '' }, { mutation: true }).catch(error => error as ApiError);
      socket.deliver({ type: 'res', id: socket.sent[1]!.id, ok: false, error: { code: 'INVALID_REQUEST', message: 'secret and raw path', details: { reason: 'path_not_allowed', retrySafe: true } } });
      const failure = await result;
      expect(failure).toMatchObject({ code: 'forbidden', retrySafe: true });
      if (!(failure instanceof ApiError)) throw new Error('Expected a typed safe rejection.');
      expect(failure.message).not.toContain('secret');
    } finally { service.close(); }
  });
  test('off-loopback plaintext controller is rejected before socket construction', () => {
    expect(() => createLemonService({ ...config, controlUrl: 'ws://remote.example/ws' })).toThrow(ApiError);
  });
});
