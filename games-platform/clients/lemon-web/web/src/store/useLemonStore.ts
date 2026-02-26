import { create } from 'zustand';
import type {
  WireServerMessage,
  ClientCommand,
  SessionStats,
  SessionSummary,
  RunningSessionInfo,
  ModelsListMessage,
  UIRequestMessage,
  Message,
} from '@lemon-web/shared';
import { reduceSessionEvent, getMessageReactKey } from './sessionEventReducer';
import { reduceBridgeMessage, reduceCoreServerMessage } from './serverMessageReducer';
import { routeUiMessage } from './uiMessageRouter';

/**
 * Extended message type with ordering metadata for stable display.
 * event_seq: Monotonic sequence from server (if present)
 * _insertionIndex: Local insertion order as fallback
 */
export type MessageWithMeta = Message & {
  _event_seq?: number;
  _insertionIndex: number;
};

export type ConnectionState = 'connecting' | 'connected' | 'disconnected' | 'error';

export interface Notification {
  id: string;
  message: string;
  level: 'info' | 'success' | 'warn' | 'error';
  createdAt: number;
}

export interface ToolExecution {
  id: string;
  name: string;
  args: Record<string, unknown> | null;
  status: 'running' | 'complete' | 'error';
  partial?: unknown;
  result?: unknown;
  startedAt: number;
  updatedAt: number;
  endedAt?: number;
}

export interface WidgetState {
  key: string;
  content: unknown;
  opts?: Record<string, unknown>;
}

/** Metadata for a queued command pending confirmation */
export interface PendingCommandConfirmation {
  /** Original command payload (JSON string) */
  payload: string;
  /** Timestamp when command was queued */
  enqueuedAt: number;
  /** TTL in milliseconds */
  ttlMs: number;
  /** Session ID that was active when command was queued */
  sessionIdAtEnqueue: string | null;
  /** Parsed command type for quick access */
  commandType: string;
}

/** Queue state for UI display */
export interface QueueState {
  /** Number of commands currently queued */
  count: number;
  /** Commands pending user confirmation (destructive commands with session change) */
  pendingConfirmations: PendingCommandConfirmation[];
}

export interface RuntimeConfig {
  claude_skip_permissions: boolean;
  codex_auto_approve: boolean;
}

export interface LemonState {
  connection: {
    state: ConnectionState;
    lastError?: string | null;
    lastServerTime?: number;
    bridgeStatus?: string | null;
  };
  sendCommand?: (cmd: ClientCommand) => void;
  setSendCommand: (fn: (cmd: ClientCommand) => void) => void;
  setConnectionState: (state: ConnectionState, error?: string | null) => void;

  config: RuntimeConfig;
  setConfig: (key: keyof RuntimeConfig, value: boolean) => void;

  sessions: {
    running: Record<string, RunningSessionInfo>;
    saved: SessionSummary[];
    activeSessionId: string | null;
    primarySessionId: string | null;
  };
  statsBySession: Record<string, SessionStats>;
  models: ModelsListMessage['providers'];

  messagesBySession: Record<string, MessageWithMeta[]>;
  toolExecutionsBySession: Record<string, Record<string, ToolExecution>>;
  /** Tracks next insertion index per session for stable ordering fallback */
  _insertionCounters: Record<string, number>;

  ui: {
    requestsQueue: UIRequestMessage[];
    status: Record<string, string>;
    widgets: Record<string, WidgetState>;
    workingMessage: string | null;
    title: string | null;
    editorText: string;
  };

  notifications: Notification[];
  debugLog: WireServerMessage[];

  /** Queue state for offline command handling */
  queue: QueueState;

  autoActivateNextSession: boolean;
  setAutoActivateNextSession: (value: boolean) => void;

  applyServerMessage: (message: WireServerMessage) => void;
  enqueueNotification: (note: Notification) => void;
  dismissNotification: (id: string) => void;
  send: (cmd: ClientCommand) => void;
  dequeueUIRequest: () => void;

  /** Queue management actions */
  setQueueCount: (count: number) => void;
  addPendingConfirmation: (meta: PendingCommandConfirmation) => void;
  removePendingConfirmation: (meta: PendingCommandConfirmation) => void;
  clearPendingConfirmations: () => void;
}

const MAX_DEBUG_LOG = 200;

