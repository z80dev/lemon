import { act, renderHook } from '@testing-library/react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { useControlPlane } from './useControlPlane';

// ============================================================================
// MockWebSocket (same pattern as controlPlaneTransport.test.ts)
// ============================================================================

class MockWebSocket {
  static instances: MockWebSocket[] = [];

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
}

// ============================================================================
// Helpers
// ============================================================================

const HELLO_OK_FRAME = {
  type: 'hello-ok',
  protocol: 1,
  server: { version: '1.0.0', nodeId: 'node-1', uptimeMs: 9999 },
  features: { monitoring: true },
  snapshot: {},
  policy: {},
  auth: {},
};

// ============================================================================
// Setup / teardown
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
// Tests
// ============================================================================

describe('useControlPlane', () => {
  it('auto-connects on mount when autoConnect is true (default)', () => {
    const { unmount } = renderHook(() => useControlPlane());

    expect(MockWebSocket.instances).toHaveLength(1);

    unmount();
  });

  it('does NOT auto-connect when autoConnect is false', () => {
    const { unmount } = renderHook(() =>
      useControlPlane(undefined, { autoConnect: false })
    );

    expect(MockWebSocket.instances).toHaveLength(0);

    unmount();
  });

  it('starts with disconnected connectionState before mount connects', () => {
    const { result, unmount } = renderHook(() =>
      useControlPlane(undefined, { autoConnect: false })
    );

    expect(result.current.connectionState).toBe('disconnected');
    expect(result.current.isConnected).toBe(false);

    unmount();
  });

  it('transitions to connecting then connected after hello-ok', async () => {
    const { result, unmount } = renderHook(() => useControlPlane());

    // After mount, we should have initiated a connection
    expect(MockWebSocket.instances).toHaveLength(1);

    const ws = MockWebSocket.instances[0];

    // Simulate handshake
    await act(async () => {
      ws.simulateOpen();
      ws.simulateMessage(HELLO_OK_FRAME);
    });

    expect(result.current.connectionState).toBe('connected');
    expect(result.current.isConnected).toBe(true);
    expect(result.current.snapshot).not.toBeNull();
    expect(result.current.snapshot?.protocol).toBe(1);
    expect(result.current.snapshot?.features).toEqual({ monitoring: true });

    unmount();
  });

  it('transitions to disconnected when the socket closes', async () => {
    const { result, unmount } = renderHook(() => useControlPlane());

    const ws = MockWebSocket.instances[0];

    await act(async () => {
      ws.simulateOpen();
      ws.simulateMessage(HELLO_OK_FRAME);
    });

    expect(result.current.isConnected).toBe(true);

    await act(async () => {
      ws.simulateClose(1006);
    });

    expect(result.current.connectionState).toBe('disconnected');
    expect(result.current.isConnected).toBe(false);

    unmount();
  });

  it('disconnects and destroys transport on unmount', async () => {
    const { unmount } = renderHook(() => useControlPlane());

    const ws = MockWebSocket.instances[0];
    await act(async () => {
      ws.simulateOpen();
      ws.simulateMessage(HELLO_OK_FRAME);
    });

    unmount();

    // After unmount, no reconnect should occur
    act(() => {
      vi.advanceTimersByTime(5000);
    });
    expect(MockWebSocket.instances).toHaveLength(1);
  });

  it('calls onEvent when an event frame is received', async () => {
    const onEvent = vi.fn();
    const { unmount } = renderHook(() => useControlPlane(onEvent));

    const ws = MockWebSocket.instances[0];
    await act(async () => {
      ws.simulateOpen();
      ws.simulateMessage(HELLO_OK_FRAME);
      ws.simulateMessage({
        type: 'event',
        event: 'run.started',
        payload: { runId: 'xyz' },
        seq: 1,
        stateVersion: { runs: 1 },
      });
    });

    expect(onEvent).toHaveBeenCalledOnce();
    expect(onEvent).toHaveBeenCalledWith('run.started', { runId: 'xyz' }, 1, { runs: 1 });

    unmount();
  });

  it('updates lastEvent state when an event frame is received', async () => {
    const { result, unmount } = renderHook(() => useControlPlane());

    const ws = MockWebSocket.instances[0];
    await act(async () => {
      ws.simulateOpen();
      ws.simulateMessage(HELLO_OK_FRAME);
      ws.simulateMessage({
        type: 'event',
        event: 'task.completed',
        payload: { taskId: 't1' },
        seq: 7,
        stateVersion: {},
      });
    });

    expect(result.current.lastEvent).toEqual({
      name: 'task.completed',
      payload: { taskId: 't1' },
      seq: 7,
    });

    unmount();
  });

  it('sends a req frame and resolves with the response payload', async () => {
    const { result, unmount } = renderHook(() => useControlPlane());

    const ws = MockWebSocket.instances[0];
    await act(async () => {
      ws.simulateOpen();
      ws.simulateMessage(HELLO_OK_FRAME);
    });

    // Clear connect req frame so we only see post-handshake messages
    ws.sentMessages = [];

    // Initiate request
    let responseValue: unknown;
    let requestPromise!: Promise<unknown>;

    act(() => {
      requestPromise = result.current.request('runs.active.list', { limit: 5 });
    });

    // Verify req frame was sent
    expect(ws.sentMessages).toHaveLength(1);
    const reqFrame = JSON.parse(ws.sentMessages[0]) as {
      type: string;
      id: string;
      method: string;
      params: Record<string, unknown>;
    };
    expect(reqFrame.type).toBe('req');
    expect(reqFrame.method).toBe('runs.active.list');
    expect(reqFrame.params).toEqual({ limit: 5 });

    // Simulate server response
    await act(async () => {
      ws.simulateMessage({
        type: 'res',
        id: reqFrame.id,
        ok: true,
        payload: { runs: [], total: 0, filters: {} },
      });
      responseValue = await requestPromise;
    });

    expect(responseValue).toEqual({ runs: [], total: 0, filters: {} });

    unmount();
  });

  it('exposes manual connect() that initiates connection', async () => {
    const { result, unmount } = renderHook(() =>
      useControlPlane(undefined, { autoConnect: false })
    );

    expect(MockWebSocket.instances).toHaveLength(0);

    await act(async () => {
      result.current.connect();
    });

    expect(MockWebSocket.instances).toHaveLength(1);

    unmount();
  });

  it('exposes manual disconnect() that closes the connection', async () => {
    const { result, unmount } = renderHook(() => useControlPlane());

    const ws = MockWebSocket.instances[0];
    await act(async () => {
      ws.simulateOpen();
      ws.simulateMessage(HELLO_OK_FRAME);
    });

    expect(result.current.isConnected).toBe(true);

    await act(async () => {
      result.current.disconnect();
    });

    expect(result.current.connectionState).toBe('disconnected');

    unmount();
  });
});
