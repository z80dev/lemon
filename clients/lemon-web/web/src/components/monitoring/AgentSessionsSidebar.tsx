import { useMemo, useState } from 'react';
import { useMonitoringStore } from '../../store/monitoringStore';

export interface AgentSessionsSidebarProps {
  onSelectSession: (sessionKey: string) => void;
  onSelectRun: (runId: string) => void;
}

type SidebarTab = 'sessions' | 'agents';

function truncate(str: string, max: number): string {
  if (str.length <= max) return str;
  return str.slice(0, max - 1) + '\u2026';
}

export function AgentSessionsSidebar({ onSelectSession, onSelectRun }: AgentSessionsSidebarProps) {
  const activeSessions = useMonitoringStore((s) => s.sessions.active);
  const agents = useMonitoringStore((s) => s.agents);
  const selectedSessionKey = useMonitoringStore((s) => s.ui.selectedSessionKey);
  const sidebarTab = useMonitoringStore((s) => s.ui.sidebarTab);
  const [tab, setTab] = useState<SidebarTab>(sidebarTab ?? 'sessions');

  const sessionsList = useMemo(
    () =>
      Object.values(activeSessions).sort(
        (a, b) => (b.updatedAtMs ?? 0) - (a.updatedAtMs ?? 0)
      ),
    [activeSessions]
  );

  const agentsList = useMemo(() => Object.values(agents), [agents]);

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
        width: '220px',
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
          Sessions
        </button>
        <button
          type="button"
          data-testid="tab-agents"
          style={activeTabStyle(tab === 'agents')}
          onClick={() => setTab('agents')}
        >
          Agents
        </button>
      </div>

      {/* Content */}
      <div style={{ flex: 1, overflowY: 'auto', padding: '4px 0' }}>
        {tab === 'sessions' && (
          <>
            {sessionsList.length === 0 ? (
              <div style={{ padding: '12px 8px', color: '#666' }}>No active sessions</div>
            ) : (
              sessionsList.map((session) => {
                const isSelected = selectedSessionKey === session.sessionKey;
                return (
                  <div
                    key={session.sessionKey}
                    data-testid={`session-item-${session.sessionKey}`}
                    style={{
                      padding: '6px 8px',
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
                          background: session.active ? '#00ff88' : '#666',
                          flexShrink: 0,
                        }}
                      />
                      <span style={{ fontWeight: 'bold', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                        {truncate(session.sessionKey, 20)}
                      </span>
                    </div>
                    <div style={{ color: '#888', fontSize: '10px', marginTop: '2px', paddingLeft: '10px' }}>
                      {session.agentId ?? 'unknown'} | {session.channelId ?? '--'}
                      {session.runCount > 0 && (
                        <span style={{ marginLeft: '4px', color: '#00ff88' }}>
                          {session.runCount} run{session.runCount !== 1 ? 's' : ''}
                        </span>
                      )}
                    </div>
                    {session.runId && (
                      <div
                        style={{ color: '#5599ff', fontSize: '10px', cursor: 'pointer', paddingLeft: '10px', marginTop: '1px' }}
                        onClick={(e) => {
                          e.stopPropagation();
                          onSelectRun(session.runId!);
                        }}
                      >
                        run: {truncate(session.runId, 12)}
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
                  style={{ padding: '6px 8px' }}
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
                              : '#666',
                        flexShrink: 0,
                      }}
                    />
                    <span style={{ fontWeight: 'bold' }}>{agent.agentId}</span>
                  </div>
                  <div style={{ color: '#888', fontSize: '10px', paddingLeft: '10px', marginTop: '2px' }}>
                    sessions: {agent.activeSessionCount}
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
