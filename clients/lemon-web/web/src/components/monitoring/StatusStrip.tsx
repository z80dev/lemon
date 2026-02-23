import { useMemo } from 'react';
import { useMonitoringStore } from '../../store/monitoringStore';
import type { ControlPlaneConnectionState } from '../../rpc/controlPlaneTransport';

export interface StatusStripProps {
  connectionState: ControlPlaneConnectionState;
}

const CONNECTION_COLORS: Record<ControlPlaneConnectionState, string> = {
  connected: '#00ff88',
  connecting: '#ffaa00',
  reconnecting: '#ffaa00',
  disconnected: '#ff4444',
  error: '#ff4444',
};

function formatUptime(ms: number | null): string {
  if (ms == null || ms <= 0) return '--';
  const totalSec = Math.floor(ms / 1000);
  const h = Math.floor(totalSec / 3600);
  const m = Math.floor((totalSec % 3600) / 60);
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

export function StatusStrip({ connectionState }: StatusStripProps) {
  const instance = useMonitoringStore((s) => s.instance);
  const agentCount = useMonitoringStore((s) => Object.keys(s.agents).length);
  const sessionCount = useMonitoringStore((s) => {
    const activeCount = Object.keys(s.sessions.active).length;
    const histCount = s.sessions.historical.length;
    return Math.max(activeCount, histCount > 0 ? activeCount + histCount : activeCount);
  });

  const dotColor = CONNECTION_COLORS[connectionState] ?? '#ff4444';

  const heartbeatFresh = useMemo(() => {
    if (instance.lastUpdatedMs == null) return false;
    return Date.now() - instance.lastUpdatedMs < 30_000;
  }, [instance.lastUpdatedMs]);

  return (
    <>
      <style>{`
        @keyframes pulse-green {
          0%, 100% { opacity: 1; }
          50% { opacity: 0.4; }
        }
      `}</style>
      <div
        data-testid="status-strip"
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '16px',
          padding: '6px 16px',
          background: '#1a1a1a',
          borderBottom: '1px solid #333',
          fontFamily: 'monospace',
          fontSize: '11px',
          color: '#e0e0e0',
          flexShrink: 0,
        }}
      >
        {/* Connection dot */}
        <span
          data-testid="connection-dot"
          style={{
            display: 'inline-block',
            width: '8px',
            height: '8px',
            borderRadius: '50%',
            background: dotColor,
            flexShrink: 0,
          }}
        />

        {/* Title */}
        <span style={{ fontWeight: 'bold', letterSpacing: '1px' }}>
          LEMON MONITOR
        </span>

        {/* Health badge */}
        <span
          data-testid="health-badge"
          style={{
            padding: '1px 6px',
            borderRadius: '3px',
            background:
              instance.status === 'healthy'
                ? '#003322'
                : instance.status === 'degraded'
                  ? '#332200'
                  : instance.status === 'unhealthy'
                    ? '#330000'
                    : '#222',
            color:
              instance.status === 'healthy'
                ? '#00ff88'
                : instance.status === 'degraded'
                  ? '#ffaa00'
                  : instance.status === 'unhealthy'
                    ? '#ff4444'
                    : '#666',
            fontSize: '10px',
            textTransform: 'uppercase',
          }}
        >
          {instance.status}
        </span>

        {/* Spacer */}
        <span style={{ flex: 1 }} />

        {/* Uptime */}
        <span style={{ color: '#888' }}>
          up: <span data-testid="uptime-value">{formatUptime(instance.uptimeMs)}</span>
        </span>

        {/* Connected clients */}
        <span style={{ color: '#888' }}>
          clients: <span data-testid="clients-count">{instance.connectedClients}</span>
        </span>

        {/* Sessions */}
        {sessionCount > 0 && (
          <span style={{ color: '#888' }}>
            sessions: <span data-testid="session-count">{sessionCount}</span>
          </span>
        )}

        {/* Agents */}
        {agentCount > 0 && (
          <span style={{ color: '#888' }}>
            agents: <span data-testid="agent-count">{agentCount}</span>
          </span>
        )}

        {/* Active runs */}
        <span style={{ color: instance.activeRuns > 0 ? '#00ff88' : '#888' }}>
          runs: <span data-testid="active-runs">{instance.activeRuns}</span>
        </span>

        {/* Queued runs */}
        <span style={{ color: instance.queuedRuns > 0 ? '#ffaa00' : '#888' }}>
          queued: <span data-testid="queued-runs">{instance.queuedRuns}</span>
        </span>

        {/* Heartbeat indicator */}
        <span
          data-testid="heartbeat-dot"
          style={{
            display: 'inline-block',
            width: '8px',
            height: '8px',
            borderRadius: '50%',
            background: heartbeatFresh ? '#00ff88' : '#444',
            animation: heartbeatFresh ? 'pulse-green 2s ease-in-out infinite' : 'none',
          }}
        />
      </div>
    </>
  );
}
