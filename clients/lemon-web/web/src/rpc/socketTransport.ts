import type { ClientCommand } from '@lemon-web/shared';
import type { QueuedCommandMeta } from './commandQueue';
import type { Notification } from '../store/useLemonStore';
import { createNotification } from '../store/notificationHelpers';

/** Number of connection failures before logging a warning */
export const CONNECTION_WARNING_THRESHOLD = 3;

interface SocketLocation {
  protocol: string;
  host: string;
}

interface WarnLogger {
  warn: (message: string) => void;
}

interface CommandQueueTransport {
  enqueue: (
    command: ClientCommand,
    sessionId: string | null,
    ttlMs: number,
    onOverflow?: (dropped: QueuedCommandMeta) => void
  ) => boolean;
  processOnReconnect: (
    currentSessionId: string | null,
    onExpired?: (commands: QueuedCommandMeta[]) => void,
    onNeedsConfirmation?: (commands: QueuedCommandMeta[]) => void
  ) => QueuedCommandMeta[];
  confirmCommand: (meta: QueuedCommandMeta, confirmed: boolean) => QueuedCommandMeta | null;
}

interface CommandSocketLike {
  send: (payload: string) => void;
  readyState: number;
}

export function buildWsUrl(
  envUrl: string | undefined = import.meta.env.VITE_LEMON_WS_URL as string | undefined,
  location: SocketLocation = window.location,
  wsToken: string | undefined = import.meta.env.VITE_LEMON_WS_TOKEN as string | undefined
): string {
  const token = wsToken?.trim();
  const appendToken = (rawUrl: string): string => {
    if (!token) {
      return rawUrl;
    }

    try {
      const parsed = new URL(rawUrl, `${location.protocol}//${location.host}`);
      if (!parsed.searchParams.has('token')) {
        parsed.searchParams.set('token', token);
      }
      return parsed.toString();
    } catch {
      const separator = rawUrl.includes('?') ? '&' : '?';
      return `${rawUrl}${separator}token=${encodeURIComponent(token)}`;
    }
  };

  if (envUrl) {
    return appendToken(envUrl);
  }

  const wsProto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return appendToken(`${wsProto}//${location.host}/ws`);
}

export function getReconnectDelayMs(retryCount: number): number {
  return Math.min(10000, 500 * Math.pow(2, retryCount));
}

export function getConnectionWarningMessage(
  retryCount: number,
  envUrl: string | undefined,
  wsUrl: string
): string | null {
  if (retryCount !== CONNECTION_WARNING_THRESHOLD) {
    return null;
  }

  if (envUrl) {
    return (
      `[LemonSocket] Failed to connect after ${retryCount} retries.\n` +
      `Using VITE_LEMON_WS_URL override: ${wsUrl}\n` +
      `Verify the WebSocket server is running and accessible.`
    );
  }

  return (
    `[LemonSocket] Failed to connect after ${retryCount} retries.\n` +
    `Using same-origin WebSocket URL: ${wsUrl}\n` +
    `If using a separate backend, set VITE_LEMON_WS_URL environment variable.`
  );
}

export function logConnectionWarning(retryCount: number, logger: WarnLogger = console): void {
  const envUrl = import.meta.env.VITE_LEMON_WS_URL as string | undefined;
  const wsUrl = buildWsUrl(envUrl);
  const message = getConnectionWarningMessage(retryCount, envUrl, wsUrl);
  if (message) {
    logger.warn(message);
  }
}

interface SendOrQueueCommandParams {
  socket: CommandSocketLike | null;
  command: ClientCommand;
  queue: Pick<CommandQueueTransport, 'enqueue'>;
  activeSessionId: string | null;
  ttlMs: number;
  enqueueNotification: (notification: Notification) => void;
  now?: () => number;
}

export function sendOrQueueCommand({
  socket,
  command,
  queue,
  activeSessionId,
  ttlMs,
  enqueueNotification,
  now = Date.now,
}: SendOrQueueCommandParams): void {
  if (socket && socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(command));
    return;
  }

  queue.enqueue(command, activeSessionId, ttlMs, (dropped) => {
    const timestamp = now();
    enqueueNotification(
      createNotification({
        idPrefix: 'queue-overflow',
        message: `Queue full: dropped oldest command "${dropped.commandType}"`,
        level: 'warn',
        now: timestamp,
      })
    );
  });
}

interface ProcessReconnectQueueParams {
  queue: Pick<CommandQueueTransport, 'processOnReconnect'>;
  currentSessionId: string | null;
  enqueueNotification: (notification: Notification) => void;
  addPendingConfirmation: (meta: QueuedCommandMeta) => void;
  sendPayload: (payload: string) => void;
  now?: () => number;
}

export function processReconnectQueue({
  queue,
  currentSessionId,
  enqueueNotification,
  addPendingConfirmation,
  sendPayload,
  now = Date.now,
}: ProcessReconnectQueueParams): void {
  const readyToSend = queue.processOnReconnect(
    currentSessionId,
    (expired) => {
      const timestamp = now();
      const count = expired.length;
      const types = [...new Set(expired.map((item) => item.commandType))].join(', ');
      enqueueNotification(
        createNotification({
          idPrefix: 'queue-expired',
          message: `${count} queued command${count > 1 ? 's' : ''} expired while disconnected: ${types}`,
          level: 'warn',
          now: timestamp,
        })
      );
    },
    (needsConfirmation) => {
      for (const meta of needsConfirmation) {
        addPendingConfirmation(meta);
      }
      if (needsConfirmation.length > 0) {
        const timestamp = now();
        enqueueNotification(
          createNotification({
            idPrefix: 'queue-confirm',
            message: `${needsConfirmation.length} destructive command${needsConfirmation.length > 1 ? 's' : ''} queued for different session - please confirm`,
            level: 'warn',
            now: timestamp,
          })
        );
      }
    }
  );

  for (const queued of readyToSend) {
    sendPayload(queued.payload);
  }

  if (readyToSend.length > 0) {
    const timestamp = now();
    enqueueNotification(
      createNotification({
        idPrefix: 'queue-sent',
        message: `Sent ${readyToSend.length} queued command${readyToSend.length > 1 ? 's' : ''}`,
        level: 'info',
        now: timestamp,
      })
    );
  }
}

interface ConfirmQueuedCommandDeps {
  queue: Pick<CommandQueueTransport, 'confirmCommand'>;
  getSendCommand: () => ((command: ClientCommand) => void) | undefined;
  removePendingConfirmation: (meta: QueuedCommandMeta) => void;
}

export function confirmQueuedCommandWithDeps(
  meta: QueuedCommandMeta,
  confirmed: boolean,
  deps: ConfirmQueuedCommandDeps
): void {
  const result = deps.queue.confirmCommand(meta, confirmed);

  if (confirmed && result) {
    const sendCommand = deps.getSendCommand();
    if (sendCommand) {
      const command = JSON.parse(result.payload) as ClientCommand;
      sendCommand(command);
    }
  }

  deps.removePendingConfirmation(meta);
}
