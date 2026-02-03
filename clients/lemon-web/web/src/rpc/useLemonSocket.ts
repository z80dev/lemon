import { useCallback, useEffect, useRef } from 'react';
import type { ClientCommand, WireServerMessage } from '@lemon-web/shared';
import { useLemonStore } from '../store/useLemonStore';
import {
  commandQueue,
  type QueuedCommandMeta,
  DEFAULT_COMMAND_TTL_MS,
} from './commandQueue';

/** Number of connection failures before logging a warning */
const CONNECTION_WARNING_THRESHOLD = 3;

function buildWsUrl(): string {
  // Allow explicit override via environment variable for custom deployments
  const envUrl = import.meta.env.VITE_LEMON_WS_URL as string | undefined;
  if (envUrl) {
    return envUrl;
  }

  // Default: use same-origin WebSocket connection
  // This works when the UI is served by the same server handling WebSocket connections
  const { protocol, host } = window.location;
  const wsProto = protocol === 'https:' ? 'wss:' : 'ws:';
  return `${wsProto}//${host}/ws`;
}

function logConnectionWarning(retryCount: number): void {
  if (retryCount === CONNECTION_WARNING_THRESHOLD) {
    const envUrl = import.meta.env.VITE_LEMON_WS_URL as string | undefined;
    const wsUrl = buildWsUrl();

    if (envUrl) {
      console.warn(
        `[LemonSocket] Failed to connect after ${retryCount} retries.\n` +
          `Using VITE_LEMON_WS_URL override: ${wsUrl}\n` +
          `Verify the WebSocket server is running and accessible.`
      );
    } else {
      console.warn(
        `[LemonSocket] Failed to connect after ${retryCount} retries.\n` +
          `Using same-origin WebSocket URL: ${wsUrl}\n` +
          `If using a separate backend, set VITE_LEMON_WS_URL environment variable.`
      );
    }
  }
}

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
      if (socketRef.current && socketRef.current.readyState === WebSocket.OPEN) {
        socketRef.current.send(JSON.stringify(command));
      } else {
        // Get current active session ID for tagging
        const activeSessionId = useLemonStore.getState().sessions.activeSessionId;

        // Enqueue with metadata
        commandQueue.enqueue(command, activeSessionId, DEFAULT_COMMAND_TTL_MS, (dropped) => {
          // Notify about dropped command due to queue overflow
          enqueueNotification({
            id: `queue-overflow-${Date.now()}`,
            message: `Queue full: dropped oldest command "${dropped.commandType}"`,
            level: 'warn',
            createdAt: Date.now(),
          });
        });
      }
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

        // Get current session ID for reconnect processing
        const currentSessionId = useLemonStore.getState().sessions.activeSessionId;

        // Process queued commands on reconnect
        const readyToSend = commandQueue.processOnReconnect(
          currentSessionId,
          // Handle expired commands
          (expired) => {
            const count = expired.length;
            const types = [...new Set(expired.map((e) => e.commandType))].join(', ');
            enqueueNotification({
              id: `queue-expired-${Date.now()}`,
              message: `${count} queued command${count > 1 ? 's' : ''} expired while disconnected: ${types}`,
              level: 'warn',
              createdAt: Date.now(),
            });
          },
          // Handle commands needing confirmation
          (needsConfirmation) => {
            for (const meta of needsConfirmation) {
              addPendingConfirmation(meta);
            }
            if (needsConfirmation.length > 0) {
              enqueueNotification({
                id: `queue-confirm-${Date.now()}`,
                message: `${needsConfirmation.length} destructive command${needsConfirmation.length > 1 ? 's' : ''} queued for different session - please confirm`,
                level: 'warn',
                createdAt: Date.now(),
              });
            }
          }
        );

        // Send ready commands
        for (const meta of readyToSend) {
          ws.send(meta.payload);
        }

        // Notify if commands were sent from queue
        if (readyToSend.length > 0) {
          enqueueNotification({
            id: `queue-sent-${Date.now()}`,
            message: `Sent ${readyToSend.length} queued command${readyToSend.length > 1 ? 's' : ''}`,
            level: 'info',
            createdAt: Date.now(),
          });
        }

        // Request current config state
        ws.send(JSON.stringify({ type: 'get_config' }));
      };

      ws.onmessage = (event) => {
        try {
          const parsed = JSON.parse(event.data as string) as WireServerMessage;
          applyServerMessage(parsed);
        } catch (err) {
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
        const delay = Math.min(10000, 500 * Math.pow(2, retryCount.current));
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
  const result = commandQueue.confirmCommand(meta, confirmed);

  if (confirmed && result) {
    // Send the command if confirmed
    const sendCommand = useLemonStore.getState().sendCommand;
    if (sendCommand) {
      const command = JSON.parse(result.payload) as ClientCommand;
      sendCommand(command);
    }
  }

  // Remove from pending confirmations in store
  useLemonStore.getState().removePendingConfirmation(meta);
}

/**
 * Get current queue count (for use outside React components)
 */
export function getQueueCount(): number {
  return commandQueue.length;
}
