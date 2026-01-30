import { useMemo } from 'react';
import { useLemonStore } from '../store/useLemonStore';

export function StatusBar() {
  const statusMap = useLemonStore((state) => state.ui.status);
  const activeSessionId = useLemonStore((state) => state.sessions.activeSessionId);
  const stats = useLemonStore((state) =>
    activeSessionId ? state.statsBySession[activeSessionId] : undefined
  );

  const statusEntries = useMemo(() => Object.entries(statusMap), [statusMap]);

  return (
    <div className="status-bar">
      <div className="status-bar__section">
        <span className="status-label">Status</span>
        {statusEntries.length === 0 ? (
          <span className="muted">No status updates yet.</span>
        ) : (
          statusEntries.map(([key, value]) => (
            <span key={key} className="status-pill">
              {key}: {value}
            </span>
          ))
        )}
      </div>
      {stats ? (
        <div className="status-bar__section">
          <span className="status-pill">Turns: {stats.turn_count}</span>
          <span className="status-pill">Messages: {stats.message_count}</span>
          <span className="status-pill">CWD: {stats.cwd}</span>
        </div>
      ) : null}
    </div>
  );
}
