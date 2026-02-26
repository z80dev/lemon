import type {
  BridgeMessage,
  ClientCommand,
  RunningSessionInfo,
  WireServerMessage,
} from '@lemon-web/shared';
import type { LemonState } from './useLemonStore';
import { createNotification } from './notificationHelpers';

interface ReducerContext {
  state: LemonState;
  message: WireServerMessage;
  now: number;
  debugLog: WireServerMessage[];
  connection: LemonState['connection'];
  sendCommand?: (cmd: ClientCommand) => void;
}

export function reduceBridgeMessage({
  state,
  message,
  now,
  debugLog,
  connection,
}: ReducerContext): LemonState | null {
  if (!isBridgeMessage(message)) {
    return null;
  }

  if (message.type === 'bridge_status') {
    return {
      ...state,
      debugLog,
      connection: {
        ...connection,
        bridgeStatus: message.message ?? null,
      },
    };
  }

  if (message.type === 'bridge_error') {
    return {
      ...state,
      debugLog,
      connection: {
        ...connection,
        lastError: message.message,
      },
      notifications: [
        ...state.notifications,
        createNotification({
          idPrefix: 'bridge-error',
          message: message.message,
          level: 'error',
          now,
        }),
      ],
    };
  }

  return { ...state, debugLog, connection };
}

export function reduceCoreServerMessage({
  state,
  message,
  now,
  debugLog,
  connection,
  sendCommand,
}: ReducerContext): LemonState | null {
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
        state.sessions.activeSessionId === message.session_id ? null : state.sessions.activeSessionId;

      const messagesBySession = { ...state.messagesBySession };
      const toolExecutionsBySession = { ...state.toolExecutionsBySession };
      const statsBySession = { ...state.statsBySession };
      const insertionCounters = { ...state._insertionCounters };

      delete messagesBySession[message.session_id];
      delete toolExecutionsBySession[message.session_id];
      delete statsBySession[message.session_id];
      delete insertionCounters[message.session_id];

      return {
        ...state,
        debugLog,
        messagesBySession,
        toolExecutionsBySession,
        statsBySession,
        _insertionCounters: insertionCounters,
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
      return { ...state, debugLog, config: message.config };
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
      return {
        ...state,
        debugLog,
        notifications: [
          ...state.notifications,
          createNotification({
            idPrefix: 'save',
            message: message.ok
              ? `Session saved to ${message.path ?? 'unknown path'}`
              : `Save failed: ${message.error ?? 'unknown error'}`,
            level: message.ok ? 'success' : 'error',
            now,
          }),
        ],
      };
    }
    case 'error': {
      return {
        ...state,
        debugLog,
        notifications: [
          ...state.notifications,
          createNotification({
            idPrefix: 'error',
            message: message.message,
            level: 'error',
            now,
          }),
        ],
      };
    }
    case 'debug': {
      return {
        ...state,
        debugLog,
        notifications: [
          ...state.notifications,
          createNotification({
            idPrefix: 'debug',
            message: message.message,
            level: 'info',
            now,
          }),
        ],
      };
    }
    default:
      return null;
  }
}

function isBridgeMessage(message: WireServerMessage): message is BridgeMessage {
  return (
    message.type === 'bridge_status' ||
    message.type === 'bridge_error' ||
    message.type === 'bridge_stderr'
  );
}
