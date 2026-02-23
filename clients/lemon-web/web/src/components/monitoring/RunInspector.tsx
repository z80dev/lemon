import { useMemo } from 'react';
import { useMonitoringStore } from '../../store/monitoringStore';
import type { FeedEvent, MonitoringRun } from '../../../../shared/src/monitoringTypes';

function formatDuration(ms: number | null): string {
  if (ms == null) return '--';
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.floor(ms / 60_000)}m ${Math.floor((ms % 60_000) / 1000)}s`;
}

function formatTimestamp(ms: number): string {
  const d = new Date(ms);
  return d.toLocaleTimeString('en-US', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

const STATUS_COLORS: Record<string, string> = {
  active: '#00ff88',
  completed: '#00ff88',
  error: '#ff4444',
  aborted: '#888',
};

interface RunInspectorProps {
  onNavigateToTasks?: () => void;
}

export function RunInspector({ onNavigateToTasks }: RunInspectorProps) {
  const selectedRunId = useMonitoringStore((s) => s.ui.selectedRunId);
  const activeRuns = useMonitoringStore((s) => s.runs.active);
  const recentRuns = useMonitoringStore((s) => s.runs.recent);
  const eventFeed = useMonitoringStore((s) => s.eventFeed);
  const activeTasks = useMonitoringStore((s) => s.tasks.active);

  const run = useMemo<MonitoringRun | null>(() => {
    if (!selectedRunId) return null;
    return activeRuns[selectedRunId] ?? recentRuns.find((r) => r.runId === selectedRunId) ?? null;
  }, [selectedRunId, activeRuns, recentRuns]);

  const runEvents = useMemo<FeedEvent[]>(() => {
    if (!selectedRunId) return [];
    return eventFeed.filter((ev) => ev.runId === selectedRunId);
  }, [selectedRunId, eventFeed]);

  const toolEvents = useMemo<FeedEvent[]>(() => {
    return runEvents.filter((ev) => {
      const p = (ev.payload ?? {}) as Record<string, unknown>;
      return p['type'] === 'tool_use' || ev.eventName === 'tool_use';
    });
  }, [runEvents]);

  const hasChildTasks = useMemo(() => {
    if (!selectedRunId) return false;
    return Object.values(activeTasks).some((t) => t.parentRunId === selectedRunId);
  }, [selectedRunId, activeTasks]);

  if (!selectedRunId || !run) {
    return (
      <div
        data-testid="run-inspector"
        style={{
          fontFamily: 'monospace',
          fontSize: '12px',
          color: '#666',
          padding: '40px',
          textAlign: 'center',
        }}
      >
        Select a run to inspect
      </div>
    );
  }

  const statusColor = STATUS_COLORS[run.status] ?? '#888';

  return (
    <div data-testid="run-inspector" style={{ fontFamily: 'monospace', fontSize: '11px', color: '#e0e0e0' }}>
      {/* Header */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '12px',
          marginBottom: '16px',
          paddingBottom: '8px',
          borderBottom: '1px solid #333',
        }}
      >
        <span style={{ fontWeight: 'bold', fontSize: '13px' }}>Run</span>
        <span data-testid="run-id" style={{ color: '#5599ff' }}>{run.runId}</span>
        <span
          data-testid="run-status-badge"
          style={{
            padding: '1px 6px',
            borderRadius: '3px',
            background: statusColor + '22',
            color: statusColor,
            fontSize: '10px',
            textTransform: 'uppercase',
          }}
        >
          {run.status}
        </span>
        <span style={{ color: '#888' }}>
          duration: {formatDuration(run.durationMs)}
        </span>
        {run.agentId && <span style={{ color: '#aaa' }}>agent: {run.agentId}</span>}
        {run.sessionKey && <span style={{ color: '#aaa' }}>session: {run.sessionKey}</span>}
        {hasChildTasks && onNavigateToTasks && (
          <button
            type="button"
            data-testid="view-tasks-btn"
            onClick={onNavigateToTasks}
            style={{
              padding: '3px 8px',
              border: '1px solid #333',
              borderRadius: '3px',
              background: 'transparent',
              color: '#5599ff',
              fontFamily: 'monospace',
              fontSize: '10px',
              cursor: 'pointer',
            }}
          >
            View task tree
          </button>
        )}
      </div>

      {/* Timeline */}
      <div style={{ marginBottom: '16px' }}>
        <div style={{ fontWeight: 'bold', marginBottom: '8px', color: '#888' }}>
          Events ({runEvents.length})
        </div>
        {runEvents.length === 0 ? (
          <div style={{ color: '#666', padding: '8px' }}>No events for this run</div>
        ) : (
          <div style={{ maxHeight: '200px', overflowY: 'auto' }}>
            {runEvents.map((ev) => {
              const p = (ev.payload ?? {}) as Record<string, unknown>;
              return (
                <div
                  key={ev.id}
                  style={{
                    display: 'flex',
                    gap: '8px',
                    padding: '3px 0',
                    borderBottom: '1px solid #1a1a1a',
                  }}
                >
                  <span style={{ color: '#666', width: '60px', flexShrink: 0 }}>
                    {formatTimestamp(ev.receivedAtMs)}
                  </span>
                  <span
                    style={{
                      color:
                        ev.eventName === 'agent' ? '#5599ff' : ev.level === 'error' ? '#ff4444' : '#aaa',
                      width: '80px',
                      flexShrink: 0,
                    }}
                  >
                    {(p['type'] as string) ?? ev.eventName}
                  </span>
                  <span style={{ color: '#666', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {typeof p['tool_name'] === 'string' && `tool: ${p['tool_name']}`}
                    {typeof p['ok'] === 'boolean' && ` ok: ${String(p['ok'])}`}
                  </span>
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* Tool use section */}
      <div>
        <div style={{ fontWeight: 'bold', marginBottom: '8px', color: '#888' }}>
          Tool Usage ({toolEvents.length})
        </div>
        {toolEvents.length === 0 ? (
          <div style={{ color: '#666', padding: '8px' }}>No tool calls recorded</div>
        ) : (
          <div style={{ maxHeight: '200px', overflowY: 'auto' }}>
            {toolEvents.map((ev, idx) => {
              const p = (ev.payload ?? {}) as Record<string, unknown>;
              const toolName = (p['tool_name'] ?? p['name'] ?? 'unknown') as string;
              const toolStatus = (p['status'] ?? 'complete') as string;
              return (
                <div
                  key={ev.id}
                  data-testid={`tool-item-${idx}`}
                  style={{
                    display: 'flex',
                    gap: '8px',
                    padding: '4px 0',
                    borderBottom: '1px solid #1a1a1a',
                  }}
                >
                  <span style={{ color: '#666', width: '20px', textAlign: 'right' }}>
                    {idx + 1}.
                  </span>
                  <span style={{ color: '#5599ff', width: '120px' }}>{toolName}</span>
                  <span
                    style={{
                      color:
                        toolStatus === 'error'
                          ? '#ff4444'
                          : toolStatus === 'running'
                            ? '#ffaa00'
                            : '#00ff88',
                      fontSize: '10px',
                    }}
                  >
                    {toolStatus}
                  </span>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}
