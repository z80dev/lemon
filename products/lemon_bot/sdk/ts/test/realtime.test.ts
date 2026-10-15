import { afterEach, beforeEach, describe, expect, test, vi } from 'bun:test';
import { LemonBotClient, compareCursors, nonce } from '../src/index.ts';
import type { RealtimeClientFrame, RealtimeConnection, RealtimeEvent, RealtimeServerFrame, RealtimeState } from '../src/index.ts';
import { fetchBoundary, snapshot } from './fixtures.ts';

class TestSocket extends EventTarget {
  readyState = 0;
  readonly sent: RealtimeClientFrame[] = [];
  constructor(readonly url: string) { super(); }
  send(value: string): void {
    if (this.readyState !== 1) throw new Error('Socket not open');
    this.sent.push(JSON.parse(value));
  }
  open(): void { this.readyState = 1; this.dispatchEvent(new Event('open')); }
  receive(frame: RealtimeServerFrame): void { this.dispatchEvent(new MessageEvent('message', { data: JSON.stringify(frame) })); }
  close(code = 1000): void {
    this.readyState = 3;
    this.dispatchEvent(new CloseEvent('close', { code }));
  }
  acknowledged(): string[] { return this.sent.flatMap(frame => frame.type === 'ack' ? [frame.cursor] : []); }
  subscription(): Extract<RealtimeClientFrame, { type: 'subscribe' }> {
    const frame = [...this.sent].reverse().find(frame => frame.type === 'subscribe');
    if (!frame || frame.type !== 'subscribe') throw new Error('No subscription received');
    return frame;
  }
}

interface Deferred { promise: Promise<void>; resolve: () => void }
function deferred(): Deferred {
  let resolve!: () => void;
  const promise = new Promise<void>(done => { resolve = done; });
  return { promise, resolve };
}

const connections: RealtimeConnection[] = [];
beforeEach(() => { vi.useFakeTimers(); });
afterEach(() => {
  for (const connection of connections.splice(0)) connection.close();
  vi.useRealTimers();
});

async function drain(): Promise<void> {
  // Flush the bounded promise chain without advancing the platform clock.
  for (let turn = 0; turn < 32; turn++) await Promise.resolve();
}

const ready: Extract<RealtimeServerFrame, { type: 'ready' }> = {
  type: 'ready', userId: 'user_1', workspaceId: 'workspace_1', cursor: '9007199254741010', earliestCursor: '1', heartbeatMs: 25000,
};
const event: RealtimeEvent = { type: 'event', seq: '9007199254740994', event: 'user.updated', payload: { ...snapshot.user, revision: 2 }, timestampMs: 2 };

