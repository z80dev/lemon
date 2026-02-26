import { useMemo, useState } from 'react';
import { useMonitoringStore } from '../../store/monitoringStore';
import type { MonitoringTask, SessionRunSummary } from '../../../../shared/src/monitoringTypes';

function formatRelativeTime(ms: number | null): string {
  if (ms == null) return '--';
  const diff = Date.now() - ms;
  if (diff < 60_000) return `${Math.floor(diff / 1000)}s ago`;
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
  return `${Math.floor(diff / 86_400_000)}d ago`;
}

function formatDuration(ms: number | null): string {
  if (ms == null) return '--';
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.floor(ms / 60_000)}m ${Math.floor((ms % 60_000) / 1000)}s`;
}

function truncate(s: string | null | undefined, max: number): string {
  if (!s) return '';
  return s.length <= max ? s : s.slice(0, max - 1) + '...';
}

function runStatus(run: SessionRunSummary): 'completed' | 'error' | 'unknown' {
  if (run.ok === true) return 'completed';
  if (run.ok === false || run.error) return 'error';
  return 'unknown';
}

function runTaskMatch(task: MonitoringTask, runId: string | null): boolean {
  if (!runId) return false;
  return task.runId === runId || task.parentRunId === runId;
}

export interface SessionDetailPanelProps {
  sessionKey: string | null;
  loading?: boolean;
  onSelectRun?: (runId: string) => void;
}

export function SessionDetailPanel({ sessionKey, loading, onSelectRun }: SessionDetailPanelProps) {
  const sessionDetails = useMonitoringStore((s) => s.sessionDetails);
  const activeSessions = useMonitoringStore((s) => s.sessions.active);
  const historicalSessions = useMonitoringStore((s) => s.sessions.historical);
  const activeRuns = useMonitoringStore((s) => s.runs.active);
  const recentRuns = useMonitoringStore((s) => s.runs.recent);
  const activeTasks = useMonitoringStore((s) => s.tasks.active);
  const recentTasks = useMonitoringStore((s) => s.tasks.recent);

  const session = useMemo(() => {
    if (!sessionKey) return null;
    return activeSessions[sessionKey] ?? historicalSessions.find((s) => s.sessionKey === sessionKey) ?? null;
  }, [sessionKey, activeSessions, historicalSessions]);

  const sessionDetail = sessionKey ? sessionDetails[sessionKey] : undefined;
  const [showAllRuns, setShowAllRuns] = useState(false);

  const runs = useMemo(() => {
    const detailRuns = [...(sessionDetail?.runs ?? [])].sort(
      (a, b) => (a.startedAtMs ?? 0) - (b.startedAtMs ?? 0)
    );
    const allRuns =
      detailRuns.length > 0
        ? detailRuns
        : [...Object.values(activeRuns), ...recentRuns]
            .filter((run) => run.sessionKey === sessionKey)
            .sort((a, b) => (a.startedAtMs ?? 0) - (b.startedAtMs ?? 0))
            .map<SessionRunSummary>((run) => ({
              runId: run.runId,
              startedAtMs: run.startedAtMs,
              engine: run.engine,
              prompt: null,
              answer: null,
              ok: run.ok,
              error: run.status === 'error' ? 'run_error' : run.status === 'aborted' ? 'aborted' : null,
              durationMs: run.durationMs,
              toolCallCount: 0,
              toolCalls: [],
              tokens: null,
              eventCount: undefined,
              eventDigest: [],
            }));

    if (showAllRuns) return allRuns;
    return allRuns.slice(-60);
  }, [sessionDetail?.runs, showAllRuns, activeRuns, recentRuns, sessionKey]);

  const allSessionTasks = useMemo(() => {
    if (!sessionKey) return [];
    return [...Object.values(activeTasks), ...recentTasks]
      .filter((task) => task.sessionKey === sessionKey)
      .sort((a, b) => (b.startedAtMs ?? b.createdAtMs ?? 0) - (a.startedAtMs ?? a.createdAtMs ?? 0));
  }, [sessionKey, activeTasks, recentTasks]);

  const sessionSpawnedAgents = useMemo(() => {
    const ids = new Set<string>();
    for (const task of allSessionTasks) {
      if (!task.agentId) continue;
      if (session?.agentId && task.agentId === session.agentId) continue;
      ids.add(task.agentId);
    }
    return Array.from(ids).sort();
  }, [allSessionTasks, session?.agentId]);

  const liveRuns = useMemo(() => {
    if (!sessionKey) return [];
    return Object.values(activeRuns)
      .filter((run) => run.sessionKey === sessionKey)
      .sort((a, b) => (b.startedAtMs ?? 0) - (a.startedAtMs ?? 0));
  }, [sessionKey, activeRuns]);

  const liveTasks = useMemo(() => {
    return allSessionTasks.filter((task) => task.status === 'active' || task.status === 'queued');
  }, [allSessionTasks]);

  if (!sessionKey) {
    return (
      <div
        data-testid="session-detail-panel"
        style={{
          padding: '48px 24px',
          color: '#555',
          fontFamily: 'monospace',
          fontSize: '12px',
          textAlign: 'center',
        }}
      >
        Select a session in the left sidebar to open the workspace view.
      </div>
    );
  }

  const runCount = sessionDetail?.runCount ?? session?.runCount ?? 0;

  return (
    <div
      data-testid="session-detail-panel"
      style={{
        fontFamily: 'monospace',
        fontSize: '11px',
        color: '#e0e0e0',
        height: '100%',
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
      }}
    >
      <div
        style={{
          padding: '12px 14px',
          borderBottom: '1px solid #333',
          background: '#111',
          flexShrink: 0,
        }}
      >
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: '8px',
            flexWrap: 'wrap',
            marginBottom: '8px',
          }}
        >
          <span style={{ color: '#00ff88', fontWeight: 'bold', fontSize: '13px' }}>
            Session Workspace
          </span>
          <span style={{ color: '#666' }}>{truncate(sessionKey, 84)}</span>
          {loading && <span style={{ color: '#888' }}>loading...</span>}
          {!loading && !sessionDetail && <span style={{ color: '#666' }}>fetching...</span>}
        </div>

        <div style={{ display: 'flex', gap: '8px', flexWrap: 'wrap', color: '#888' }}>
          {session?.agentId && <span>agent: <span style={{ color: '#aaa' }}>{session.agentId}</span></span>}
          {session?.channelId && <span>channel: <span style={{ color: '#aaa' }}>{session.channelId}</span></span>}
          {session?.peerId && <span>peer: <span style={{ color: '#aaa' }}>{truncate(session.peerId, 24)}</span></span>}
          {session?.threadId && <span>thread: <span style={{ color: '#aaa' }}>{truncate(session.threadId, 20)}</span></span>}
          <span>runs: <span style={{ color: '#5599ff' }}>{runCount}</span></span>
          <span>live runs: <span style={{ color: liveRuns.length > 0 ? '#00ff88' : '#666' }}>{liveRuns.length}</span></span>
          <span>live tasks: <span style={{ color: liveTasks.length > 0 ? '#ffaa00' : '#666' }}>{liveTasks.length}</span></span>
          {session?.updatedAtMs && <span>updated: {formatRelativeTime(session.updatedAtMs)}</span>}
        </div>

        {(liveRuns.length > 0 || sessionSpawnedAgents.length > 0) && (
          <div style={{ marginTop: '8px', display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '10px' }}>
            <div style={{ border: '1px solid #272727', borderRadius: '4px', padding: '6px 8px', background: '#121212' }}>
              <div style={{ color: '#777', textTransform: 'uppercase', fontSize: '10px', marginBottom: '4px' }}>Live Runs</div>
              {liveRuns.length === 0 ? (
                <div style={{ color: '#555' }}>None</div>
              ) : (
                liveRuns.map((run) => (
                  <div key={run.runId} style={{ display: 'flex', gap: '8px', padding: '2px 0', alignItems: 'center' }}>
                    <span style={{ color: '#00ff88', minWidth: '50px' }}>{run.status}</span>
                    <span style={{ color: '#5599ff', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                      {run.runId}
                    </span>
                    {run.engine && <span style={{ color: '#666', marginLeft: 'auto' }}>{run.engine}</span>}
                  </div>
                ))
              )}
            </div>

            <div style={{ border: '1px solid #272727', borderRadius: '4px', padding: '6px 8px', background: '#121212' }}>
              <div style={{ color: '#777', textTransform: 'uppercase', fontSize: '10px', marginBottom: '4px' }}>Spawned Agents</div>
              {sessionSpawnedAgents.length === 0 ? (
                <div style={{ color: '#555' }}>None observed in task history</div>
              ) : (
                sessionSpawnedAgents.map((agentId) => (
                  <div key={agentId} style={{ display: 'flex', gap: '8px', padding: '2px 0' }}>
                    <span style={{ color: '#ffaa00' }}>{agentId}</span>
                    <span style={{ color: '#666' }}>
                      {allSessionTasks.filter((task) => task.agentId === agentId).length} task(s)
                    </span>
                  </div>
                ))
              )}
            </div>
          </div>
        )}
      </div>

      <div style={{ flex: 1, overflowY: 'auto', padding: '14px', background: '#0d0d0d' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '10px', marginBottom: '10px' }}>
          <span style={{ color: '#777', textTransform: 'uppercase', fontSize: '10px' }}>
            Conversation + Run Timeline ({runs.length}{runCount > runs.length ? ` of ${runCount}` : ''})
          </span>
          {sessionDetail?.runs && sessionDetail.runs.length > 60 && (
            <button
              type="button"
              onClick={() => setShowAllRuns((v) => !v)}
              style={{
                border: '1px solid #333',
                borderRadius: '3px',
                background: 'transparent',
                color: '#5599ff',
                fontFamily: 'monospace',
                fontSize: '10px',
                cursor: 'pointer',
                padding: '2px 8px',
              }}
            >
              {showAllRuns ? 'Show Recent Only' : 'Show Full History'}
            </button>
          )}
        </div>

        {runs.length === 0 && sessionDetail ? (
          <div style={{ color: '#555', padding: '18px 8px' }}>No run history available.</div>
        ) : (
          runs.map((run, idx) => {
            const runId = run.runId ?? null;
            const status = runStatus(run);
            const statusColor = status === 'completed' ? '#00ff88' : status === 'error' ? '#ff6666' : '#888';
            const runTasks = allSessionTasks.filter((task) => runTaskMatch(task, runId));
            const activeRunTasks = runTasks.filter((task) => task.status === 'active' || task.status === 'queued');
            const spawnedForRun = Array.from(
              new Set(
                runTasks
                  .map((task) => task.agentId)
                  .filter((agentId): agentId is string => Boolean(agentId) && agentId !== session?.agentId)
              )
            );

            return (
              <div
                key={`${runId ?? 'run'}-${idx}`}
                style={{
                  border: '1px solid #232323',
                  borderRadius: '6px',
                  background: '#111',
                  marginBottom: '12px',
                  overflow: 'hidden',
                }}
              >
                <div
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: '8px',
                    padding: '6px 10px',
                    borderBottom: '1px solid #1b1b1b',
                    background: '#141414',
                  }}
                >
                  <span style={{ color: '#555', minWidth: '32px' }}>#{idx + 1}</span>
                  <span style={{ color: statusColor, minWidth: '70px' }}>{status}</span>
                  {run.engine && <span style={{ color: '#5599ff' }}>{run.engine}</span>}
                  <span style={{ color: '#777' }}>dur: {formatDuration(run.durationMs)}</span>
                  <span style={{ color: '#777' }}>tools: {run.toolCallCount}</span>
                  {run.eventCount != null && <span style={{ color: '#666' }}>ev: {run.eventCount}</span>}
                  {run.startedAtMs && <span style={{ color: '#666', marginLeft: 'auto' }}>{formatRelativeTime(run.startedAtMs)}</span>}
                  {runId && onSelectRun && (
                    <button
                      type="button"
                      onClick={() => onSelectRun(runId)}
                      style={{
                        border: '1px solid #333',
                        borderRadius: '3px',
                        background: 'transparent',
                        color: '#5599ff',
                        fontFamily: 'monospace',
                        fontSize: '10px',
                        cursor: 'pointer',
                        padding: '1px 8px',
                      }}
                    >
                      inspect
                    </button>
                  )}
                </div>

                <div style={{ padding: '10px' }}>
                  {run.prompt && (
                    <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: '8px' }}>
                      <div
                        style={{
                          maxWidth: '88%',
                          background: '#182334',
                          border: '1px solid #24354d',
                          borderRadius: '6px',
                          padding: '8px 10px',
                          color: '#d6e6ff',
                          whiteSpace: 'pre-wrap',
                        }}
                      >
                        {run.promptFull ?? run.prompt}
                      </div>
                    </div>
                  )}

                  {run.answer && (
                    <div style={{ display: 'flex', justifyContent: 'flex-start', marginBottom: '8px' }}>
                      <div
                        style={{
                          maxWidth: '88%',
                          background: '#142319',
                          border: '1px solid #21412b',
                          borderRadius: '6px',
                          padding: '8px 10px',
                          color: '#dbffe7',
                          whiteSpace: 'pre-wrap',
                        }}
                      >
                        {run.answerFull ?? run.answer}
                      </div>
                    </div>
                  )}

                  {!run.prompt && !run.answer && (
                    <div style={{ color: '#666', marginBottom: '8px' }}>No transcript captured for this run.</div>
                  )}

                  {(run.toolCalls.length > 0 || runTasks.length > 0 || run.error || run.tokens) && (
                    <div style={{ borderTop: '1px dashed #2a2a2a', paddingTop: '8px', marginTop: '4px' }}>
                      {run.toolCalls.length > 0 && (
                        <div style={{ marginBottom: '8px' }}>
                          <div style={{ color: '#777', textTransform: 'uppercase', fontSize: '10px', marginBottom: '4px' }}>
                            Tools
                          </div>
                          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '6px' }}>
                            {run.toolCalls.slice(0, 24).map((tool, toolIdx) => (
                              <span
                                key={`${tool.name}-${toolIdx}`}
                                style={{
                                  border: '1px solid #2f2f2f',
                                  borderRadius: '12px',
                                  padding: '1px 8px',
                                  color: tool.ok === false ? '#ff7777' : '#ffaa00',
                                  background: '#171717',
                                }}
                                title={tool.detail ?? undefined}
                              >
                                {tool.name}
                                {tool.phase ? `:${tool.phase}` : ''}
                              </span>
                            ))}
                          </div>
                        </div>
                      )}

                      {runTasks.length > 0 && (
                        <div style={{ marginBottom: '8px' }}>
                          <div style={{ color: '#777', textTransform: 'uppercase', fontSize: '10px', marginBottom: '4px' }}>
                            Task Activity
                          </div>
                          {activeRunTasks.length > 0 && (
                            <div style={{ color: '#00ff88', marginBottom: '4px' }}>
                              live: {activeRunTasks.length} task(s)
                            </div>
                          )}
                          {spawnedForRun.length > 0 && (
                            <div style={{ color: '#ffaa00', marginBottom: '4px' }}>
                              spawned agents: {spawnedForRun.join(', ')}
                            </div>
                          )}
                          <div style={{ maxHeight: '150px', overflowY: 'auto', border: '1px solid #242424', borderRadius: '4px' }}>
                            {runTasks.slice(0, 40).map((task) => (
                              <div
                                key={task.taskId}
                                style={{ display: 'flex', gap: '8px', padding: '3px 6px', borderBottom: '1px solid #1b1b1b' }}
                              >
                                <span style={{ color: task.status === 'error' ? '#ff6666' : task.status === 'active' ? '#00ff88' : '#aaa', minWidth: '64px' }}>
                                  {task.status}
                                </span>
                                <span style={{ color: '#5599ff', minWidth: '88px' }}>
                                  {task.engine ?? 'unknown'}
                                </span>
                                <span style={{ color: '#aaa' }}>{truncate(task.description ?? task.taskId, 80)}</span>
                                {task.agentId && <span style={{ color: '#888', marginLeft: 'auto' }}>{task.agentId}</span>}
                              </div>
                            ))}
                          </div>
                        </div>
                      )}

                      {run.tokens && (
                        <div style={{ color: '#888', marginBottom: '4px' }}>
                          tokens: {run.tokens.total} (in {run.tokens.input}, out {run.tokens.output})
                          {run.tokens.costUsd > 0 ? ` | cost $${run.tokens.costUsd.toFixed(4)}` : ''}
                        </div>
                      )}

                      {run.error && <div style={{ color: '#ff7777' }}>error: {run.error}</div>}
                    </div>
                  )}
                </div>
              </div>
            );
          })
        )}
      </div>
    </div>
  );
}
