import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  createControlPlaneTransport,
  type ControlPlaneConnectionHandler,
  type HelloOkSnapshot,
} from './controlPlaneTransport';

// ============================================================================
// MockWebSocket
// ============================================================================

class MockWebSocket {
  static instances: MockWebSocket[] = [];

  // WebSocket readyState constants
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;

  readyState: number = MockWebSocket.CONNECTING;
  onopen: ((ev: Event) => void) | null = null;
  onmessage: ((ev: MessageEvent) => void) | null = null;
  onclose: ((ev: CloseEvent) => void) | null = null;
  onerror: ((ev: Event) => void) | null = null;
  sentMessages: string[] = [];

  constructor(public url: string) {
    MockWebSocket.instances.push(this);
  }

  send(data: string): void {
    this.sentMessages.push(data);
  }

  close(): void {
    this.readyState = MockWebSocket.CLOSED;
  }

  // Test helpers
  simulateOpen(): void {
    this.readyState = MockWebSocket.OPEN;
    this.onopen?.(new Event('open'));
  }

  simulateMessage(data: unknown): void {
    this.onmessage?.(new MessageEvent('message', { data: JSON.stringify(data) }));
  }

  simulateClose(code = 1000): void {
    this.readyState = MockWebSocket.CLOSED;
    this.onclose?.(new CloseEvent('close', { code, wasClean: code === 1000 }));
  }

  simulateError(): void {
    this.onerror?.(new Event('error'));
  }
}

// ============================================================================
// Test setup / teardown
// ============================================================================

