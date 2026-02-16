import { act, renderHook } from '@testing-library/react';
import type { ClientCommand } from '@lemon-web/shared';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { QueuedCommandMeta } from './commandQueue';

const HOISTED = vi.hoisted(() => {
  const storeState = {
    applyServerMessage: vi.fn(),
    setConnectionState: vi.fn(),
    setSendCommand: vi.fn(),
    enqueueNotification: vi.fn(),
    setQueueCount: vi.fn(),
    addPendingConfirmation: vi.fn(),
    removePendingConfirmation: vi.fn(),
    sessions: {
      activeSessionId: 'session-a',
    },
    sendCommand: undefined as ((command: ClientCommand) => void) | undefined,
  };

  const useLemonStore = vi.fn((selector: (state: typeof storeState) => unknown) =>
    selector(storeState)
  );
  Object.assign(useLemonStore, {
    getState: () => storeState,
  });

  const commandQueue = {
    length: 0,
    subscribe: vi.fn(),
    enqueue: vi.fn(),
    processOnReconnect: vi.fn(),
    confirmCommand: vi.fn(),
  };

  return {
    storeState,
    useLemonStore,
    commandQueue,
  };
});

vi.mock('../store/useLemonStore', () => ({
  useLemonStore: HOISTED.useLemonStore,
}));

vi.mock('./commandQueue', () => ({
  commandQueue: HOISTED.commandQueue,
  DEFAULT_COMMAND_TTL_MS: 5 * 60 * 1000,
}));

import { confirmQueuedCommand, getQueueCount, useLemonSocket } from './useLemonSocket';

class MockWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;
  static instances: MockWebSocket[] = [];

  readonly url: string;
  readyState = MockWebSocket.CONNECTING;
  onopen: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onclose: ((event: CloseEvent) => void) | null = null;
  send = vi.fn();
  close = vi.fn();

  constructor(url: string) {
    this.url = url;
    MockWebSocket.instances.push(this);
  }

  emitOpen(): void {
    this.readyState = MockWebSocket.OPEN;
    this.onopen?.(new Event('open'));
  }

  emitMessage(data: string): void {
    this.onmessage?.({ data } as MessageEvent);
  }

  emitError(): void {
    this.onerror?.(new Event('error'));
  }

  emitClose(): void {
    this.readyState = MockWebSocket.CLOSED;
    this.onclose?.(new CloseEvent('close'));
  }

  static reset(): void {
    MockWebSocket.instances = [];
  }
}

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

