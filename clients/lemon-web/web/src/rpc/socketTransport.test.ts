import { describe, expect, it, vi } from 'vitest';
import type { QueuedCommandMeta } from './commandQueue';
import {
  buildWsUrl,
  confirmQueuedCommandWithDeps,
  getConnectionWarningMessage,
  getReconnectDelayMs,
  processReconnectQueue,
  sendOrQueueCommand,
} from './socketTransport';

function createQueuedMeta(overrides: Partial<QueuedCommandMeta> = {}): QueuedCommandMeta {
  return {
    payload: JSON.stringify({ type: 'ping' }),
    enqueuedAt: 1000,
    ttlMs: 300000,
    sessionIdAtEnqueue: 'session-a',
    commandType: 'ping',
    ...overrides,
  };
}

describe('socketTransport', () => {
  it('builds same-origin websocket URL when no env override is provided', () => {
    expect(buildWsUrl('', { protocol: 'https:', host: 'lemon.dev' }, undefined)).toBe(
      'wss://lemon.dev/ws'
    );
    expect(buildWsUrl('', { protocol: 'http:', host: 'localhost:5173' }, undefined)).toBe(
      'ws://localhost:5173/ws'
    );
  });

  it('returns env override URL directly', () => {
    expect(
      buildWsUrl('wss://custom.example/ws', { protocol: 'http:', host: 'ignored' }, undefined)
    ).toBe(
      'wss://custom.example/ws'
    );
  });

  it('appends websocket token when configured', () => {
    expect(
      buildWsUrl('wss://custom.example/ws', { protocol: 'http:', host: 'ignored' }, 'abc123')
    ).toBe('wss://custom.example/ws?token=abc123');

    expect(
      buildWsUrl(
        'wss://custom.example/ws?existing=1',
        { protocol: 'http:', host: 'ignored' },
        'abc123'
      )
    ).toBe('wss://custom.example/ws?existing=1&token=abc123');
  });

  it('calculates reconnect delay with exponential backoff and cap', () => {
    expect(getReconnectDelayMs(0)).toBe(500);
    expect(getReconnectDelayMs(1)).toBe(1000);
    expect(getReconnectDelayMs(4)).toBe(8000);
    expect(getReconnectDelayMs(5)).toBe(10000);
    expect(getReconnectDelayMs(12)).toBe(10000);
  });

  it('creates warning message only at retry threshold', () => {
    expect(getConnectionWarningMessage(2, undefined, 'ws://localhost/ws')).toBeNull();
    expect(getConnectionWarningMessage(3, undefined, 'ws://localhost/ws')).toContain(
      'same-origin WebSocket URL'
    );
    expect(getConnectionWarningMessage(3, 'wss://custom/ws', 'wss://custom/ws')).toContain(
      'VITE_LEMON_WS_URL override'
    );
  });

  it('queues command when socket is unavailable and sends immediately when open', () => {
    const queue = {
      enqueue: vi.fn(),
    };
    const enqueueNotification = vi.fn();
    const now = vi.fn(() => 1234);

    sendOrQueueCommand({
      socket: null,
      command: { type: 'ping' },
      queue,
      activeSessionId: 'session-a',
      ttlMs: 10,
      enqueueNotification,
      now,
    });

    expect(queue.enqueue).toHaveBeenCalledWith(
      { type: 'ping' },
      'session-a',
      10,
      expect.any(Function)
    );

    const onOverflow = queue.enqueue.mock.calls[0][3] as (dropped: QueuedCommandMeta) => void;
    onOverflow(createQueuedMeta({ commandType: 'abort' }));
    expect(enqueueNotification).toHaveBeenCalledWith(
      expect.objectContaining({
        id: 'queue-overflow-1234',
        level: 'warn',
      })
    );

    const send = vi.fn();
    sendOrQueueCommand({
      socket: { readyState: WebSocket.OPEN, send },
      command: { type: 'ping' },
      queue,
      activeSessionId: null,
      ttlMs: 10,
      enqueueNotification,
    });
    expect(send).toHaveBeenCalledWith(JSON.stringify({ type: 'ping' }));
  });

  it('processes reconnect queue and emits callbacks/notifications', () => {
    const expired = createQueuedMeta({ commandType: 'reset' });
    const pending = createQueuedMeta({ commandType: 'abort' });
    const ready = createQueuedMeta({
      payload: JSON.stringify({ type: 'prompt', text: 'continue' }),
      commandType: 'prompt',
    });

    const queue = {
      processOnReconnect: vi.fn(
        (
          _sessionId: string | null,
          onExpired?: (commands: QueuedCommandMeta[]) => void,
          onNeedsConfirmation?: (commands: QueuedCommandMeta[]) => void
        ) => {
          onExpired?.([expired]);
          onNeedsConfirmation?.([pending]);
          return [ready];
        }
      ),
    };

    const enqueueNotification = vi.fn();
    const addPendingConfirmation = vi.fn();
    const sendPayload = vi.fn();

    processReconnectQueue({
      queue,
      currentSessionId: 'session-a',
      enqueueNotification,
      addPendingConfirmation,
      sendPayload,
      now: () => 4567,
    });

    expect(queue.processOnReconnect).toHaveBeenCalledWith(
      'session-a',
      expect.any(Function),
      expect.any(Function)
    );
    expect(addPendingConfirmation).toHaveBeenCalledWith(pending);
    expect(sendPayload).toHaveBeenCalledWith(ready.payload);
    expect(enqueueNotification).toHaveBeenCalledTimes(3);
  });

  it('confirms queued command with dependency injection', () => {
    const meta = createQueuedMeta({
      payload: JSON.stringify({ type: 'prompt', text: 'restored' }),
    });
    const queue = {
      confirmCommand: vi.fn(() => meta),
    };
    const sendCommand = vi.fn();
    const removePendingConfirmation = vi.fn();

    confirmQueuedCommandWithDeps(meta, true, {
      queue,
      getSendCommand: () => sendCommand,
      removePendingConfirmation,
    });

    expect(queue.confirmCommand).toHaveBeenCalledWith(meta, true);
    expect(sendCommand).toHaveBeenCalledWith({ type: 'prompt', text: 'restored' });
    expect(removePendingConfirmation).toHaveBeenCalledWith(meta);
  });

  it('removes pending confirmation even if command is rejected', () => {
    const meta = createQueuedMeta();
    const queue = {
      confirmCommand: vi.fn(() => null),
    };
    const sendCommand = vi.fn();
    const removePendingConfirmation = vi.fn();

    confirmQueuedCommandWithDeps(meta, false, {
      queue,
      getSendCommand: () => sendCommand,
      removePendingConfirmation,
    });

    expect(sendCommand).not.toHaveBeenCalled();
    expect(removePendingConfirmation).toHaveBeenCalledWith(meta);
  });
});