export const useLemonStore = create<LemonState>((set, get) => ({
  connection: {
    state: 'connecting',
    lastError: null,
    lastServerTime: undefined,
    bridgeStatus: null,
  },
  sendCommand: undefined,
  setSendCommand: (fn) => set({ sendCommand: fn }),
  setConnectionState: (state, error) =>
    set((current) => ({
      connection: {
        ...current.connection,
        state,
        lastError: error ?? null,
      },
    })),

  config: {
    claude_skip_permissions: true,
    codex_auto_approve: false,
  },
  setConfig: (key, value) => {
    const sendCommand = get().sendCommand;
    if (sendCommand) {
      sendCommand({ type: 'set_config', key, value });
    }
    set((current) => ({
      config: {
        ...current.config,
        [key]: value,
      },
    }));
  },

  sessions: {
    running: {},
    saved: [],
    activeSessionId: null,
    primarySessionId: null,
  },
  statsBySession: {},
  models: [],

  messagesBySession: {},
  toolExecutionsBySession: {},
  _insertionCounters: {},

  ui: {
    requestsQueue: [],
    status: {},
    widgets: {},
    workingMessage: null,
    title: null,
    editorText: '',
  },

  notifications: [],
  debugLog: [],

  queue: {
    count: 0,
    pendingConfirmations: [],
  },

  autoActivateNextSession: false,
  setAutoActivateNextSession: (value) => set({ autoActivateNextSession: value }),

  applyServerMessage: (message) => {
    const now = Date.now();
    const sendCommand = get().sendCommand;

    set((state) => {
      const debugLog = [...state.debugLog, message].slice(-MAX_DEBUG_LOG);
      const connection = {
        ...state.connection,
        lastServerTime: message.server_time ?? state.connection.lastServerTime,
      };

      const bridgeUpdate = reduceBridgeMessage({
        state,
        message,
        now,
        debugLog,
        connection,
        sendCommand,
      });
      if (bridgeUpdate) {
        return bridgeUpdate;
      }

      const coreUpdate = reduceCoreServerMessage({
        state,
        message,
        now,
        debugLog,
        connection,
        sendCommand,
      });
      if (coreUpdate) {
        return coreUpdate;
      }

      const uiUpdate = routeUiMessage({ state, message, debugLog, now });
      if (uiUpdate) {
        return uiUpdate;
      }

      if (message.type === 'event') {
        const updated = reduceSessionEvent(
          state,
          message.session_id,
          message.event,
          message.event_seq,
          now
        );
        return {
          ...state,
          debugLog,
          ...updated,
        };
      }

      return { ...state, debugLog };
    });
  },

  enqueueNotification: (note) =>
    set((state) => ({ notifications: [...state.notifications, note] })),

  dismissNotification: (id) =>
    set((state) => ({
      notifications: state.notifications.filter((note) => note.id !== id),
    })),

  send: (cmd) => {
    const sendCommand = get().sendCommand;
    if (!sendCommand) {
      return;
    }
    sendCommand(cmd);
  },

  dequeueUIRequest: () =>
    set((state) => ({
      ui: {
        ...state.ui,
        requestsQueue: state.ui.requestsQueue.slice(1),
      },
    })),

  setQueueCount: (count) =>
    set((state) => ({
      queue: {
        ...state.queue,
        count,
      },
    })),

  addPendingConfirmation: (meta) =>
    set((state) => ({
      queue: {
        ...state.queue,
        pendingConfirmations: [...state.queue.pendingConfirmations, meta],
      },
    })),

  removePendingConfirmation: (meta) =>
    set((state) => ({
      queue: {
        ...state.queue,
        pendingConfirmations: state.queue.pendingConfirmations.filter(
          (m) => m.payload !== meta.payload || m.enqueuedAt !== meta.enqueuedAt
        ),
      },
    })),

  clearPendingConfirmations: () =>
    set((state) => ({
      queue: {
        ...state.queue,
        pendingConfirmations: [],
      },
    })),
}));

/**
 * Generate a stable React key for a message.
 * Uses event_seq + role + tool_call_id/timestamp to ensure uniqueness
 * and avoid key collisions even when messages arrive out of order.
 */
export function getMessageKey(msg: MessageWithMeta): string {
  return getMessageReactKey(msg);
}
