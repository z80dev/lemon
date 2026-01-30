import { useMemo } from 'react';
import { useLemonStore } from '../store/useLemonStore';

export function TopBar() {
  const title = useLemonStore((state) => state.ui.title);
  const connection = useLemonStore((state) => state.connection);
  const activeSessionId = useLemonStore((state) => state.sessions.activeSessionId);
  const stats = useLemonStore((state) =>
    activeSessionId ? state.statsBySession[activeSessionId] : undefined
  );
  const send = useLemonStore((state) => state.send);

  const connectionLabel = useMemo(() => {
    switch (connection.state) {
      case 'connected':
        return 'Connected';
      case 'connecting':
        return 'Connecting…';
      case 'disconnected':
        return 'Disconnected';
      case 'error':
        return 'Error';
      default:
        return 'Unknown';
    }
  }, [connection.state]);

  return (
    <header className="top-bar">
      <div className="top-bar__left">
        <div className="app-title">
          <span className="app-title__badge">Lemon</span>
          <span className="app-title__text">{title ?? 'Lemon Web UI'}</span>
        </div>
        <div className={`connection-pill connection-pill--${connection.state}`}>
          <span className="dot" />
          {connectionLabel}
        </div>
        {connection.bridgeStatus ? (
          <span className="bridge-status">{connection.bridgeStatus}</span>
        ) : null}
        {connection.lastError ? (
          <span className="bridge-status bridge-status--error">{connection.lastError}</span>
        ) : null}
      </div>
      <div className="top-bar__center">
        <div className="session-meta">
          <span className="session-meta__label">Active Session</span>
          <span className="session-meta__value">{activeSessionId ?? 'None'}</span>
        </div>
        {stats ? (
          <div className="session-meta">
            <span className="session-meta__label">Model</span>
            <span className="session-meta__value">
              {stats.model.provider}:{stats.model.id}
            </span>
          </div>
        ) : null}
        {stats ? (
          <div className="session-meta">
            <span className="session-meta__label">Streaming</span>
            <span className="session-meta__value">
              {stats.is_streaming ? 'Yes' : 'No'}
            </span>
          </div>
        ) : null}
      </div>
      <div className="top-bar__right">
        <button
          className="pill-button"
          type="button"
          onClick={() => send({ type: 'ping' })}
        >
          Ping
        </button>
        <button
          className="pill-button"
          type="button"
          onClick={() => send({ type: 'debug' })}
        >
          Debug
        </button>
        <button
          className="pill-button"
          type="button"
          onClick={() => send({ type: 'stats', session_id: activeSessionId ?? undefined })}
          disabled={!activeSessionId}
        >
          Stats
        </button>
        <button
          className="pill-button pill-button--warn"
          type="button"
          onClick={() => send({ type: 'abort', session_id: activeSessionId ?? undefined })}
          disabled={!activeSessionId}
        >
          Abort
        </button>
        <button
          className="pill-button"
          type="button"
          onClick={() => send({ type: 'reset', session_id: activeSessionId ?? undefined })}
          disabled={!activeSessionId}
        >
          Reset
        </button>
        <button
          className="pill-button"
          type="button"
          onClick={() => send({ type: 'save', session_id: activeSessionId ?? undefined })}
          disabled={!activeSessionId}
        >
          Save
        </button>
      </div>
    </header>
  );
}
