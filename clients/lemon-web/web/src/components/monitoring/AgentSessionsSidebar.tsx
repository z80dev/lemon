import { useMemo, useState } from 'react';
import { useMonitoringStore } from '../../store/monitoringStore';
import type { MonitoringSession } from '../../../../shared/src/monitoringTypes';

export interface AgentSessionsSidebarProps {
  onSelectSession: (sessionKey: string) => void;
  onSelectRun: (runId: string) => void;
}

type SidebarTab = 'sessions' | 'agents';

function truncate(str: string, max: number): string {
  if (str.length <= max) return str;
  return str.slice(0, max - 1) + '\u2026';
}

function formatRelativeTime(ms: number | null): string {
  if (ms == null) return '--';
  const diff = Date.now() - ms;
  if (diff < 60_000) return `${Math.floor(diff / 1000)}s ago`;
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
  return `${Math.floor(diff / 86_400_000)}d ago`;
}

export function AgentSessionsSidebar({ onSelectSession, onSelectRun }: AgentSessionsSidebarProps) {
  const activeSessions = useMonitoringStore((s) => s.sessions.active);
  const historicalSessions = useMonitoringStore((s) => s.sessions.historical);
  const agents = useMonitoringStore((s) => s.agents);
  const selectedSessionKey = useMonitoringStore((s) => s.ui.selectedSessionKey);
  const sidebarTab = useMonitoringStore((s) => s.ui.sidebarTab);
  const [tab, setTab] = useState<SidebarTab>(sidebarTab ?? 'sessions');

  // Merge active + historical, dedup, sort by updatedAt desc
  const allSessions = useMemo<MonitoringSession[]>(() => {
    const map = new Map<string, MonitoringSession>();
    for (const s of historicalSessions) map.set(s.sessionKey, s);
    for (const s of Object.values(activeSessions)) map.set(s.sessionKey, s);
    return Array.from(map.values()).sort(
      (a, b) => (b.updatedAtMs ?? 0) - (a.updatedAtMs ?? 0)
    );
  }, [activeSessions, historicalSessions]);

  const agentsList = useMemo(
    () =>
      Object.values(agents).sort((a, b) => {
        // Active first, then by last activity
        if (a.status === 'active' && b.status !== 'active') return -1;
        if (b.status === 'active' && a.status !== 'active') return 1;
        return (b.latestUpdatedAtMs ?? 0) - (a.latestUpdatedAtMs ?? 0);
      }),
    [agents]
  );

  const activeTabStyle = (isActive: boolean): React.CSSProperties => ({
    flex: 1,
    padding: '6px 0',
    border: 'none',
    borderBottom: isActive ? '2px solid #00ff88' : '2px solid transparent',
    background: 'transparent',
    color: isActive ? '#00ff88' : '#888',
    fontFamily: 'monospace',
    fontSize: '11px',
    cursor: 'pointer',
    textTransform: 'uppercase',
    letterSpacing: '0.5px',
  });

  return (
    <aside
      data-testid="agent-sessions-sidebar"
      style={{
        width: '240px',
        background: '#141414',
        borderRight: '1px solid #333',
        display: 'flex',
        flexDirection: 'column',
        fontFamily: 'monospace',
        fontSize: '11px',
        color: '#e0e0e0',
        flexShrink: 0,
        overflow: 'hidden',
      }}
    >
      {/* Tab bar */}
      <div style={{ display: 'flex', borderBottom: '1px solid #333' }}>
        <button
          type="button"
          data-testid="tab-sessions"
          style={activeTabStyle(tab === 'sessions')}
          onClick={() => setTab('sessions')}
        >
          Sessions{allSessions.length > 0 && ` (${allSessions.length})`}
        </button>
        <button
          type="button"
          data-testid="tab-agents"
          style={activeTabStyle(tab === 'agents')}
          onClick={() => setTab('agents')}
        >
          Agents{agentsList.length > 0 && ` (${agentsList.length})`}
        </button>
      </div>

      {/* Content */}
      <div style={{ flex: 1, overflowY: 'auto', padding: '4px 0' }}>
        {tab === 'sessions' && (
          <>
            {allSessions.length === 0 ? (
              <div style={{ padding: '12px 8px', color: '#666' }}>No sessions</div>
            ) : (
              allSessions.map((session) => {
                const isSelected = selectedSessionKey === session.sessionKey;
                return (
                  <div
                    key={session.sessionKey}
                    data-testid={`session-item-${session.sessionKey}`}
                    style={{
                      padding: '5px 8px',
                      cursor: 'pointer',
                      background: isSelected ? '#1a2a1a' : 'transparent',
                      borderLeft: isSelected ? '3px solid #00ff88' : '3px solid transparent',
                    }}
                    onClick={() => onSelectSession(session.sessionKey)}
                  >
                    <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                      <span
                        style={{
                          width: '6px',
                          height: '6px',
                          borderRadius: '50%',
                          background: session.active ? '#00ff88' : '#444',
                          flexShrink: 0,
                        }}
                      />
                      <span
                        style={{
                          fontWeight: isSelected ? 'bold' : 'normal',
                          overflow: 'hidden',
                          textOverflow: 'ellipsis',
                          whiteSpace: 'nowrap',
                          flex: 1,
                        }}
                      >
                        {truncate(session.sessionKey, 22)}
                      </span>
                    </div>
                    <div
                      style={{
                        color: '#666',
                        fontSize: '10px',
                        marginTop: '1px',
                        paddingLeft: '10px',
                        display: 'flex',
                        gap: '6px',
                        overflow: 'hidden',
                      }}
                    >
                      <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                        {session.agentId ?? 'unknown'}
                      </span>
                      {session.runCount > 0 && (
                        <span style={{ color: '#5599ff', flexShrink: 0 }}>
                          {session.runCount}r
                        </span>
                      )}
                      <span style={{ color: '#555', flexShrink: 0 }}>
                        {formatRelativeTime(session.updatedAtMs)}
                      </span>
                    </div>
                    {session.runId && (
                      <div
                        style={{
                          color: '#5599ff',
                          fontSize: '10px',
                          cursor: 'pointer',
                          paddingLeft: '10px',
                          marginTop: '1px',
                        }}
                        onClick={(e) => {
                          e.stopPropagation();
                          onSelectRun(session.runId!);
                        }}
                      >
                        ▶ {truncate(session.runId, 14)}
                      </div>
                    )}
                  </div>
                );
              })
            )}
          </>
        )}

        {tab === 'agents' && (
          <>
            {agentsList.length === 0 ? (
              <div style={{ padding: '12px 8px', color: '#666' }}>No agents registered</div>
            ) : (
              agentsList.map((agent) => (
                <div
                  key={agent.agentId}
                  data-testid={`agent-item-${agent.agentId}`}
                  style={{ padding: '6px 8px', borderBottom: '1px solid #1a1a1a' }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                    <span
                      style={{
                        width: '6px',
                        height: '6px',
                        borderRadius: '50%',
                        background:
                          agent.status === 'active'
                            ? '#00ff88'
                            : agent.status === 'idle'
                              ? '#ffaa00'
                              : '#444',
                        flexShrink: 0,
                      }}
                    />
                    <span style={{ fontWeight: 'bold', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                      {agent.name ?? agent.agentId}
                    </span>
                  </div>
                  <div
                    style={{
                      color: '#666',
                      fontSize: '10px',
                      paddingLeft: '10px',
                      marginTop: '3px',
                      display: 'grid',
                      gridTemplateColumns: '1fr 1fr',
                      gap: '2px',
                    }}
                  >
                    <span>sessions: <span style={{ color: '#aaa' }}>{agent.sessionCount}</span></span>
                    <span>active: <span style={{ color: agent.activeSessionCount > 0 ? '#00ff88' : '#aaa' }}>{agent.activeSessionCount}</span></span>
                    {agent.routeCount > 0 && (
                      <span>routes: <span style={{ color: '#aaa' }}>{agent.routeCount}</span></span>
                    )}
                    {agent.model && (
                      <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                        <span style={{ color: '#555' }}>model: </span>
                        <span style={{ color: '#888' }}>{truncate(agent.model, 16)}</span>
                      </span>
                    )}
                    {agent.engine && (
                      <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                        <span style={{ color: '#555' }}>engine: </span>
                        <span style={{ color: '#888' }}>{truncate(agent.engine, 12)}</span>
                      </span>
                    )}
                    {agent.latestUpdatedAtMs && (
                      <span style={{ gridColumn: '1 / -1', color: '#555' }}>
                        last: {formatRelativeTime(agent.latestUpdatedAtMs)}
                      </span>
                    )}
                  </div>
                </div>
              ))
            )}
          </>
        )}
      </div>
    </aside>
  );
}
