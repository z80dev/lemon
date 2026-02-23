import { useMemo, useState } from 'react';
import { useMonitoringStore } from '../../store/monitoringStore';
import type { MonitoringSession } from '../../../../shared/src/monitoringTypes';

function formatRelativeTime(ms: number | null): string {
  if (ms == null) return '--';
  const diff = Date.now() - ms;
  if (diff < 60_000) return `${Math.floor(diff / 1000)}s ago`;
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
  return `${Math.floor(diff / 86_400_000)}d ago`;
}

function truncate(str: string, max: number): string {
  if (str.length <= max) return str;
  return str.slice(0, max - 1) + '\u2026';
}

export function SessionsExplorer() {
  const activeSessions = useMonitoringStore((s) => s.sessions.active);
  const historicalSessions = useMonitoringStore((s) => s.sessions.historical);
  const selectedSessionKey = useMonitoringStore((s) => s.ui.selectedSessionKey);
  const setSelectedSession = useMonitoringStore((s) => s.setSelectedSession);

  const [searchQuery, setSearchQuery] = useState('');
  const [showAll, setShowAll] = useState(false);

  const allSessions = useMemo<MonitoringSession[]>(() => {
    const active = Object.values(activeSessions);
    if (!showAll) return active.sort((a, b) => (b.updatedAtMs ?? 0) - (a.updatedAtMs ?? 0));
    // Merge active + historical, dedup by sessionKey
    const map = new Map<string, MonitoringSession>();
    for (const s of historicalSessions) map.set(s.sessionKey, s);
    for (const s of active) map.set(s.sessionKey, s); // active overrides
    return Array.from(map.values()).sort((a, b) => (b.updatedAtMs ?? 0) - (a.updatedAtMs ?? 0));
  }, [activeSessions, historicalSessions, showAll]);

  const filteredSessions = useMemo(() => {
    if (!searchQuery.trim()) return allSessions;
    const q = searchQuery.toLowerCase();
    return allSessions.filter(
      (s) =>
        s.sessionKey.toLowerCase().includes(q) ||
        (s.agentId?.toLowerCase().includes(q) ?? false) ||
        (s.peerId?.toLowerCase().includes(q) ?? false)
    );
  }, [allSessions, searchQuery]);

  const inputStyle: React.CSSProperties = {
    background: '#1a1a1a',
    border: '1px solid #333',
    borderRadius: '3px',
    color: '#e0e0e0',
    fontFamily: 'monospace',
    fontSize: '11px',
    padding: '4px 8px',
    outline: 'none',
    width: '240px',
  };

  const toggleStyle = (isActive: boolean): React.CSSProperties => ({
    padding: '3px 8px',
    border: '1px solid #333',
    borderRadius: '3px',
    background: isActive ? '#003322' : 'transparent',
    color: isActive ? '#00ff88' : '#888',
    fontFamily: 'monospace',
    fontSize: '10px',
    cursor: 'pointer',
  });

  return (
    <div data-testid="sessions-explorer" style={{ fontFamily: 'monospace', fontSize: '11px', color: '#e0e0e0' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '12px' }}>
        <span style={{ fontWeight: 'bold', fontSize: '13px' }}>Sessions</span>
        <input
          data-testid="session-search"
          placeholder="Search sessions..."
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          style={inputStyle}
        />
        <button type="button" style={toggleStyle(!showAll)} onClick={() => setShowAll(false)}>
          Active
        </button>
        <button type="button" style={toggleStyle(showAll)} onClick={() => setShowAll(true)}>
          All
        </button>
        <span style={{ color: '#666', marginLeft: '8px' }}>
          {filteredSessions.length} result{filteredSessions.length !== 1 ? 's' : ''}
        </span>
      </div>

      {/* Table */}
      <div style={{ overflowX: 'auto' }}>
        <table
          data-testid="sessions-table"
          style={{ width: '100%', borderCollapse: 'collapse', fontSize: '11px' }}
        >
          <thead>
            <tr style={{ borderBottom: '1px solid #333', color: '#888', textAlign: 'left' }}>
              <th style={{ padding: '4px 8px' }}>Status</th>
              <th style={{ padding: '4px 8px' }}>SessionKey</th>
              <th style={{ padding: '4px 8px' }}>Agent</th>
              <th style={{ padding: '4px 8px' }}>Channel</th>
              <th style={{ padding: '4px 8px' }}>Peer</th>
              <th style={{ padding: '4px 8px' }}>Runs</th>
              <th style={{ padding: '4px 8px' }}>Last Active</th>
            </tr>
          </thead>
          <tbody>
            {filteredSessions.length === 0 ? (
              <tr>
                <td colSpan={7} style={{ padding: '16px 8px', color: '#666', textAlign: 'center' }}>
                  No sessions found
                </td>
              </tr>
            ) : (
              filteredSessions.map((session) => {
                const isSelected = selectedSessionKey === session.sessionKey;
                return (
                  <tr
                    key={session.sessionKey}
                    data-testid={`session-row-${session.sessionKey}`}
                    onClick={() => setSelectedSession(session.sessionKey)}
                    style={{
                      cursor: 'pointer',
                      background: isSelected ? '#1a2a1a' : 'transparent',
                      borderBottom: '1px solid #222',
                    }}
                  >
                    <td style={{ padding: '4px 8px' }}>
                      <span
                        style={{
                          display: 'inline-block',
                          width: '6px',
                          height: '6px',
                          borderRadius: '50%',
                          background: session.active ? '#00ff88' : '#666',
                        }}
                      />
                    </td>
                    <td style={{ padding: '4px 8px', fontWeight: isSelected ? 'bold' : 'normal' }}>
                      {truncate(session.sessionKey, 24)}
                    </td>
                    <td style={{ padding: '4px 8px', color: '#aaa' }}>{session.agentId ?? '--'}</td>
                    <td style={{ padding: '4px 8px', color: '#aaa' }}>{session.channelId ?? '--'}</td>
                    <td style={{ padding: '4px 8px', color: '#aaa' }}>
                      {session.peerId ? truncate(session.peerId, 16) : '--'}
                    </td>
                    <td style={{ padding: '4px 8px' }}>{session.runCount}</td>
                    <td style={{ padding: '4px 8px', color: '#888' }}>
                      {formatRelativeTime(session.updatedAtMs)}
                    </td>
                  </tr>
                );
              })
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