describe('useLemonSocket', () => {
  beforeEach(() => {
    vi.useRealTimers();
    vi.clearAllMocks();
    MockWebSocket.reset();
    vi.stubGlobal('WebSocket', MockWebSocket);

    HOISTED.storeState.sessions.activeSessionId = 'session-a';
    HOISTED.storeState.sendCommand = undefined;

    HOISTED.commandQueue.length = 0;
    HOISTED.commandQueue.enqueue.mockReturnValue(true);
    HOISTED.commandQueue.processOnReconnect.mockReturnValue([]);
    HOISTED.commandQueue.confirmCommand.mockReturnValue(null);
    HOISTED.commandQueue.subscribe.mockImplementation((listener: (count: number) => void) => {
      listener(HOISTED.commandQueue.length);
      return vi.fn();
    });
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it('enqueues commands while disconnected and emits queue overflow notification', () => {
    const { unmount } = renderHook(() => useLemonSocket());

    const sendCommand = HOISTED.storeState.setSendCommand.mock.calls[0][0] as (
      command: ClientCommand
    ) => void;
    sendCommand({ type: 'ping' });

    expect(HOISTED.commandQueue.enqueue).toHaveBeenCalledTimes(1);
    expect(HOISTED.commandQueue.enqueue).toHaveBeenCalledWith(
      { type: 'ping' },
      'session-a',
      5 * 60 * 1000,
      expect.any(Function)
    );

    const onOverflow = HOISTED.commandQueue.enqueue.mock.calls[0][3] as (
      dropped: QueuedCommandMeta
    ) => void;
    onOverflow(createQueuedMeta({ commandType: 'abort' }));

    expect(HOISTED.storeState.enqueueNotification).toHaveBeenCalledWith(
      expect.objectContaining({
        level: 'warn',
        message: 'Queue full: dropped oldest command "abort"',
      })
    );

    unmount();
  });

  it('processes queued commands on reconnect and requests config', () => {
    const expired = createQueuedMeta({ commandType: 'reset' });
    const confirmation = createQueuedMeta({
      payload: JSON.stringify({ type: 'abort' }),
      commandType: 'abort',
    });
    const ready = createQueuedMeta({
      payload: JSON.stringify({ type: 'prompt', text: 'hello' }),
      commandType: 'prompt',
    });

    HOISTED.commandQueue.processOnReconnect.mockImplementation(
      (
        _sessionId: string | null,
        onExpired?: (commands: QueuedCommandMeta[]) => void,
        onNeedsConfirmation?: (commands: QueuedCommandMeta[]) => void
      ) => {
        onExpired?.([expired]);
        onNeedsConfirmation?.([confirmation]);
        return [ready];
      }
    );

    const { unmount } = renderHook(() => useLemonSocket());
    const socket = MockWebSocket.instances[0];

    act(() => {
      socket.emitOpen();
    });

    expect(HOISTED.storeState.setConnectionState).toHaveBeenCalledWith('connected');
    expect(HOISTED.commandQueue.processOnReconnect).toHaveBeenCalledWith(
      'session-a',
      expect.any(Function),
      expect.any(Function)
    );
    expect(HOISTED.storeState.addPendingConfirmation).toHaveBeenCalledWith(confirmation);
    expect(socket.send).toHaveBeenCalledWith(ready.payload);
    expect(socket.send).toHaveBeenCalledWith(JSON.stringify({ type: 'get_config' }));

    const messages = HOISTED.storeState.enqueueNotification.mock.calls.map((call) => call[0].message);
    expect(messages).toContain('1 queued command expired while disconnected: reset');
    expect(messages).toContain(
      '1 destructive command queued for different session - please confirm'
    );
    expect(messages).toContain('Sent 1 queued command');

    unmount();
  });

  it('reconnects with exponential backoff after close', () => {
    vi.useFakeTimers();
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    const { unmount } = renderHook(() => useLemonSocket());
    const firstSocket = MockWebSocket.instances[0];

    act(() => {
      firstSocket.emitClose();
    });
    expect(HOISTED.storeState.setConnectionState).toHaveBeenCalledWith('disconnected');
    expect(MockWebSocket.instances).toHaveLength(1);

    act(() => {
      vi.advanceTimersByTime(500);
    });
    expect(MockWebSocket.instances).toHaveLength(2);

    const secondSocket = MockWebSocket.instances[1];
    act(() => {
      secondSocket.emitClose();
    });

    act(() => {
      vi.advanceTimersByTime(1000);
    });
    expect(MockWebSocket.instances).toHaveLength(3);
    expect(warnSpy).not.toHaveBeenCalled();

    unmount();
    warnSpy.mockRestore();
  });
});

describe('confirmQueuedCommand', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    HOISTED.commandQueue.confirmCommand.mockReturnValue(null);
    HOISTED.storeState.sendCommand = undefined;
  });

  it('sends confirmed command and always removes pending confirmation', () => {
    const meta = createQueuedMeta({
      payload: JSON.stringify({ type: 'prompt', text: 'resume' }),
      commandType: 'prompt',
    });
    const sendCommand = vi.fn();
    HOISTED.storeState.sendCommand = sendCommand;
    HOISTED.commandQueue.confirmCommand.mockReturnValue(meta);

    confirmQueuedCommand(meta, true);

    expect(HOISTED.commandQueue.confirmCommand).toHaveBeenCalledWith(meta, true);
    expect(sendCommand).toHaveBeenCalledWith({ type: 'prompt', text: 'resume' });
    expect(HOISTED.storeState.removePendingConfirmation).toHaveBeenCalledWith(meta);
  });

  it('does not send when command is rejected but still removes pending confirmation', () => {
    const meta = createQueuedMeta({ commandType: 'abort' });
    HOISTED.commandQueue.confirmCommand.mockReturnValue(null);

    confirmQueuedCommand(meta, false);

    expect(HOISTED.commandQueue.confirmCommand).toHaveBeenCalledWith(meta, false);
    expect(HOISTED.storeState.removePendingConfirmation).toHaveBeenCalledWith(meta);
  });
});

describe('getQueueCount', () => {
  it('returns the current queue length', () => {
    HOISTED.commandQueue.length = 9;
    expect(getQueueCount()).toBe(9);
  });
});
