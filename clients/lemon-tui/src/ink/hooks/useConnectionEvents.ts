/**
 * Hook to wire AgentConnection events to StateStore.
 */

import { useEffect, useRef } from 'react';
import type { AgentConnection } from '../../agent-connection.js';
import type { StateStore } from '../../state.js';
import type {
  ServerMessage,
  UIRequestMessage,
  SessionSummary,
  RunningSessionInfo,
} from '../../types.js';
import type { NormalizedAssistantMessage } from '../../state.js';

export interface ConnectionEventHandlers {
  onUIRequest: (request: UIRequestMessage) => void;
  onUINotify: (params: { message: string; notify_type?: string }) => void;
  onSessionsList: (msg: { sessions: SessionSummary[]; error?: string }) => void;
  onSaveResult: (msg: { ok: boolean; path?: string; error?: string }) => void;
  onSessionStarted: (msg: { session_id: string; cwd: string; model: { provider: string; id: string } }) => void;
  onSessionClosed: (msg: { session_id: string; reason: string }) => void;
  onRunningSessions: (msg: { sessions: RunningSessionInfo[]; error?: string | null }) => void;
  onModelsList: (msg: { providers: Array<{ id: string; models: Array<{ id: string; name?: string }> }>; error?: string | null }) => void;
  onActiveSession: (msg: { session_id: string | null }) => void;
  onSetEditorText: (text: string) => void;
  onClose: (code: number) => void;
  onReady: () => void;
}

export function useConnectionEvents(
  connection: AgentConnection,
  store: StateStore,
  handlers: ConnectionEventHandlers
): void {
  const handlersRef = useRef(handlers);
  handlersRef.current = handlers;

  useEffect(() => {
    const onReady = (msg: { cwd: string; model: { provider: string; id: string }; ui: boolean; debug: boolean; primary_session_id: string | null; active_session_id: string | null }) => {
      store.setReady(msg.cwd, msg.model, msg.ui, msg.debug, msg.primary_session_id, msg.active_session_id);
      handlersRef.current.onReady();
      connection.listRunningSessions();
    };

    const onMessage = (msg: ServerMessage) => {
      switch (msg.type) {
        case 'event':
          store.handleEvent(msg.event, msg.session_id);
          break;

        case 'stats':
          store.setStats(msg.stats, msg.session_id);
          break;

        case 'error':
          store.setError(msg.session_id ? `[${msg.session_id}] ${msg.message}` : msg.message);
          break;

        case 'ui_request':
          handlersRef.current.onUIRequest(msg);
          break;

        case 'ui_notify':
          handlersRef.current.onUINotify(msg.params as { message: string; notify_type?: string });
          break;

        case 'ui_status': {
          const statusParams = msg.params as { key: string; text: string | null };
          store.setStatus(statusParams.key, statusParams.text);
          break;
        }

        case 'ui_working':
          store.setAgentWorkingMessage((msg.params as { message: string | null }).message);
          break;

        case 'ui_set_title':
          store.setTitle((msg.params as { title: string }).title);
          break;

        case 'ui_set_editor_text':
          handlersRef.current.onSetEditorText((msg.params as { text: string }).text || '');
          break;

        case 'ui_widget': {
          const widgetParams = msg.params as { key: string; content: string | string[] | null; opts?: Record<string, unknown> };
          store.setWidget(widgetParams.key, widgetParams.content, widgetParams.opts || {});
          break;
        }

        case 'save_result':
          handlersRef.current.onSaveResult(msg as { ok: boolean; path?: string; error?: string });
          break;

        case 'sessions_list':
          handlersRef.current.onSessionsList(msg as { sessions: SessionSummary[]; error?: string });
          break;

        case 'session_started':
          handlersRef.current.onSessionStarted(msg);
          break;

        case 'session_closed':
          handlersRef.current.onSessionClosed(msg as { session_id: string; reason: string });
          break;

        case 'running_sessions':
          handlersRef.current.onRunningSessions(msg as { sessions: RunningSessionInfo[]; error?: string | null });
          break;

        case 'models_list':
          handlersRef.current.onModelsList(msg as { providers: Array<{ id: string; models: Array<{ id: string; name?: string }> }>; error?: string | null });
          break;

        case 'active_session':
          handlersRef.current.onActiveSession(msg as { session_id: string | null });
          break;

        case 'debug':
          if (store.getState().debug) {
            const debugMsg = msg as { message: string };
            handlersRef.current.onUINotify({ message: `[debug] ${debugMsg.message}`, notify_type: 'info' });
          }
          break;
      }
    };

    const onError = (err: Error) => {
      store.setError(err.message);
    };

    const onClose = (code: number | null) => {
      handlersRef.current.onClose(code ?? 0);
    };

    connection.on('ready', onReady);
    connection.on('message', onMessage);
    connection.on('error', onError);
    connection.on('close', onClose as any);

    return () => {
      connection.removeListener('ready', onReady);
      connection.removeListener('message', onMessage);
      connection.removeListener('error', onError);
      connection.removeListener('close', onClose as any);
    };
  }, [connection, store]);
}
