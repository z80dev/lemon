import { useCallback, useEffect, useMemo, useState, type CSSProperties } from 'react';
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
  running: '#5599ff',
  queued: '#ffaa00',
};

interface IntrospectionEvent {
  eventId?: string | null;
  eventType: string;
  tsMs: number | null;
  payload: Record<string, unknown>;
  runId?: string | null;
  agentId: string | null;
  sessionKey: string | null;
  parentRunId?: string | null;
  engine?: string | null;
  provenance?: string | null;
}

interface RunGraphNode {
  runId: string;
  status?: string;
  parentRunId?: string | null;
  sessionKey?: string | null;
  agentId?: string | null;
  engine?: string | null;
  startedAtMs?: number | null;
  completedAtMs?: number | null;
  durationMs?: number | null;
  ok?: boolean | null;
  error?: unknown;
  runRecord?: unknown;
  introspection?: unknown[];
  children: RunGraphNode[];
}

interface RunInspectorProps {
  onNavigateToTasks?: () => void;
  request?: <T = unknown>(method: string, params?: Record<string, unknown>) => Promise<T>;
}

export function RunInspector({ onNavigateToTasks, request }: RunInspectorProps) {
  const selectedRunId = useMonitoringStore((s) => s.ui.selectedRunId);
  const activeRuns = useMonitoringStore((s) => s.runs.active);
  const recentRuns = useMonitoringStore((s) => s.runs.recent);
  const eventFeed = useMonitoringStore((s) => s.eventFeed);
  const activeTasks = useMonitoringStore((s) => s.tasks.active);
  const recentTasks = useMonitoringStore((s) => s.tasks.recent);
  const runIntrospectionCache = useMonitoringStore((s) => s.runIntrospection);
  const applyRunIntrospection = useMonitoringStore((s) => s.applyRunIntrospection);

  const [introspectionEvents, setIntrospectionEvents] = useState<IntrospectionEvent[]>([]);
  const [runRecord, setRunRecord] = useState<Record<string, unknown> | null>(null);
  const [runGraph, setRunGraph] = useState<RunGraphNode | null>(null);
  const [loadingIntrospection, setLoadingIntrospection] = useState(false);
  const [loadingGraph, setLoadingGraph] = useState(false);
  const [expandedEventIds, setExpandedEventIds] = useState<Set<string>>(new Set());

  const run = useMemo<MonitoringRun | null>(() => {
    if (!selectedRunId) return null;
    return activeRuns[selectedRunId] ?? recentRuns.find((r) => r.runId === selectedRunId) ?? null;
  }, [selectedRunId, activeRuns, recentRuns]);

  const runEvents = useMemo<FeedEvent[]>(() => {
    if (!selectedRunId) return [];
    return eventFeed.filter((ev) => ev.runId === selectedRunId);
  }, [selectedRunId, eventFeed]);

  const liveToolEvents = useMemo<FeedEvent[]>(() => {
    return runEvents.filter((ev) => {
      const p = (ev.payload ?? {}) as Record<string, unknown>;
      return p['type'] === 'tool_use';
    });
  }, [runEvents]);

  const runTasks = useMemo(() => {
    const all = [...Object.values(activeTasks), ...recentTasks];
    return all.filter((t) => t.runId === selectedRunId || t.parentRunId === selectedRunId);
  }, [selectedRunId, activeTasks, recentTasks]);

  const hasChildTasks = useMemo(() => {
    if (!selectedRunId) return false;
    return Object.values(activeTasks).some((t) => t.parentRunId === selectedRunId);
  }, [selectedRunId, activeTasks]);

  const historicalToolCalls = useMemo(() => {
    return introspectionEvents.filter(
      (e) => e.eventType === 'tool_call_dispatched' || e.eventType === 'tool_use_observed'
    );
  }, [introspectionEvents]);

  const eventTypeCounts = useMemo(() => {
    return introspectionEvents.reduce<Record<string, number>>((acc, evt) => {
      acc[evt.eventType] = (acc[evt.eventType] ?? 0) + 1;
      return acc;
    }, {});
  }, [introspectionEvents]);

  const toggleEventExpanded = useCallback((id: string) => {
    setExpandedEventIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }, []);

  const loadIntrospection = useCallback(async (runId: string) => {
    if (!request) return;
    setLoadingIntrospection(true);
    try {
      const result = await request<{ events: IntrospectionEvent[]; runRecord?: Record<string, unknown> }>(
        'run.introspection.list',
        {
          runId,
          limit: 2000,
          includeRunRecord: true,
          includeRunEvents: true,
          runEventLimit: 1200,
        }
      );

      const events = result.events ?? [];
      const record = (result.runRecord as Record<string, unknown>) ?? null;
      setIntrospectionEvents(events);
      setRunRecord(record);
      applyRunIntrospection(runId, { events, runRecord: record ?? undefined });
    } catch {
      setIntrospectionEvents([]);
      setRunRecord(null);
    } finally {
      setLoadingIntrospection(false);
    }
  }, [applyRunIntrospection, request]);

  const loadRunGraph = useCallback(async (runId: string) => {
    if (!request) return;
    setLoadingGraph(true);
    try {
      const result = await request<{ graph?: RunGraphNode }>('run.graph.get', {
        runId,
        maxDepth: 12,
        childLimit: 400,
        includeRunRecord: true,
        includeRunEvents: true,
        runEventLimit: 1200,
        includeIntrospection: true,
        introspectionLimit: 1200,
      });

      const graph = result.graph ?? null;
      setRunGraph(graph);

      if (graph) {
        const runIds = flattenGraphRunIds(graph);
        await Promise.allSettled(
          runIds.map((id) => request('events.subscribe', { runId: id }))
        );
      }
    } catch {
      setRunGraph(null);
    } finally {
      setLoadingGraph(false);
    }
  }, [request]);

  useEffect(() => {
    if (!selectedRunId) return;

    const cached = runIntrospectionCache[selectedRunId];
    if (cached) {
      setIntrospectionEvents((cached.events ?? []) as IntrospectionEvent[]);
      setRunRecord((cached.runRecord as Record<string, unknown>) ?? null);
    } else {
      setIntrospectionEvents([]);
      setRunRecord(null);
    }

    setRunGraph(null);
    setExpandedEventIds(new Set());

    void loadIntrospection(selectedRunId);
    void loadRunGraph(selectedRunId);
  }, [selectedRunId, loadIntrospection, loadRunGraph, runIntrospectionCache]);

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
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: '12px',
          marginBottom: '16px',
          paddingBottom: '8px',
          borderBottom: '1px solid #333',
          flexWrap: 'wrap',
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
        <span style={{ color: '#888' }}>duration: {formatDuration(run.durationMs)}</span>
        {run.agentId && <span style={{ color: '#aaa' }}>agent: {run.agentId}</span>}
        {run.sessionKey && <span style={{ color: '#aaa' }}>session: {run.sessionKey}</span>}
        {run.engine && <span style={{ color: '#666' }}>engine: {run.engine}</span>}
        {run.parentRunId && (
          <span style={{ color: '#888' }}>
            parent: <span style={{ color: '#5599ff' }}>{run.parentRunId.slice(0, 8)}…</span>
          </span>
        )}
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
        <button
          type="button"
          onClick={() => {
            if (selectedRunId) {
              void loadIntrospection(selectedRunId);
              void loadRunGraph(selectedRunId);
            }
          }}
          style={{
            padding: '3px 8px',
            border: '1px solid #333',
            borderRadius: '3px',
            background: 'transparent',
            color: '#888',
            fontFamily: 'monospace',
            fontSize: '10px',
            cursor: 'pointer',
            marginLeft: 'auto',
          }}
        >
          {loadingIntrospection || loadingGraph ? 'Loading…' : 'Reload'}
        </button>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '16px' }}>
        <div>
          <div style={{ fontWeight: 'bold', marginBottom: '8px', color: '#888' }}>
            Tool Calls ({historicalToolCalls.length}{liveToolEvents.length > 0 && ` / ${liveToolEvents.length} live`})
          </div>
          {historicalToolCalls.length === 0 && liveToolEvents.length === 0 ? (
            <div style={{ color: '#666', padding: '8px' }}>No tool calls recorded</div>
          ) : (
            <div style={{ maxHeight: '260px', overflowY: 'auto' }}>
              {historicalToolCalls.map((ev, idx) => {
                const toolName =
                  (ev.payload['tool_name'] as string) ??
                  (ev.payload['name'] as string) ??
                  ev.eventType;
                const ok = ev.payload['ok'];
                return (
                  <div
                    key={`hist-${idx}`}
                    data-testid={`tool-item-${idx}`}
                    style={{ display: 'flex', gap: '8px', padding: '3px 0', borderBottom: '1px solid #1a1a1a' }}
                  >
                    <span style={{ color: '#555', width: '20px', textAlign: 'right', flexShrink: 0 }}>
                      {idx + 1}.
                    </span>
                    <span style={{ color: '#5599ff', minWidth: '100px' }}>{toolName}</span>
                    <span style={{ color: '#666', fontSize: '10px' }}>{ev.eventType}</span>
                    {ok !== undefined && ok !== null && (
                      <span style={{ color: ok ? '#00ff88' : '#ff4444', fontSize: '10px' }}>
                        {ok ? 'ok' : 'err'}
                      </span>
                    )}
                    {ev.tsMs && (
                      <span style={{ color: '#444', fontSize: '10px', marginLeft: 'auto' }}>
                        {formatTimestamp(ev.tsMs)}
                      </span>
                    )}
                  </div>
                );
              })}
              {historicalToolCalls.length === 0 && liveToolEvents.map((ev, idx) => {
                const p = (ev.payload ?? {}) as Record<string, unknown>;
                const action = (p['action'] ?? {}) as Record<string, unknown>;
                const toolName = (action['title'] as string) ?? (p['tool_name'] as string) ?? 'unknown';
                const ok = p['ok'];
                return (
                  <div
                    key={ev.id}
                    data-testid={`tool-item-${idx}`}
                    style={{ display: 'flex', gap: '8px', padding: '3px 0', borderBottom: '1px solid #1a1a1a' }}
                  >
                    <span style={{ color: '#555', width: '20px', textAlign: 'right', flexShrink: 0 }}>
                      {idx + 1}.
                    </span>
                    <span style={{ color: '#5599ff', minWidth: '100px' }}>{toolName}</span>
                    {ok !== undefined && ok !== null && (
                      <span style={{ color: ok ? '#00ff88' : '#ff4444', fontSize: '10px' }}>
                        {ok ? 'ok' : 'err'}
                      </span>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </div>

        <div>
          <div style={{ fontWeight: 'bold', marginBottom: '8px', color: '#888' }}>
            Tasks ({runTasks.length})
          </div>
          {runTasks.length === 0 ? (
            <div style={{ color: '#666', padding: '8px' }}>No tasks</div>
          ) : (
            <div style={{ maxHeight: '260px', overflowY: 'auto' }}>
              {runTasks.map((task) => (
                <div
                  key={task.taskId}
                  style={{ display: 'flex', gap: '8px', padding: '3px 0', borderBottom: '1px solid #1a1a1a' }}
                >
                  <span
                    style={{
                      width: '6px',
                      height: '6px',
                      borderRadius: '50%',
                      background:
                        task.status === 'active' ? '#ffaa00' : task.status === 'completed' ? '#00ff88' : '#ff4444',
                      flexShrink: 0,
                      marginTop: '4px',
                    }}
                  />
                  <span style={{ color: '#aaa', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {task.taskId.slice(0, 24)}
                  </span>
                  <span style={{ color: '#666', fontSize: '10px', marginLeft: 'auto', flexShrink: 0 }}>
                    {task.status}
                    {task.durationMs != null && ` · ${formatDuration(task.durationMs)}`}
                  </span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      <div style={{ marginTop: '16px' }}>
        <div style={{ fontWeight: 'bold', marginBottom: '8px', color: '#888' }}>
          Introspection Log ({introspectionEvents.length})
          {loadingIntrospection && <span style={{ color: '#666', marginLeft: '6px' }}>loading…</span>}
        </div>
        {Object.keys(eventTypeCounts).length > 0 && (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px', marginBottom: '8px' }}>
            {Object.entries(eventTypeCounts).map(([eventType, count]) => (
              <span
                key={eventType}
                style={{
                  padding: '1px 6px',
                  borderRadius: '3px',
                  border: '1px solid #2a2a2a',
                  color: '#888',
                  fontSize: '10px',
                }}
              >
                {eventType}: {count}
              </span>
            ))}
          </div>
        )}
        {introspectionEvents.length === 0 && !loadingIntrospection ? (
          <div style={{ color: '#666', padding: '8px' }}>No introspection data for this run</div>
        ) : (
          <div style={{ maxHeight: '300px', overflowY: 'auto' }}>
            {introspectionEvents.map((ev, idx) => {
              const eventId = ev.eventId ?? `${ev.eventType}:${idx}`;
              const expanded = expandedEventIds.has(eventId);
              return (
                <div
                  key={eventId}
                  style={{ borderBottom: '1px solid #1a1a1a', fontSize: '10px', padding: '3px 0' }}
                >
                  <button
                    type="button"
                    onClick={() => toggleEventExpanded(eventId)}
                    style={{
                      width: '100%',
                      textAlign: 'left',
                      border: 'none',
                      background: 'transparent',
                      color: '#aaa',
                      fontFamily: 'monospace',
                      fontSize: '10px',
                      cursor: 'pointer',
                      padding: 0,
                    }}
                  >
                    <span style={{ color: '#555', marginRight: '8px' }}>
                      {ev.tsMs ? formatTimestamp(ev.tsMs) : '--:--:--'}
                    </span>
                    <span style={{ color: '#5599ff', marginRight: '8px' }}>{ev.eventType}</span>
                    {ev.engine && <span style={{ color: '#666', marginRight: '6px' }}>eng:{ev.engine}</span>}
                    {ev.provenance && <span style={{ color: '#666', marginRight: '6px' }}>{ev.provenance}</span>}
                    {ev.parentRunId && (
                      <span style={{ color: '#666', marginRight: '6px' }}>
                        parent:{ev.parentRunId.slice(0, 10)}
                      </span>
                    )}
                    <span style={{ color: '#444', float: 'right' }}>{expanded ? '▼' : '▶'}</span>
                  </button>
                  {expanded && (
                    <pre
                      style={{
                        margin: '4px 0 0 18px',
                        maxHeight: '220px',
                        overflowY: 'auto',
                        background: '#111',
                        border: '1px solid #222',
                        padding: '8px',
                        color: '#bdbdbd',
                        whiteSpace: 'pre-wrap',
                        wordBreak: 'break-word',
                      }}
                    >
                      {JSON.stringify(ev.payload ?? {}, null, 2)}
                    </pre>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </div>

      <div style={{ marginTop: '16px' }}>
        <div style={{ fontWeight: 'bold', marginBottom: '8px', color: '#888' }}>
          Run Graph Internals
          {loadingGraph && <span style={{ color: '#666', marginLeft: '6px' }}>loading…</span>}
        </div>
        {!runGraph && !loadingGraph ? (
          <div style={{ color: '#666', padding: '8px' }}>No run graph data available</div>
        ) : runGraph ? (
          <RunGraphTree node={runGraph} depth={0} />
        ) : null}
      </div>

      {runRecord && (
        <div style={{ marginTop: '16px' }}>
          <div style={{ fontWeight: 'bold', marginBottom: '8px', color: '#888' }}>
            Raw Run Record
          </div>
          <pre
            style={{
              maxHeight: '260px',
              overflowY: 'auto',
              margin: 0,
              background: '#111',
              border: '1px solid #222',
              padding: '8px',
              color: '#bdbdbd',
              whiteSpace: 'pre-wrap',
              wordBreak: 'break-word',
            }}
          >
            {JSON.stringify(runRecord, null, 2)}
          </pre>
        </div>
      )}

      {runEvents.length > 0 && (
        <div style={{ marginTop: '16px' }}>
          <div style={{ fontWeight: 'bold', marginBottom: '8px', color: '#888' }}>
            Live Events ({runEvents.length})
          </div>
          <div style={{ maxHeight: '220px', overflowY: 'auto' }}>
            {runEvents.map((ev) => (
              <div
                key={ev.id}
                style={{ display: 'flex', gap: '8px', padding: '3px 0', borderBottom: '1px solid #1a1a1a' }}
              >
                <span style={{ color: '#666', width: '60px', flexShrink: 0 }}>
                  {formatTimestamp(ev.receivedAtMs)}
                </span>
                <span
                  style={{
                    color: ev.eventName === 'agent' ? '#5599ff' : ev.level === 'error' ? '#ff4444' : '#aaa',
                    width: '100px',
                    flexShrink: 0,
                  }}
                >
                  {ev.eventName}
                </span>
                <span style={{ color: '#666', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {JSON.stringify(ev.payload)}
                </span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

function RunGraphTree({ node, depth }: { node: RunGraphNode; depth: number }) {
  const [expanded, setExpanded] = useState(depth === 0);
  const [showRecord, setShowRecord] = useState(false);
  const [showIntrospection, setShowIntrospection] = useState(false);
  const statusColor = STATUS_COLORS[node.status ?? 'unknown'] ?? '#888';

  return (
    <div style={{ marginLeft: `${depth * 14}px`, borderLeft: depth > 0 ? '1px solid #1f1f1f' : 'none', paddingLeft: '6px' }}>
      <button
        type="button"
        onClick={() => setExpanded((v) => !v)}
        style={{
          width: '100%',
          textAlign: 'left',
          border: 'none',
          background: 'transparent',
          color: '#ddd',
          fontFamily: 'monospace',
          fontSize: '10px',
          cursor: 'pointer',
          padding: '3px 0',
        }}
      >
        <span style={{ color: '#444', marginRight: '6px' }}>{expanded ? '▼' : '▶'}</span>
        <span style={{ color: '#5599ff' }}>{node.runId}</span>
        <span style={{ color: statusColor, marginLeft: '8px' }}>{node.status ?? 'unknown'}</span>
        {node.engine && <span style={{ color: '#666', marginLeft: '8px' }}>{node.engine}</span>}
        {node.durationMs != null && <span style={{ color: '#666', marginLeft: '8px' }}>{formatDuration(node.durationMs)}</span>}
      </button>

      {expanded && (
        <div style={{ marginBottom: '8px' }}>
          <div style={{ color: '#777', fontSize: '10px' }}>
            {node.sessionKey && <span style={{ marginRight: '10px' }}>session: {node.sessionKey}</span>}
            {node.agentId && <span style={{ marginRight: '10px' }}>agent: {node.agentId}</span>}
            {node.parentRunId && <span>parent: {node.parentRunId}</span>}
          </div>
          <div style={{ marginTop: '4px', display: 'flex', gap: '8px', flexWrap: 'wrap' }}>
            {Boolean(node.runRecord) && (
              <button
                type="button"
                onClick={() => setShowRecord((v) => !v)}
                style={inlineButtonStyle(showRecord)}
              >
                {showRecord ? 'Hide' : 'Show'} runRecord
              </button>
            )}
            {Array.isArray(node.introspection) && node.introspection.length > 0 && (
              <button
                type="button"
                onClick={() => setShowIntrospection((v) => !v)}
                style={inlineButtonStyle(showIntrospection)}
              >
                {showIntrospection ? 'Hide' : 'Show'} introspection ({node.introspection.length})
              </button>
            )}
          </div>
          {showRecord && (
            <pre style={jsonPreStyle}>
              {JSON.stringify(node.runRecord, null, 2)}
            </pre>
          )}
          {showIntrospection && (
            <pre style={jsonPreStyle}>
              {JSON.stringify(node.introspection, null, 2)}
            </pre>
          )}
          {node.children.map((child) => (
            <RunGraphTree key={child.runId} node={child} depth={depth + 1} />
          ))}
        </div>
      )}
    </div>
  );
}

function inlineButtonStyle(active: boolean): CSSProperties {
  return {
    padding: '2px 6px',
    border: '1px solid #333',
    borderRadius: '3px',
    background: active ? '#1a1a1a' : 'transparent',
    color: '#888',
    fontFamily: 'monospace',
    fontSize: '10px',
    cursor: 'pointer',
  };
}

const jsonPreStyle: CSSProperties = {
  margin: '6px 0',
  maxHeight: '220px',
  overflowY: 'auto',
  background: '#111',
  border: '1px solid #222',
  padding: '8px',
  color: '#bdbdbd',
  whiteSpace: 'pre-wrap',
  wordBreak: 'break-word',
};

function flattenGraphRunIds(root: RunGraphNode): string[] {
  const ids = new Set<string>();
  const stack: RunGraphNode[] = [root];
  while (stack.length > 0) {
    const node = stack.pop();
    if (!node) continue;
    if (typeof node.runId === 'string' && node.runId.length > 0) {
      ids.add(node.runId);
    }
    if (Array.isArray(node.children)) {
      for (const child of node.children) stack.push(child);
    }
  }
  return Array.from(ids);
}
