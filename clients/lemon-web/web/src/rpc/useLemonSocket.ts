import { useCallback, useEffect, useRef } from 'react';
import type { ClientCommand, WireServerMessage } from '@lemon-web/shared';
import { useLemonStore } from '../store/useLemonStore';
import {
  commandQueue,
  type QueuedCommandMeta,
  DEFAULT_COMMAND_TTL_MS,
} from './commandQueue';
import {
  buildWsUrl,
  confirmQueuedCommandWithDeps,
  getReconnectDelayMs,
  logConnectionWarning,
  processReconnectQueue,
  sendOrQueueCommand,
} from './socketTransport';

export function useLemonSocket(): void {
  const applyServerMessage = useLemonStore((state) => state.applyServerMessage);
  const setConnectionState = useLemonStore((state) => state.setConnectionState);
  const setSendCommand = useLemonStore((state) => state.setSendCommand);
  const enqueueNotification = useLemonStore((state) => state.enqueueNotification);
  const setQueueCount = useLemonStore((state) => state.setQueueCount);
  const addPendingConfirmation = useLemonStore((state) => state.addPendingConfirmation);

  const socketRef = useRef<WebSocket | null>(null);
  const reconnectTimer = useRef<number | null>(null);
  const retryCount = useRef<number>(0);

  // Subscribe to queue count changes
  useEffect(() => {
    const unsubscribe = commandQueue.subscribe((count) => {
      setQueueCount(count);
    });
    return unsubscribe;
  }, [setQueueCount]);

  const send = useCallback(
    (command: ClientCommand) => {
      sendOrQueueCommand({
        socket: socketRef.current,
        command,
        queue: commandQueue,
        activeSessionId: useLemonStore.getState().sessions.activeSessionId,
        ttlMs: DEFAULT_COMMAND_TTL_MS,
        enqueueNotification,
      });
    },
    [enqueueNotification]
  );

  useEffect(() => {
    setSendCommand(send);
  }, [send, setSendCommand]);

  useEffect(() => {
    let cancelled = false;

    const connect = () => {
      if (cancelled) {
        return;
      }

      setConnectionState('connecting');

      const ws = new WebSocket(buildWsUrl());
      socketRef.current = ws;

      ws.onopen = () => {
        retryCount.current = 0;
        setConnectionState('connected');

        processReconnectQueue({
          queue: commandQueue,
          currentSessionId: useLemonStore.getState().sessions.activeSessionId,
          enqueueNotification,
          addPendingConfirmation,
          sendPayload: (payload) => ws.send(payload),
        });

        // Request current config state
        ws.send(JSON.stringify({ type: 'get_config' }));
      };

      ws.onmessage = (event) => {
        try {
          const parsed = JSON.parse(event.data as string) as WireServerMessage;
          applyServerMessage(parsed);
        } catch {
          setConnectionState('error', 'Failed to parse server message');
        }
      };

      ws.onerror = () => {
        setConnectionState('error', 'WebSocket error');
      };

      ws.onclose = () => {
        if (cancelled) {
          return;
        }
        setConnectionState('disconnected');
        const delay = getReconnectDelayMs(retryCount.current);
        retryCount.current += 1;
        logConnectionWarning(retryCount.current);
        reconnectTimer.current = window.setTimeout(connect, delay);
      };
    };

    connect();

    return () => {
      cancelled = true;
      if (reconnectTimer.current) {
        window.clearTimeout(reconnectTimer.current);
      }
      socketRef.current?.close();
    };
  }, [applyServerMessage, setConnectionState, enqueueNotification, addPendingConfirmation]);
}

/**
 * Confirm a pending destructive command
 * Call this from UI when user confirms/rejects a stale destructive command
 */
export function confirmQueuedCommand(meta: QueuedCommandMeta, confirmed: boolean): void {
  confirmQueuedCommandWithDeps(meta, confirmed, {
    queue: commandQueue,
    getSendCommand: () => useLemonStore.getState().sendCommand,
    removePendingConfirmation: (pendingMeta) =>
      useLemonStore.getState().removePendingConfirmation(pendingMeta),
  });
}

/**
 * Get current queue count (for use outside React components)
 */
export function getQueueCount(): number {
  return commandQueue.length;
}