beforeEach(() => {
  MockWebSocket.instances = [];
  vi.stubGlobal('WebSocket', MockWebSocket);
  vi.useFakeTimers();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

// ============================================================================
// Helpers
// ============================================================================

const HELLO_OK_FRAME = {
  type: 'hello-ok',
  protocol: 1,
  server: { version: '1.0.0', nodeId: 'node-1', uptimeMs: 12345 },
  features: { monitoring: true },
  snapshot: { runs: [] },
  policy: {},
  auth: {},
};

function makeHandlers(): ControlPlaneConnectionHandler & {
  onConnectedMock: ReturnType<typeof vi.fn>;
  onDisconnectedMock: ReturnType<typeof vi.fn>;
  onEventMock: ReturnType<typeof vi.fn>;
} {
  const onConnectedMock = vi.fn();
  const onDisconnectedMock = vi.fn();
  const onEventMock = vi.fn();
  return {
    onConnected: onConnectedMock,
    onDisconnected: onDisconnectedMock,
    onEvent: onEventMock,
    onConnectedMock,
    onDisconnectedMock,
    onEventMock,
  };
}

function connectAndHandshake(): {
  transport: ReturnType<typeof createControlPlaneTransport>;
  ws: MockWebSocket;
  handlers: ReturnType<typeof makeHandlers>;
} {
  const handlers = makeHandlers();
  const transport = createControlPlaneTransport(handlers);
  transport.connect('ws://localhost/ws');

  const ws = MockWebSocket.instances[0];
  ws.simulateOpen();         // triggers ws.onopen → sends connect req frame
  ws.simulateMessage(HELLO_OK_FRAME); // server responds → transport is connected

  // Clear the connect req frame from sentMessages so tests only see
  // messages sent after the handshake is complete.
  ws.sentMessages = [];

  return { transport, ws, handlers };
}

// ============================================================================
// Tests
// ============================================================================

describe('createControlPlaneTransport', () => {
  describe('connection lifecycle', () => {
    it('starts in disconnected state', () => {
      const handlers = makeHandlers();
      const transport = createControlPlaneTransport(handlers);
      expect(transport.getConnectionState()).toBe('disconnected');
      expect(transport.isConnected()).toBe(false);
    });

    it('transitions to connecting when connect() is called', () => {
      const handlers = makeHandlers();
      const transport = createControlPlaneTransport(handlers);
      transport.connect('ws://localhost/ws');
      expect(transport.getConnectionState()).toBe('connecting');
      expect(MockWebSocket.instances).toHaveLength(1);
      expect(MockWebSocket.instances[0].url).toBe('ws://localhost/ws');
    });

    it('becomes connected after hello-ok is received', () => {
      const { transport, handlers } = connectAndHandshake();

      expect(transport.getConnectionState()).toBe('connected');
      expect(transport.isConnected()).toBe(true);
      expect(handlers.onConnectedMock).toHaveBeenCalledOnce();

      const snapshot = handlers.onConnectedMock.mock.calls[0][0] as HelloOkSnapshot;
      expect(snapshot.protocol).toBe(1);
      expect(snapshot.server.version).toBe('1.0.0');
      expect(snapshot.features).toEqual({ monitoring: true });
    });

    it('sends connect req frame on open before waiting for hello-ok', () => {
      const handlers = makeHandlers();
      const transport = createControlPlaneTransport(handlers);
      transport.connect('ws://localhost/ws');

      const ws = MockWebSocket.instances[0];
      ws.simulateOpen();

      expect(ws.sentMessages).toHaveLength(1);
      const frame = JSON.parse(ws.sentMessages[0]) as { type: string; method: string };
      expect(frame.type).toBe('req');
      expect(frame.method).toBe('connect');
    });

    it('does NOT become connected until hello-ok is received (open event alone is not enough)', () => {
      const handlers = makeHandlers();
      const transport = createControlPlaneTransport(handlers);
      transport.connect('ws://localhost/ws');

      const ws = MockWebSocket.instances[0];
      ws.simulateOpen();

      expect(transport.getConnectionState()).toBe('connecting');
      expect(handlers.onConnectedMock).not.toHaveBeenCalled();
    });

    it('calls onDisconnected and schedules reconnect on close', () => {
      const { handlers } = connectAndHandshake();
      const ws = MockWebSocket.instances[0];
      ws.simulateClose(1006);

      expect(handlers.onDisconnectedMock).toHaveBeenCalledOnce();

      // Advance past first reconnect delay (500ms)
      vi.advanceTimersByTime(600);
      expect(MockWebSocket.instances).toHaveLength(2);
    });

    it('calls onDisconnected and removes socket when disconnect() is called', () => {
      const { transport, handlers } = connectAndHandshake();
      transport.disconnect();

      expect(transport.getConnectionState()).toBe('disconnected');
      expect(handlers.onDisconnectedMock).toHaveBeenCalledWith('disconnect called');
      expect(transport.isConnected()).toBe(false);
    });

    it('does not reconnect after destroy()', () => {
      const { transport } = connectAndHandshake();
      const ws = MockWebSocket.instances[0];
      transport.destroy();
      ws.simulateClose();

      vi.advanceTimersByTime(5000);
      // Still only 1 socket, no reconnect attempted
      expect(MockWebSocket.instances).toHaveLength(1);
    });
  });

  describe('request / response', () => {
    it('sends a req frame and resolves the promise when matching res arrives', async () => {
      const { transport, ws } = connectAndHandshake();

      const promise = transport.request<{ count: number }>('runs.active.list', { limit: 10 });

      expect(ws.sentMessages).toHaveLength(1);
      const sent = JSON.parse(ws.sentMessages[0]) as { type: string; id: string; method: string; params: Record<string, unknown> };
      expect(sent.type).toBe('req');
      expect(sent.method).toBe('runs.active.list');
      expect(sent.params).toEqual({ limit: 10 });
      expect(typeof sent.id).toBe('string');
      expect(sent.id.length).toBeGreaterThan(0);

      ws.simulateMessage({ type: 'res', id: sent.id, ok: true, payload: { count: 5 } });

      const result = await promise;
      expect(result).toEqual({ count: 5 });
    });

    it('rejects the promise when res has ok:false', async () => {
      const { transport, ws } = connectAndHandshake();

      const promise = transport.request('bad.method');
      const sent = JSON.parse(ws.sentMessages[0]) as { id: string };

      ws.simulateMessage({
        type: 'res',
        id: sent.id,
        ok: false,
        error: { code: 'NOT_FOUND', message: 'Resource not found' },
      });

      await expect(promise).rejects.toThrow('NOT_FOUND: Resource not found');
    });

    it('rejects after timeout when no response arrives', async () => {
      const { transport } = connectAndHandshake();

      const promise = transport.request('slow.method', {}, { timeoutMs: 500 });

      vi.advanceTimersByTime(501);

      await expect(promise).rejects.toThrow('timed out');
    });

    it('rejects immediately when not connected', async () => {
      const handlers = makeHandlers();
      const transport = createControlPlaneTransport(handlers);

      await expect(transport.request('any.method')).rejects.toThrow('Not connected');
    });

    it('resolves multiple concurrent requests independently', async () => {
      const { transport, ws } = connectAndHandshake();

      const p1 = transport.request<string>('method.a');
      const p2 = transport.request<string>('method.b');
      const p3 = transport.request<string>('method.c');

      const [sent1, sent2, sent3] = ws.sentMessages.map(
        (m) => JSON.parse(m) as { id: string; method: string }
      );

      // Respond out of order
      ws.simulateMessage({ type: 'res', id: sent3.id, ok: true, payload: 'c-result' });
      ws.simulateMessage({ type: 'res', id: sent1.id, ok: true, payload: 'a-result' });
      ws.simulateMessage({ type: 'res', id: sent2.id, ok: true, payload: 'b-result' });

      expect(await p1).toBe('a-result');
      expect(await p2).toBe('b-result');
      expect(await p3).toBe('c-result');
    });
  });

  describe('event routing', () => {
    it('calls onEvent with correct arguments when event frame is received', () => {
      const { handlers, ws } = connectAndHandshake();

      ws.simulateMessage({
        type: 'event',
        event: 'run.started',
        payload: { runId: 'abc-123' },
        seq: 42,
        stateVersion: { runs: 5 },
      });

      expect(handlers.onEventMock).toHaveBeenCalledOnce();
      expect(handlers.onEventMock).toHaveBeenCalledWith(
        'run.started',
        { runId: 'abc-123' },
        42,
        { runs: 5 }
      );
    });

    it('routes multiple events in order', () => {
      const { handlers, ws } = connectAndHandshake();

      ws.simulateMessage({ type: 'event', event: 'evt.one', payload: 1, seq: 1, stateVersion: {} });
      ws.simulateMessage({ type: 'event', event: 'evt.two', payload: 2, seq: 2, stateVersion: {} });
      ws.simulateMessage({ type: 'event', event: 'evt.three', payload: 3, seq: 3, stateVersion: {} });

      expect(handlers.onEventMock).toHaveBeenCalledTimes(3);
      expect(handlers.onEventMock.mock.calls[0][0]).toBe('evt.one');
      expect(handlers.onEventMock.mock.calls[1][0]).toBe('evt.two');
      expect(handlers.onEventMock.mock.calls[2][0]).toBe('evt.three');
    });
  });

  describe('disconnect behaviour', () => {
    it('rejects all pending requests when connection closes', async () => {
      const { transport, ws } = connectAndHandshake();

      const p1 = transport.request('method.a');
      const p2 = transport.request('method.b');

      ws.simulateClose();

      await expect(p1).rejects.toThrow();
      await expect(p2).rejects.toThrow();
    });

    it('rejects pending requests when destroy() is called', async () => {
      const { transport } = connectAndHandshake();
      const p = transport.request('pending.method');
      transport.destroy();
      await expect(p).rejects.toThrow('Transport destroyed');
    });
  });

  describe('reconnection', () => {
    it('reconnects with exponential backoff after disconnect', () => {
      const handlers = makeHandlers();
      const transport = createControlPlaneTransport(handlers);
      transport.connect('ws://localhost/ws');

      const ws1 = MockWebSocket.instances[0];
      ws1.simulateOpen();
      ws1.simulateMessage(HELLO_OK_FRAME);
      ws1.simulateClose(1006);

      expect(MockWebSocket.instances).toHaveLength(1);

      // First reconnect: 500ms
      vi.advanceTimersByTime(500);
      expect(MockWebSocket.instances).toHaveLength(2);

      const ws2 = MockWebSocket.instances[1];
      ws2.simulateOpen();
      ws2.simulateMessage(HELLO_OK_FRAME);
      ws2.simulateClose(1006);

      // Second reconnect: 1000ms
      vi.advanceTimersByTime(1000);
      expect(MockWebSocket.instances).toHaveLength(3);
    });

    it('resets retry count after a successful hello-ok', () => {
      const handlers = makeHandlers();
      const transport = createControlPlaneTransport(handlers);
      transport.connect('ws://localhost/ws');

      // Fail twice
      MockWebSocket.instances[0].simulateClose(1006);
      vi.advanceTimersByTime(500);
      MockWebSocket.instances[1].simulateClose(1006);
      vi.advanceTimersByTime(1000);

      // Now succeed
      const ws3 = MockWebSocket.instances[2];
      ws3.simulateOpen();
      ws3.simulateMessage(HELLO_OK_FRAME);

      // Close again — retry count should be reset so next delay is 500ms
      ws3.simulateClose(1006);
      vi.advanceTimersByTime(500);
      expect(MockWebSocket.instances).toHaveLength(4);
    });
  });

  describe('unknown / malformed frames', () => {
    it('ignores unknown frame types gracefully', () => {
      const { handlers, ws } = connectAndHandshake();

      expect(() => {
        ws.simulateMessage({ type: 'unknown-frame-type', data: 'whatever' });
      }).not.toThrow();

      expect(handlers.onEventMock).not.toHaveBeenCalled();
      expect(handlers.onDisconnectedMock).not.toHaveBeenCalled();
    });

    it('ignores malformed JSON messages gracefully', () => {
      const { handlers } = connectAndHandshake();
      const ws = MockWebSocket.instances[0];

      expect(() => {
        ws.onmessage?.(new MessageEvent('message', { data: 'not-json{{{' }));
      }).not.toThrow();

      expect(handlers.onEventMock).not.toHaveBeenCalled();
    });

    it('ignores res frames with unknown IDs', () => {
      const { handlers, ws } = connectAndHandshake();

      expect(() => {
        ws.simulateMessage({ type: 'res', id: 'non-existent-id', ok: true, payload: {} });
      }).not.toThrow();

      expect(handlers.onEventMock).not.toHaveBeenCalled();
    });

    it('ignores pong frames silently', () => {
      const { handlers, ws } = connectAndHandshake();

      expect(() => {
        ws.simulateMessage({ type: 'pong' });
      }).not.toThrow();

      expect(handlers.onEventMock).not.toHaveBeenCalled();
    });
  });
});
