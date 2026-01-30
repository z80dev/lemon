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
} from '@lemon-web/shared';

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

  sessions: {
    running: Record<string, RunningSessionInfo>;
    saved: SessionSummary[];
    activeSessionId: string | null;
    primarySessionId: string | null;
  };
  statsBySession: Record<string, SessionStats>;
  models: ModelsListMessage['providers'];

  messagesBySession: Record<string, Message[]>;
  toolExecutionsBySession: Record<string, Record<string, ToolExecution>>;

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

  autoActivateNextSession: boolean;
  setAutoActivateNextSession: (value: boolean) => void;

  applyServerMessage: (message: WireServerMessage) => void;
  enqueueNotification: (note: Notification) => void;
  dismissNotification: (id: string) => void;
  send: (cmd: ClientCommand) => void;
  dequeueUIRequest: () => void;
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
          delete messagesBySession[message.session_id];
          delete toolExecutionsBySession[message.session_id];
          delete statsBySession[message.session_id];
          return {
            ...state,
            debugLog,
            messagesBySession,
            toolExecutionsBySession,
            statsBySession,
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
        const updated = applySessionEvent(state, message.session_id, message.event);
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

function applySessionEvent(state: LemonState, sessionId: string, event: SessionEvent) {
  const messagesBySession = { ...state.messagesBySession };
  const toolExecutionsBySession = { ...state.toolExecutionsBySession };
  const statsBySession = { ...state.statsBySession };

  const messages = [...(messagesBySession[sessionId] ?? [])];

  switch (event.type) {
    case 'agent_end': {
      const newMessages = (event.data?.[0] as Message[]) ?? [];
      const merged = [...messages];
      for (const msg of newMessages) {
        upsertMessage(merged, msg);
      }
      messagesBySession[sessionId] = merged;
      break;
    }
    case 'message_start':
    case 'message_update':
    case 'message_end': {
      const msg = (event.data?.[0] as Message | undefined) ?? null;
      if (msg) {
        upsertMessage(messages, msg);
        messagesBySession[sessionId] = messages;
      }
      break;
    }
    case 'turn_end': {
      const msg = (event.data?.[0] as Message | undefined) ?? null;
      if (msg) {
        upsertMessage(messages, msg);
        messagesBySession[sessionId] = messages;
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
        notifications: [...state.notifications, note],
      };
    }
    default:
      break;
  }

  return { messagesBySession, toolExecutionsBySession, statsBySession };
}

function upsertMessage(messages: Message[], msg: Message): void {
  const key = messageKey(msg);
  const existingIndex = messages.findIndex((existing) => messageKey(existing) === key);
  if (existingIndex >= 0) {
    messages[existingIndex] = msg;
  } else {
    messages.push(msg);
  }
}

function messageKey(msg: Message): string {
  if (msg.role === 'tool_result') {
    return `tool:${msg.tool_call_id}:${msg.timestamp}`;
  }
  return `${msg.role}:${msg.timestamp}`;
}
