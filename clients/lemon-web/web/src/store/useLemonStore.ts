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
  SessionEvent,
  BridgeMessage,
  EventMessage,
} from '@lemon-web/shared';

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

      if (isBridgeMessage(message)) {
        if (message.type === 'bridge_status') {
          connection.bridgeStatus = message.message ?? null;
        }
        if (message.type === 'bridge_error') {
          connection.lastError = message.message;
          const note: Notification = {
            id: `bridge-error-${now}`,
            message: message.message,
            level: 'error',
            createdAt: now,
          };
          return { ...state, debugLog, connection, notifications: [...state.notifications, note] };
        }
        return { ...state, debugLog, connection };
      }

      switch (message.type) {
        case 'ready': {
          return {
            ...state,
            connection,
            debugLog,
            sessions: {
              ...state.sessions,
              activeSessionId: message.active_session_id,
              primarySessionId: message.primary_session_id,
            },
          };
        }
        case 'active_session': {
          return {
            ...state,
            debugLog,
            sessions: {
              ...state.sessions,
              activeSessionId: message.session_id,
            },
          };
        }
        case 'session_started': {
          const running = { ...state.sessions.running };
          running[message.session_id] = {
            session_id: message.session_id,
            cwd: message.cwd,
            is_streaming: false,
          };

          if (state.autoActivateNextSession && sendCommand) {
            sendCommand({ type: 'set_active_session', session_id: message.session_id });
          }

          return {
            ...state,
            debugLog,
            autoActivateNextSession: false,
            sessions: {
              ...state.sessions,
              running,
            },
          };
        }
        case 'session_closed': {
          const running = { ...state.sessions.running };
          delete running[message.session_id];
          const activeSessionId =
            state.sessions.activeSessionId === message.session_id
              ? null
              : state.sessions.activeSessionId;
          const messagesBySession = { ...state.messagesBySession };
          const toolExecutionsBySession = { ...state.toolExecutionsBySession };
          const statsBySession = { ...state.statsBySession };
          const _insertionCounters = { ...state._insertionCounters };
          delete messagesBySession[message.session_id];
          delete toolExecutionsBySession[message.session_id];
          delete statsBySession[message.session_id];
          delete _insertionCounters[message.session_id];
          return {
            ...state,
            debugLog,
            messagesBySession,
            toolExecutionsBySession,
            statsBySession,
            _insertionCounters,
            sessions: {
              ...state.sessions,
              running,
              activeSessionId,
            },
          };
        }
        case 'sessions_list': {
          return {
            ...state,
            debugLog,
            sessions: {
              ...state.sessions,
              saved: message.sessions,
            },
          };
        }
        case 'running_sessions': {
          const running: Record<string, RunningSessionInfo> = {};
          for (const session of message.sessions) {
            running[session.session_id] = session;
          }
          return {
            ...state,
            debugLog,
            sessions: {
              ...state.sessions,
              running,
            },
          };
        }
        case 'models_list': {
          return { ...state, debugLog, models: message.providers };
        }
        case 'config_state': {
          return {
            ...state,
            debugLog,
            config: message.config,
          };
        }
        case 'stats': {
          return {
            ...state,
            debugLog,
            statsBySession: {
              ...state.statsBySession,
              [message.session_id]: message.stats,
            },
          };
        }
        case 'save_result': {
          const note: Notification = {
            id: `save-${now}`,
            message: message.ok
              ? `Session saved to ${message.path ?? 'unknown path'}`
              : `Save failed: ${message.error ?? 'unknown error'}`,
            level: message.ok ? 'success' : 'error',
            createdAt: now,
          };
          return {
            ...state,
            debugLog,
            notifications: [...state.notifications, note],
          };
        }
        case 'error': {
          const note: Notification = {
            id: `error-${now}`,
            message: message.message,
            level: 'error',
            createdAt: now,
          };
          return {
            ...state,
            debugLog,
            notifications: [...state.notifications, note],
          };
        }
        case 'debug': {
          const note: Notification = {
            id: `debug-${now}`,
            message: message.message,
            level: 'info',
            createdAt: now,
          };
          return {
            ...state,
            debugLog,
            notifications: [...state.notifications, note],
          };
        }
        case 'ui_request': {
          return {
            ...state,
            debugLog,
            ui: {
              ...state.ui,
              requestsQueue: [...state.ui.requestsQueue, message],
            },
          };
        }
        default:
          break;
      }

      if (message.type === 'ui_notify') {
        const noteType = (message.params as Record<string, unknown>).notify_type;
        const fallbackType = (message.params as Record<string, unknown>).type;
        const level =
          (typeof noteType === 'string' ? noteType : undefined) ||
          (typeof fallbackType === 'string' ? fallbackType : 'info');

        const normalizedLevel = normalizeLevel(level);
        const note: Notification = {
          id: `notify-${now}`,
          message: String((message.params as Record<string, unknown>).message ?? ''),
          level: normalizedLevel,
          createdAt: now,
        };
        return {
          ...state,
          debugLog,
          notifications: [...state.notifications, note],
        };
      }

      if (message.type === 'ui_status') {
        const key = String((message.params as Record<string, unknown>).key ?? '');
        const rawText = (message.params as Record<string, unknown>).text;
        if (!key) {
          return { ...state, debugLog };
        }
        const status = { ...state.ui.status };
        if (rawText === null) {
          delete status[key];
        } else if (rawText !== undefined) {
          status[key] = String(rawText);
        }
        return {
          ...state,
          debugLog,
          ui: {
            ...state.ui,
            status,
          },
        };
      }

      if (message.type === 'ui_widget') {
        const key = String((message.params as Record<string, unknown>).key ?? '');
        const content = (message.params as Record<string, unknown>).content;
        const opts = (message.params as Record<string, unknown>).opts as Record<string, unknown>;
        if (!key) {
          return { ...state, debugLog };
        }
        if (content === null) {
          const widgets = { ...state.ui.widgets };
          delete widgets[key];
          return {
            ...state,
            debugLog,
            ui: {
              ...state.ui,
              widgets,
            },
          };
        }
        return {
          ...state,
          debugLog,
          ui: {
            ...state.ui,
            widgets: {
              ...state.ui.widgets,
              [key]: { key, content, opts },
            },
          },
        };
      }

      if (message.type === 'ui_working') {
        const workingMessage = (message.params as Record<string, unknown>).message ?? null;
        return {
          ...state,
          debugLog,
          ui: {
            ...state.ui,
            workingMessage: workingMessage ? String(workingMessage) : null,
          },
        };
      }

      if (message.type === 'ui_set_title') {
        const title = String((message.params as Record<string, unknown>).title ?? 'Lemon');
        return {
          ...state,
          debugLog,
          ui: {
            ...state.ui,
            title,
          },
        };
      }

      if (message.type === 'ui_set_editor_text') {
        const text = String((message.params as Record<string, unknown>).text ?? '');
        return {
          ...state,
          debugLog,
          ui: {
            ...state.ui,
            editorText: text,
          },
        };
      }

      if (message.type === 'event') {
        const eventMsg = message as EventMessage;
        const updated = applySessionEvent(state, eventMsg.session_id, eventMsg.event, eventMsg.event_seq);
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

function isBridgeMessage(message: WireServerMessage): message is BridgeMessage {
  return (
    message.type === 'bridge_status' ||
    message.type === 'bridge_error' ||
    message.type === 'bridge_stderr'
  );
}

function normalizeLevel(level: string): Notification['level'] {
  switch (level) {
    case 'success':
      return 'success';
    case 'warn':
    case 'warning':
      return 'warn';
    case 'error':
      return 'error';
    default:
      return 'info';
  }
}

function applySessionEvent(state: LemonState, sessionId: string, event: SessionEvent, eventSeq?: number) {
  const messagesBySession = { ...state.messagesBySession };
  const toolExecutionsBySession = { ...state.toolExecutionsBySession };
  const statsBySession = { ...state.statsBySession };
  const _insertionCounters = { ...state._insertionCounters };

  const messages: MessageWithMeta[] = [...(messagesBySession[sessionId] ?? [])];

  // Get next insertion index for this session
  const getNextInsertionIndex = (): number => {
    const current = _insertionCounters[sessionId] ?? 0;
    _insertionCounters[sessionId] = current + 1;
    return current;
  };

  switch (event.type) {
    case 'agent_end': {
      const newMessages = (event.data?.[0] as Message[]) ?? [];
      const merged: MessageWithMeta[] = [...messages];
      for (const msg of newMessages) {
        const msgWithMeta: MessageWithMeta = {
          ...msg,
          _event_seq: eventSeq,
          _insertionIndex: getNextInsertionIndex(),
        };
        upsertMessage(merged, msgWithMeta);
      }
      messagesBySession[sessionId] = sortMessages(merged);
      break;
    }
    case 'message_start':
    case 'message_update':
    case 'message_end': {
      const msg = (event.data?.[0] as Message | undefined) ?? null;
      if (msg) {
        const msgWithMeta: MessageWithMeta = {
          ...msg,
          _event_seq: eventSeq,
          _insertionIndex: getNextInsertionIndex(),
        };
        upsertMessage(messages, msgWithMeta);
        messagesBySession[sessionId] = sortMessages(messages);
      }
      break;
    }
    case 'turn_end': {
      const msg = (event.data?.[0] as Message | undefined) ?? null;
      if (msg) {
        const msgWithMeta: MessageWithMeta = {
          ...msg,
          _event_seq: eventSeq,
          _insertionIndex: getNextInsertionIndex(),
        };
        upsertMessage(messages, msgWithMeta);
        messagesBySession[sessionId] = sortMessages(messages);
      }
      break;
    }
    case 'tool_execution_start': {
      const [id, name, args] = (event.data ?? []) as [string, string, Record<string, unknown>];
      const map = { ...(toolExecutionsBySession[sessionId] ?? {}) };
      map[id] = {
        id,
        name,
        args,
        status: 'running',
        startedAt: Date.now(),
        updatedAt: Date.now(),
      };
      toolExecutionsBySession[sessionId] = map;
      break;
    }
    case 'tool_execution_update': {
      const [id, name, args, partial] = (event.data ?? []) as [
        string,
        string,
        Record<string, unknown>,
        unknown,
      ];
      const map = { ...(toolExecutionsBySession[sessionId] ?? {}) };
      const existing = map[id];
      map[id] = {
        id,
        name,
        args,
        status: existing?.status ?? 'running',
        partial,
        result: existing?.result,
        startedAt: existing?.startedAt ?? Date.now(),
        updatedAt: Date.now(),
      };
      toolExecutionsBySession[sessionId] = map;
      break;
    }
    case 'tool_execution_end': {
      const [id, name, result, isError] = (event.data ?? []) as [string, string, unknown, boolean];
      const map = { ...(toolExecutionsBySession[sessionId] ?? {}) };
      const existing = map[id];
      map[id] = {
        id,
        name,
        args: existing?.args ?? null,
        status: isError ? 'error' : 'complete',
        partial: existing?.partial,
        result,
        startedAt: existing?.startedAt ?? Date.now(),
        updatedAt: Date.now(),
        endedAt: Date.now(),
      };
      toolExecutionsBySession[sessionId] = map;
      break;
    }
    case 'error': {
      const reason = String((event.data?.[0] as string | undefined) ?? 'unknown error');
      const note: Notification = {
        id: `session-error-${Date.now()}`,
        message: `Session ${sessionId}: ${reason}`,
        level: 'error',
        createdAt: Date.now(),
      };
      return {
        messagesBySession,
        toolExecutionsBySession,
        statsBySession,
        _insertionCounters,
        notifications: [...state.notifications, note],
      };
    }
    default:
      break;
  }

  return { messagesBySession, toolExecutionsBySession, statsBySession, _insertionCounters };
}

function upsertMessage(messages: MessageWithMeta[], msg: MessageWithMeta): void {
  const key = messageKey(msg);
  const existingIndex = messages.findIndex((existing) => messageKey(existing) === key);
  if (existingIndex >= 0) {
    // Preserve the original insertion index when updating
    const existingMeta = messages[existingIndex];
    messages[existingIndex] = {
      ...msg,
      _insertionIndex: existingMeta._insertionIndex,
      // Keep earliest event_seq if we're updating an existing message
      _event_seq: existingMeta._event_seq ?? msg._event_seq,
    };
  } else {
    messages.push(msg);
  }
}

/**
 * Generate a stable key for a message that combines:
 * - event_seq (if present) for server-side ordering
 * - role and tool_call_id for uniqueness
 * - timestamp as fallback
 */
function messageKey(msg: MessageWithMeta): string {
  const meta = msg as MessageWithMeta;
  const seqPart = meta._event_seq !== undefined ? `seq:${meta._event_seq}:` : '';

  if (msg.role === 'tool_result') {
    // Tool results are uniquely identified by their tool_call_id
    return `${seqPart}tool:${msg.tool_call_id}`;
  }
  // For user/assistant messages, use role + timestamp
  // The timestamp should be unique per message from the server
  return `${seqPart}${msg.role}:${msg.timestamp}`;
}

/**
 * Sort messages for stable display ordering.
 * Primary sort: event_seq (if present) - monotonic server order
 * Secondary sort: timestamp
 * Tertiary sort: insertion index (for messages with same timestamp)
 */
function sortMessages(messages: MessageWithMeta[]): MessageWithMeta[] {
  return [...messages].sort((a, b) => {
    // First, sort by event_seq if both have it
    if (a._event_seq !== undefined && b._event_seq !== undefined) {
      if (a._event_seq !== b._event_seq) {
        return a._event_seq - b._event_seq;
      }
    }
    // If only one has event_seq, it should come after messages without
    // (messages without event_seq are likely from older protocol)
    if (a._event_seq !== undefined && b._event_seq === undefined) {
      return 1;
    }
    if (a._event_seq === undefined && b._event_seq !== undefined) {
      return -1;
    }

    // Fall back to timestamp comparison
    if (a.timestamp !== b.timestamp) {
      return a.timestamp - b.timestamp;
    }

    // Finally, use insertion index for deterministic ordering
    return a._insertionIndex - b._insertionIndex;
  });
}

/**
 * Generate a stable React key for a message.
 * Uses event_seq + role + tool_call_id/timestamp to ensure uniqueness
 * and avoid key collisions even when messages arrive out of order.
 */
export function getMessageKey(msg: MessageWithMeta): string {
  const seqPart = msg._event_seq !== undefined ? `${msg._event_seq}-` : '';
  const indexPart = `-${msg._insertionIndex}`;

  if (msg.role === 'tool_result') {
    return `${seqPart}tool-${msg.tool_call_id}${indexPart}`;
  }
  return `${seqPart}${msg.role}-${msg.timestamp}${indexPart}`;
}
