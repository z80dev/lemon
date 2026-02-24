import { useCallback, useMemo, useState } from 'react';
import { useMonitoringStore } from '../../store/monitoringStore';
import type { MonitoringRun } from '../../../../shared/src/monitoringTypes';

interface LifecycleEntry {
  id: string;
  tsMs: number;
  label: string;
  detail: string;
}

interface RunnersInspectorProps {
  request?: <T = unknown>(method: string, params?: Record<string, unknown>) => Promise<T>;
  onSelectRun?: (runId: string) => void;
  onNavigateToTasks?: () => void;
}

function formatDuration(ms: number | null): string {
  if (ms == null) return '--';
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.floor(ms / 60_000)}m ${Math.floor((ms % 60_000) / 1000)}s`;
}

function formatTs(ms: number | null): string {
  if (ms == null) return '--:--:--';
  const d = new Date(ms);
  return d.toLocaleTimeString('en-US', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

function mapLifecycleLabel(eventName: string, payload: Record<string, unknown>): string {
  const type = payload['type'];
  if (eventName === 'agent' && type === 'started') return 'run_started';
  if (eventName === 'agent' && type === 'completed') return 'run_completed';
  if (eventName.startsWith('task.')) return eventName;
  if (type === 'tool_use') return 'tool_use';
  return eventName;
}

function mapLifecycleDetail(payload: Record<string, unknown>): string {
  const action = (payload['action'] ?? {}) as Record<string, unknown>;
  const tool = (payload['tool_name'] ?? action['title'] ?? payload['name']) as string | undefined;
  if (tool) return String(tool);
  const status = payload['status'];
  if (typeof status === 'string') return status;
  const phase = payload['phase'];
  if (typeof phase === 'string') return phase;
  return '';
}

export function RunnersInspector({ request, onSelectRun, onNavigateToTasks }: RunnersInspectorProps) {
  const activeRuns = useMonitoringStore((s) => s.runs.active);
  const recentRuns = useMonitoringStore((s) => s.runs.recent);
  const tasksActive = useMonitoringStore((s) => s.tasks.active);
  const tasksRecent = useMonitoringStore((s) => s.tasks.recent);
  const eventFeed = useMonitoringStore((s) => s.eventFeed);
  const runIntrospection = useMonitoringStore((s) => s.runIntrospection);
  const applyRunIntrospection = useMonitoringStore((s) => s.applyRunIntrospection);
  const [expandedRunIds, setExpandedRunIds] = useState<Set<string>>(new Set());
  const [loadingRunIds, setLoadingRunIds] = useState<Set<string>>(new Set());

  const allRuns = useMemo<MonitoringRun[]>(() => {
    const map = new Map<string, MonitoringRun>();
    for (const run of recentRuns) map.set(run.runId, run);
    for (const run of Object.values(activeRuns)) map.set(run.runId, run);
    return Array.from(map.values()).sort((a, b) => {
      const aTs = a.startedAtMs ?? a.completedAtMs ?? 0;
      const bTs = b.startedAtMs ?? b.completedAtMs ?? 0;
      return bTs - aTs;
    });
  }, [activeRuns, recentRuns]);

  const runLastEventAtMs = useMemo(() => {
    const map: Record<string, number> = {};
    for (const ev of eventFeed) {
      if (!ev.runId) continue;
      map[ev.runId] = Math.max(map[ev.runId] ?? 0, ev.receivedAtMs);
    }
    return map;
  }, [eventFeed]);

  const stuckRuns = useMemo(() => {
    const now = Date.now();
    return allRuns.filter((run) => {
      if (run.status !== 'active') return false;
      const lastEvent = runLastEventAtMs[run.runId] ?? run.startedAtMs ?? 0;
      const age = now - (run.startedAtMs ?? now);
      const silentFor = now - lastEvent;
      return age > 10 * 60_000 && silentFor > 3 * 60_000;
    });
  }, [allRuns, runLastEventAtMs]);

  const engineSummary = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const run of allRuns) {
      const engine = run.engine ?? 'unknown';
      counts[engine] = (counts[engine] ?? 0) + 1;
    }
    for (const task of [...Object.values(tasksActive), ...tasksRecent]) {
      const engine = task.engine ?? 'unknown';
      counts[engine] = (counts[engine] ?? 0) + 1;
    }
    return Object.entries(counts).sort((a, b) => b[1] - a[1]);
  }, [allRuns, tasksActive, tasksRecent]);

  const fetchTimeline = useCallback(async (runId: string) => {
    if (!request || loadingRunIds.has(runId)) return;
    setLoadingRunIds((prev) => new Set(prev).add(runId));
    try {
      const result = await request<{ events: unknown[]; runRecord?: unknown }>('run.introspection.list', {
        runId,
        limit: 1000,
        includeRunRecord: true,
        includeRunEvents: true,
        runEventLimit: 600,
      });

      const events = Array.isArray(result.events) ? result.events : [];
      applyRunIntrospection(runId, {
        events,
        runRecord: result.runRecord,
      });
    } finally {
      setLoadingRunIds((prev) => {
        const next = new Set(prev);
        next.delete(runId);
        return next;
      });
    }
  }, [applyRunIntrospection, loadingRunIds, request]);

  const toggleExpanded = useCallback((runId: string) => {
    setExpandedRunIds((prev) => {
      const next = new Set(prev);
      if (next.has(runId)) next.delete(runId);
      else next.add(runId);
      return next;
    });
    if (!runIntrospection[runId]) {
      void fetchTimeline(runId);
    }
  }, [fetchTimeline, runIntrospection]);

  if (allRuns.length === 0) {
    return (
      <div
        data-testid="runners-inspector"
        style={{ fontFamily: 'monospace', fontSize: '12px', color: '#666', padding: '40px', textAlign: 'center' }}
      >
        No runner data yet
      </div>
    );
  }

  return (
    <div data-testid="runners-inspector" style={{ fontFamily: 'monospace', fontSize: '11px', color: '#e0e0e0' }}>
      <div style={{ display: 'flex', gap: '14px', marginBottom: '12px', flexWrap: 'wrap' }}>
        <div>runs: <span style={{ color: '#5599ff' }}>{allRuns.length}</span></div>
        <div>active: <span style={{ color: '#00ff88' }}>{allRuns.filter((r) => r.status === 'active').length}</span></div>
        <div>stuck alerts: <span style={{ color: stuckRuns.length > 0 ? '#ff6666' : '#888' }}>{stuckRuns.length}</span></div>
        <div>tasks active: <span style={{ color: '#ffaa00' }}>{Object.keys(tasksActive).length}</span></div>
        <div>tasks recent: <span style={{ color: '#888' }}>{tasksRecent.length}</span></div>
      </div>

      {stuckRuns.length > 0 && (
        <div style={{ marginBottom: '12px', border: '1px solid #3a1d1d', borderRadius: '4px', padding: '8px', background: '#1a1111' }}>
          <div style={{ color: '#ff6666', marginBottom: '4px', fontWeight: 'bold' }}>Potentially stuck runs</div>
          {stuckRuns.map((run) => (
            <div key={run.runId} style={{ display: 'flex', gap: '8px', padding: '2px 0' }}>
              <span style={{ color: '#aaa' }}>{run.runId}</span>
              <span style={{ color: '#666' }}>{run.engine ?? 'unknown'}</span>
              <span style={{ marginLeft: 'auto', color: '#ff9999' }}>started {formatTs(run.startedAtMs)}</span>
            </div>
          ))}
        </div>
      )}

      <div style={{ marginBottom: '12px', border: '1px solid #333', borderRadius: '4px', padding: '8px', background: '#141414' }}>
        <div style={{ color: '#888', marginBottom: '4px', textTransform: 'uppercase', fontSize: '10px' }}>Engine load</div>
        {engineSummary.map(([engine, count]) => (
          <div key={engine} style={{ display: 'flex', gap: '8px', padding: '2px 0' }}>
            <span style={{ color: '#aaa' }}>{engine}</span>
            <span style={{ marginLeft: 'auto', color: '#5599ff' }}>{count}</span>
          </div>
        ))}
      </div>

      <div style={{ borderTop: '1px solid #333' }}>
        {allRuns.map((run) => {
          const isExpanded = expandedRunIds.has(run.runId);
          const cachedTimeline = runIntrospection[run.runId]?.events ?? [];
          const feedEvents = eventFeed.filter((ev) => ev.runId === run.runId).slice(-50);
          const lifecycleFromFeed: LifecycleEntry[] = feedEvents.map((ev) => {
            const payload = (ev.payload ?? {}) as Record<string, unknown>;
            return {
              id: ev.id,
              tsMs: ev.receivedAtMs,
              label: mapLifecycleLabel(ev.eventName, payload),
              detail: mapLifecycleDetail(payload),
            };
          });
          const lifecycleFromIntrospection: LifecycleEntry[] = Array.isArray(cachedTimeline)
            ? cachedTimeline
                .map((ev, idx) => {
                  if (!ev || typeof ev !== 'object' || Array.isArray(ev)) return null;
                  const item = ev as Record<string, unknown>;
                  const payload = (item['payload'] ?? {}) as Record<string, unknown>;
                  const ts = typeof item['tsMs'] === 'number' ? item['tsMs'] : null;
                  return {
                    id: `${run.runId}-${idx}`,
                    tsMs: ts ?? 0,
                    label: String(item['eventType'] ?? 'event'),
                    detail: mapLifecycleDetail(payload),
                  };
                })
                .filter((x): x is LifecycleEntry => x !== null)
            : [];
          const lifecycle = [...lifecycleFromIntrospection, ...lifecycleFromFeed]
            .sort((a, b) => a.tsMs - b.tsMs)
            .slice(-80);
          const lastEvent = runLastEventAtMs[run.runId] ?? null;
          const isLoadingTimeline = loadingRunIds.has(run.runId);

          return (
            <div key={run.runId} style={{ borderBottom: '1px solid #1d1d1d', padding: '6px 0' }}>
              <button
                type="button"
                onClick={() => toggleExpanded(run.runId)}
                style={{
                  width: '100%',
                  textAlign: 'left',
                  border: 'none',
                  background: 'transparent',
                  color: '#ddd',
                  fontFamily: 'monospace',
                  fontSize: '11px',
                  cursor: 'pointer',
                  display: 'flex',
                  gap: '8px',
                  alignItems: 'center',
                }}
              >
                <span style={{ color: '#444', width: '14px' }}>{isExpanded ? '▼' : '▶'}</span>
                <span style={{ color: '#5599ff', minWidth: '170px' }}>{run.runId}</span>
                <span style={{ color: run.status === 'active' ? '#00ff88' : run.status === 'error' ? '#ff6666' : '#aaa', minWidth: '70px' }}>
                  {run.status}
                </span>
                <span style={{ color: '#888', minWidth: '100px' }}>{run.engine ?? 'unknown'}</span>
                <span style={{ color: '#666', minWidth: '90px' }}>{formatDuration(run.durationMs)}</span>
                <span style={{ color: '#555' }}>last: {formatTs(lastEvent)}</span>
              </button>

              {isExpanded && (
                <div style={{ marginLeft: '22px', marginTop: '6px' }}>
                  <div style={{ display: 'flex', gap: '8px', marginBottom: '6px', flexWrap: 'wrap' }}>
                    <button
                      type="button"
                      onClick={() => onSelectRun?.(run.runId)}
                      style={{ border: '1px solid #2a2a2a', background: '#151515', color: '#5599ff', borderRadius: '3px', fontSize: '10px', padding: '2px 8px', cursor: 'pointer' }}
                    >
                      Open Run Inspector
                    </button>
                    <button
                      type="button"
                      onClick={() => onNavigateToTasks?.()}
                      style={{ border: '1px solid #2a2a2a', background: '#151515', color: '#ffaa00', borderRadius: '3px', fontSize: '10px', padding: '2px 8px', cursor: 'pointer' }}
                    >
                      Open Tasks
                    </button>
                    <button
                      type="button"
                      onClick={() => void fetchTimeline(run.runId)}
                      style={{ border: '1px solid #2a2a2a', background: '#151515', color: '#888', borderRadius: '3px', fontSize: '10px', padding: '2px 8px', cursor: 'pointer' }}
                    >
                      {isLoadingTimeline ? 'Loading…' : 'Reload Timeline'}
                    </button>
                  </div>
                  {lifecycle.length === 0 ? (
                    <div style={{ color: '#666', padding: '6px 0' }}>No lifecycle events for this runner yet</div>
                  ) : (
                    <div style={{ maxHeight: '220px', overflowY: 'auto', border: '1px solid #222', background: '#111' }}>
                      {lifecycle.map((entry) => (
                        <div key={entry.id} style={{ display: 'flex', gap: '8px', padding: '3px 6px', borderBottom: '1px solid #1a1a1a' }}>
                          <span style={{ color: '#666', width: '70px', flexShrink: 0 }}>{formatTs(entry.tsMs)}</span>
                          <span style={{ color: '#aaa', minWidth: '140px' }}>{entry.label}</span>
                          <span style={{ color: '#5599ff', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                            {entry.detail}
                          </span>
                        </div>
                      ))}
                    </div>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