describe('realtime consumer lifecycle', () => {
  test('exposes the real backoff deadline and clears it on retry and close', async () => {
    const sockets: TestSocket[] = [];
    const deadlines: (number | null)[] = [];
    const connection = new LemonBotClient({ baseUrl: 'https://bot.example', token: 'session' }).realtime({
      cursor: snapshot.cursor, onReset: async () => snapshot, onEvent: () => {},
      onState: state => { if (state === 'reconnecting') deadlines.push(connection.nextRetryAtMs); },
      webSocket: url => { const socket = new TestSocket(url); sockets.push(socket); return socket as unknown as WebSocket; },
    });
    connections.push(connection);
    connection.start();
    expect(connection.nextRetryAtMs).toBeNull();
    sockets[0]!.close(1006);
    expect(connection.nextRetryAtMs).toBe(Date.now() + 500);
    expect(deadlines).toEqual([Date.now() + 500]);
    vi.advanceTimersByTime(500);
    expect(sockets).toHaveLength(2);
    expect(connection.nextRetryAtMs).toBeNull();
    sockets[1]!.close(1006);
    expect(connection.nextRetryAtMs).toBe(Date.now() + 1000);
    connection.close();
    expect(connection.nextRetryAtMs).toBeNull();
    vi.advanceTimersByTime(30000);
    expect(sockets).toHaveLength(2);
  });

  test('auth precedes subscription, atomic reset cursor is used instead of ready watermark', async () => {
    const sockets: TestSocket[] = [];
    const reset = deferred();
    const states: RealtimeState[] = [];
    const saved: string[] = [];
    const client = new LemonBotClient({ baseUrl: 'https://bot.example', token: 'product-session' });
    const connection = client.realtime({
      deviceId: 'device_1', onEvent: () => {}, onState: state => { states.push(state); },
      onReset: async () => { await reset.promise; return snapshot; }, saveCursor: cursor => { saved.push(cursor); },
      webSocket: url => { const socket = new TestSocket(url); sockets.push(socket); return socket as unknown as WebSocket; },
    });
    connections.push(connection);
    connection.start();
    const socket = sockets[0]!;
    expect(socket.url).toBe('wss://bot.example/v1/realtime');
    expect(socket.sent).toEqual([]);
    expect(() => connection.send({ type: 'typing', conversationId: 'conversation_1', active: true })).toThrow();
    socket.open();
    expect(socket.sent).toEqual([{ type: 'auth', token: 'product-session', deviceId: 'device_1' }]);
    socket.receive(ready);
    await drain();
    expect(socket.sent).toHaveLength(1);
    expect(connection.state).toBe('syncing');
    reset.resolve();
    await drain();
    const subscription = socket.subscription();
    expect(subscription.cursor).toBe(snapshot.cursor);
    expect(saved).toEqual([snapshot.cursor]);
    socket.receive({ type: 'subscribed', requestId: subscription.requestId, cursor: snapshot.cursor, conversationIds: [] });
    socket.receive({ type: 'caught_up', cursor: ready.cursor });
    await drain();
    expect(connection.state).toBe('live');
    expect(states).toContain('authenticating');
    expect(socket.acknowledged()).toEqual([ready.cursor]);
  });

  test('async application and persistence finish before ack; watermarks cannot overtake events', async () => {
    const application = deferred();
    const persistence = deferred();
    const order: string[] = [];
    const socket = new TestSocket('wss://bot.example/v1/realtime');
    const connection = new LemonBotClient({ baseUrl: 'https://bot.example', token: 'session' }).realtime({
      cursor: snapshot.cursor, onReset: async () => snapshot,
      onEvent: async frame => { order.push(`apply:${frame.seq}`); await application.promise; order.push('applied'); },
      saveCursor: async cursor => { order.push(`save:${cursor}`); await persistence.promise; order.push('saved'); },
      onFrame: frame => { if (frame.type === 'event') order.push('frame'); },
      webSocket: () => socket as unknown as WebSocket,
    });
    connections.push(connection);
    connection.start(); socket.open(); socket.receive(ready); await drain();
    const subscription = socket.subscription();
    socket.receive({ type: 'subscribed', requestId: subscription.requestId, cursor: snapshot.cursor, conversationIds: [] });
    socket.receive(event);
    socket.receive({ type: 'watermark', cursor: '9007199254741000' });
    await drain();
    expect(order).toEqual([`apply:${event.seq}`]);
    expect(socket.acknowledged()).toEqual([]);
    application.resolve(); await drain();
    expect(order).toEqual([`apply:${event.seq}`, 'applied', 'frame', `save:${event.seq}`]);
    expect(socket.acknowledged()).toEqual([]);
    persistence.resolve(); await drain();
    expect(socket.acknowledged()).toEqual([event.seq, '9007199254741000']);
    expect(connection.cursor).toBe('9007199254741000');
    socket.receive(event); await drain();
    expect(order.filter(value => value.startsWith('apply:'))).toHaveLength(1);
  });

  test('uncorrelated subscribe acknowledgements never authorize event application', async () => {
    const sockets: TestSocket[] = [];
    const applied: RealtimeEvent[] = [];
    const connection = new LemonBotClient({ baseUrl: 'https://bot.example', token: 'session' }).realtime({
      cursor: snapshot.cursor, onReset: async () => snapshot, onEvent: frame => { applied.push(frame); }, reconnectDelayMs: 1,
      webSocket: url => { const socket = new TestSocket(url); sockets.push(socket); return socket as unknown as WebSocket; },
    });
    connections.push(connection);
    connection.start(); const socket = sockets[0]!; socket.open(); socket.receive(ready); await drain();
    socket.receive({ type: 'subscribed', requestId: 'other-request', cursor: snapshot.cursor, conversationIds: [] });
    socket.receive(event); await drain();
    expect(applied).toEqual([]);
    expect(socket.acknowledged()).toEqual([]);
    expect(connection.cursor).toBe(snapshot.cursor);
  });

  test('expired cursor resets authoritative state and resubscribes only after new snapshot is persisted', async () => {
    const socket = new TestSocket('wss://bot.example/v1/realtime');
    const reset = deferred();
    const saved: string[] = [];
    let resets = 0;
    const connection = new LemonBotClient({ baseUrl: 'https://bot.example', token: 'session' }).realtime({
      cursor: '1', onEvent: () => {},
      onReset: async () => { resets++; await reset.promise; return snapshot; },
      saveCursor: cursor => { saved.push(cursor); }, webSocket: () => socket as unknown as WebSocket,
    });
    connections.push(connection);
    connection.start(); socket.open(); socket.receive(ready); await drain();
    const old = socket.subscription();
    socket.receive({ type: 'error', requestId: old.requestId, error: { code: 'cursor_expired', message: 'Expired.', requestId: 'req_1', retrySafe: true } });
    await drain();
    expect(resets).toBe(1);
    expect(socket.sent.filter(frame => frame.type === 'subscribe')).toHaveLength(1);
    reset.resolve(); await drain();
    const next = socket.subscription();
    expect(next.requestId).not.toBe(old.requestId);
    expect(next.cursor).toBe(snapshot.cursor);
    expect(saved).toEqual([snapshot.cursor]);
  });

  test('reconnect authenticates/resumes, terminal listeners reattach but no REST/voice mutation is replayed', async () => {
    const sockets: TestSocket[] = [];
    const boundary = fetchBoundary(() => { throw new TypeError('uncertain mutation'); });
    const client = new LemonBotClient({ baseUrl: 'https://bot.example', token: 'session', fetch: boundary.clientFetch });
    const frames: RealtimeServerFrame[] = [];
    const connection = client.realtime({ cursor: snapshot.cursor, onReset: async () => snapshot, onEvent: () => {}, reconnectDelayMs: 1,
      webSocket: url => { const socket = new TestSocket(url); sockets.push(socket); return socket as unknown as WebSocket; },
    });
    connections.push(connection);
    const unsubscribe = connection.subscribe(frame => { frames.push(frame); });
    connection.start(); const first = sockets[0]!; first.open(); first.receive(ready); await drain();
    first.receive({ type: 'subscribed', requestId: first.subscription().requestId, cursor: snapshot.cursor, conversationIds: [] });
    first.receive(event); first.receive({ type: 'caught_up', cursor: event.seq }); await drain();
    connection.send({ type: 'terminal_subscribe', terminalId: 'terminal_1' });
    first.receive({ type: 'terminal_output', terminalId: 'terminal_1', seq: 1, dataBase64: 'aGk=' }); await drain();
    connection.send({ type: 'voice', voiceSessionId: 'voice_1', action: 'mute' });
    await expect(client.call('POST /conversations/:id/messages', { params: { id: 'conversation_1' }, body: { text: 'One intent', clientNonce: nonce() } })).rejects.toMatchObject({ outcomeUnknown: true });
    first.close(1006); vi.advanceTimersByTime(5); await drain();
    const second = sockets[1]!; second.open();
    expect(second.sent).toEqual([{ type: 'auth', token: 'session' }]);
    second.receive(ready); await drain();
    expect(second.subscription().cursor).toBe(event.seq);
    second.receive({ type: 'subscribed', requestId: second.subscription().requestId, cursor: event.seq, conversationIds: [] });
    second.receive({ type: 'caught_up', cursor: event.seq }); await drain();
    expect(second.sent).toContainEqual({ type: 'terminal_subscribe', terminalId: 'terminal_1', afterSeq: 1 });
    expect(second.sent.some(frame => frame.type === 'voice' || frame.type === 'typing' || frame.type === 'presence')).toBe(false);
    expect(boundary.requests).toHaveLength(1);
    expect(frames.some(frame => frame.type === 'terminal_output')).toBe(true);
    unsubscribe(); const count = frames.length;
    second.receive({ type: 'terminal_exit', terminalId: 'terminal_1', code: null }); await drain();
    expect(frames).toHaveLength(count);
  });

  test('failed application preserves cursor and reconnect never acknowledges its event', async () => {
    const sockets: TestSocket[] = [];
    const connection = new LemonBotClient({ baseUrl: 'https://bot.example', token: 'session' }).realtime({ cursor: snapshot.cursor,
      onReset: async () => snapshot, onEvent: async () => { throw new Error('cache write failed'); }, reconnectDelayMs: 1,
      webSocket: url => { const socket = new TestSocket(url); sockets.push(socket); return socket as unknown as WebSocket; },
    });
    connections.push(connection);
    connection.start(); const socket = sockets[0]!; socket.open(); socket.receive(ready); await drain();
    socket.receive({ type: 'subscribed', requestId: socket.subscription().requestId, cursor: snapshot.cursor, conversationIds: [] });
    socket.receive(event); socket.receive({ type: 'watermark', cursor: ready.cursor }); await drain();
    expect(connection.cursor).toBe(snapshot.cursor);
    expect(socket.acknowledged()).toEqual([]);
  });

  test('authentication revocation is terminal and bigint comparison preserves precision', async () => {
    const socket = new TestSocket('wss://bot.example/v1/realtime');
    let created = 0;
    const states: RealtimeState[] = [];
    const connection = new LemonBotClient({ baseUrl: 'https://bot.example', token: 'session' }).realtime({ onReset: async () => snapshot,
      onEvent: () => {}, reconnectDelayMs: 1, onState: state => { states.push(state); }, webSocket: () => { created++; return socket as unknown as WebSocket; },
    });
    connections.push(connection);
    connection.start(); socket.open(); socket.close(4401); vi.advanceTimersByTime(5);
    expect(created).toBe(1);
    expect(connection.state).toBe('unauthenticated');
    expect(states).not.toContain('live');
    expect(compareCursors('9007199254740993', '9007199254740992')).toBe(1);
    expect(compareCursors('0001', '1')).toBe(0);
    expect(() => compareCursors('-1', '0')).toThrow();
  });

  test('heartbeat sends a correlated ping and protocol pong is observed by listeners', async () => {
    const socket = new TestSocket('wss://bot.example/v1/realtime');
    const frames: RealtimeServerFrame[] = [];
    const connection = new LemonBotClient({ baseUrl: 'https://bot.example', token: 'session' }).realtime({ cursor: snapshot.cursor,
      onEvent: () => {}, onReset: async () => snapshot, onFrame: frame => { frames.push(frame); }, webSocket: () => socket as unknown as WebSocket,
    });
    connections.push(connection);
    connection.start(); socket.open(); socket.receive({ ...ready, heartbeatMs: 2 }); await drain();
    vi.advanceTimersByTime(5);
    const ping = socket.sent.find(frame => frame.type === 'ping');
    expect(ping?.type).toBe('ping');
    if (!ping || ping.type !== 'ping') throw new Error('Missing ping');
    socket.receive({ type: 'pong', requestId: ping.requestId }); await drain();
    expect(frames).toContainEqual({ type: 'pong', requestId: ping.requestId });
  });

  test('heartbeat expiry reconnects and forbidden auth closes remain terminal', async () => {
    const sockets: TestSocket[] = [];
    const connection = new LemonBotClient({ baseUrl: 'https://bot.example', token: 'session' }).realtime({
      cursor: snapshot.cursor, onEvent: () => {}, onReset: async () => snapshot, reconnectDelayMs: 1,
      webSocket: url => { const socket = new TestSocket(url); sockets.push(socket); return socket as unknown as WebSocket; },
    });
    connections.push(connection);
    connection.start(); const first = sockets[0]!; first.open(); first.receive(ready); await drain();
    first.receive({ type: 'subscribed', requestId: first.subscription().requestId, cursor: snapshot.cursor, conversationIds: [] });
    first.receive({ type: 'caught_up', cursor: snapshot.cursor }); await drain();
    vi.advanceTimersByTime(60001); await drain();
    expect(sockets).toHaveLength(2);
    expect(connection.state).toBe('reconnecting');
    const second = sockets[1]!; second.open(); second.close(4403);
    vi.advanceTimersByTime(30000);
    expect(sockets).toHaveLength(2);
    expect(connection.state).toBe('forbidden');
    expect(() => connection.send({ type: 'voice', voiceSessionId: 'voice_1', action: 'end' })).toThrow();
  });

  test('cursor persistence failure cannot acknowledge applied-but-unpersisted state', async () => {
    const socket = new TestSocket('wss://bot.example/v1/realtime');
    const connection = new LemonBotClient({ baseUrl: 'https://bot.example', token: 'session' }).realtime({
      cursor: snapshot.cursor, onEvent: () => {}, onReset: async () => snapshot,
      saveCursor: async () => { throw new Error('cursor store unavailable'); },
      webSocket: () => socket as unknown as WebSocket,
    });
    connections.push(connection);
    connection.start(); socket.open(); socket.receive(ready); await drain();
    socket.receive({ type: 'subscribed', requestId: socket.subscription().requestId, cursor: snapshot.cursor, conversationIds: [] });
    socket.receive(event); await drain();
    expect(connection.cursor).toBe(snapshot.cursor);
    expect(socket.acknowledged()).toEqual([]);
    expect(connection.state).toBe('reconnecting');
  });
});
