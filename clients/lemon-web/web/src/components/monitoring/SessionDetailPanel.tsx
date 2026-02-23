import { useMemo, useState } from 'react';
import { useMonitoringStore } from '../../store/monitoringStore';
import type { SessionRunSummary } from '../../../../shared/src/monitoringTypes';

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
  return s.length <= max ? s : s.slice(0, max - 1) + '…';
}

export interface SessionDetailPanelProps {
  sessionKey: string | null;
  loading?: boolean;
}

export function SessionDetailPanel({ sessionKey, loading }: SessionDetailPanelProps) {
  const sessionDetails = useMonitoringStore((s) => s.sessionDetails);
  const activeSessions = useMonitoringStore((s) => s.sessions.active);
  const historicalSessions = useMonitoringStore((s) => s.sessions.historical);

  const session = useMemo(() => {
    if (!sessionKey) return null;
    return activeSessions[sessionKey] ?? historicalSessions.find((s) => s.sessionKey === sessionKey) ?? null;
  }, [sessionKey, activeSessions, historicalSessions]);

  const sessionDetail = sessionKey ? sessionDetails[sessionKey] : undefined;

  if (!sessionKey) {
    return (
      <div
        data-testid="session-detail-panel"
        style={{
          padding: '40px 24px',
          color: '#555',
          fontFamily: 'monospace',
          fontSize: '11px',
          textAlign: 'center',
        }}
      >
        Select a session to view details
      </div>
    );
  }

  const runs = sessionDetail?.runs ?? [];
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
      {/* Session header */}
      <div
        style={{
          padding: '10px 12px',
          borderBottom: '1px solid #333',
          background: '#141414',
          flexShrink: 0,
        }}
      >
        <div
          style={{
            fontWeight: 'bold',
            fontSize: '12px',
            marginBottom: '8px',
            color: '#00ff88',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
          }}
        >
          {truncate(sessionKey, 48)}
        </div>
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: '1fr 1fr',
            gap: '3px 16px',
            color: '#888',
          }}
        >
          {session?.agentId && (
            <div>
              <span style={{ color: '#555' }}>agent: </span>
              {session.agentId}
            </div>
          )}
          {session?.channelId && (
            <div>
              <span style={{ color: '#555' }}>channel: </span>
              {session.channelId}
            </div>
          )}
          {session?.peerId && (
            <div>
              <span style={{ color: '#555' }}>peer: </span>
              {truncate(session.peerId, 22)}
            </div>
          )}
          {session?.peerLabel && (
            <div>
              <span style={{ color: '#555' }}>label: </span>
              {truncate(session.peerLabel, 22)}
            </div>
          )}
          <div>
            <span style={{ color: '#555' }}>runs: </span>
            <span style={{ color: '#5599ff' }}>{runCount}</span>
          </div>
          {session?.origin && session.origin !== 'unknown' && (
            <div>
              <span style={{ color: '#555' }}>origin: </span>
              {session.origin}
            </div>
          )}
          {session?.updatedAtMs && (
            <div>
              <span style={{ color: '#555' }}>active: </span>
              {formatRelativeTime(session.updatedAtMs)}
            </div>
          )}
          {session?.createdAtMs && (
            <div>
              <span style={{ color: '#555' }}>created: </span>
              {formatRelativeTime(session.createdAtMs)}
            </div>
          )}
          {session?.active && (
            <div>
              <span
                style={{
                  display: 'inline-block',
                  width: '6px',
                  height: '6px',
                  borderRadius: '50%',
                  background: '#00ff88',
                  marginRight: '4px',
                }}
              />
              <span style={{ color: '#00ff88' }}>active</span>
            </div>
          )}
        </div>
      </div>

      {/* Runs list */}
      <div style={{ flex: 1, overflowY: 'auto' }}>
        <div
          style={{
            padding: '6px 12px',
            color: '#666',
            textTransform: 'uppercase',
            fontSize: '10px',
            letterSpacing: '0.5px',
            borderBottom: '1px solid #1a1a1a',
          }}
        >
          Runs ({runs.length}
          {runCount > runs.length ? ` of ${runCount}` : ''})
          {loading && <span style={{ color: '#444', marginLeft: '8px' }}>loading…</span>}
          {!sessionDetail && !loading && sessionKey && (
            <span style={{ color: '#444', marginLeft: '8px' }}>fetching…</span>
          )}
        </div>

        {runs.length === 0 && sessionDetail ? (
          <div style={{ padding: '16px 12px', color: '#555' }}>No run history available</div>
        ) : (
          runs.map((run, idx) => <RunRow key={idx} run={run} index={idx} />)
        )}
      </div>
    </div>
  );
}

function RunRow({ run, index }: { run: SessionRunSummary; index: number }) {
  const [expanded, setExpanded] = useState(false);

  const okColor = run.ok === true ? '#00ff88' : run.ok === false ? '#ff4444' : '#666';
  const totalTokens = run.tokens?.total ?? 0;
  const cost = run.tokens?.costUsd ?? 0;

  return (
    <div
      style={{
        borderBottom: '1px solid #1a1a1a',
        cursor: 'pointer',
        background: expanded ? '#0f1a0f' : 'transparent',
      }}
      onClick={() => setExpanded((v) => !v)}
    >
      {/* Summary row */}
      <div
        style={{ display: 'flex', gap: '8px', padding: '6px 12px', alignItems: 'flex-start' }}
      >
        <span
          style={{ color: '#444', width: '18px', textAlign: 'right', flexShrink: 0, marginTop: '1px' }}
        >
          {index + 1}.
        </span>
        <span
          style={{
            width: '8px',
            height: '8px',
            borderRadius: '50%',
            background: okColor,
            flexShrink: 0,
            marginTop: '3px',
          }}
        />
        <div style={{ flex: 1, overflow: 'hidden' }}>
          {run.prompt ? (
            <div
              style={{
                color: '#d0d0d0',
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
              }}
            >
              {run.prompt}
            </div>
          ) : (
            <div style={{ color: '#444', fontStyle: 'italic' }}>no prompt</div>
          )}
          <div
            style={{
              display: 'flex',
              gap: '8px',
              marginTop: '2px',
              color: '#666',
              fontSize: '10px',
              flexWrap: 'wrap',
            }}
          >
            {run.engine && <span style={{ color: '#5599ff' }}>{run.engine}</span>}
            {run.durationMs != null && <span>{formatDuration(run.durationMs)}</span>}
            {run.toolCallCount > 0 && (
              <span style={{ color: '#ffaa00' }}>{run.toolCallCount} tool{run.toolCallCount !== 1 ? 's' : ''}</span>
            )}
            {totalTokens > 0 && (
              <span>
                {totalTokens} tok{cost > 0 ? ` · $${cost.toFixed(4)}` : ''}
              </span>
            )}
            {run.error && (
              <span style={{ color: '#ff4444' }}>err: {truncate(run.error, 40)}</span>
            )}
            {run.runId && (
              <span style={{ color: '#666' }}>run: {truncate(run.runId, 16)}</span>
            )}
            {run.eventCount != null && run.eventCount > 0 && (
              <span style={{ color: '#888' }}>{run.eventCount} ev</span>
            )}
          </div>
        </div>
        <span style={{ color: '#444', fontSize: '10px', flexShrink: 0 }}>
          {expanded ? '▼' : '▶'}
        </span>
      </div>

      {/* Expanded detail */}
      {expanded && (
        <div style={{ padding: '0 12px 10px 40px' }}>
          {run.answer && (
            <div style={{ marginBottom: '8px' }}>
              <div
                style={{
                  color: '#555',
                  marginBottom: '3px',
                  textTransform: 'uppercase',
                  fontSize: '10px',
                  letterSpacing: '0.5px',
                }}
              >
                Answer
              </div>
              <div
                style={{ color: '#aaa', whiteSpace: 'pre-wrap', wordBreak: 'break-word', lineHeight: '1.4' }}
              >
                {run.answer}
              </div>
            </div>
          )}
          {run.promptFull && run.promptFull !== run.prompt && (
            <div style={{ marginBottom: '8px' }}>
              <div
                style={{
                  color: '#555',
                  marginBottom: '3px',
                  textTransform: 'uppercase',
                  fontSize: '10px',
                  letterSpacing: '0.5px',
                }}
              >
                Prompt Full
              </div>
              <pre
                style={{
                  margin: 0,
                  maxHeight: '180px',
                  overflowY: 'auto',
                  background: '#111',
                  border: '1px solid #222',
                  padding: '6px',
                  color: '#aaa',
                  whiteSpace: 'pre-wrap',
                  wordBreak: 'break-word',
                }}
              >
                {run.promptFull}
              </pre>
            </div>
          )}
          {run.answerFull && run.answerFull !== run.answer && (
            <div style={{ marginBottom: '8px' }}>
              <div
                style={{
                  color: '#555',
                  marginBottom: '3px',
                  textTransform: 'uppercase',
                  fontSize: '10px',
                  letterSpacing: '0.5px',
                }}
              >
                Answer Full
              </div>
              <pre
                style={{
                  margin: 0,
                  maxHeight: '220px',
                  overflowY: 'auto',
                  background: '#111',
                  border: '1px solid #222',
                  padding: '6px',
                  color: '#aaa',
                  whiteSpace: 'pre-wrap',
                  wordBreak: 'break-word',
                }}
              >
                {run.answerFull}
              </pre>
            </div>
          )}
          {run.toolCalls.length > 0 && (
            <div style={{ marginBottom: '8px' }}>
              <div
                style={{
                  color: '#555',
                  marginBottom: '4px',
                  textTransform: 'uppercase',
                  fontSize: '10px',
                  letterSpacing: '0.5px',
                }}
              >
                Tool Calls ({run.toolCalls.length})
              </div>
              {run.toolCalls.map((tc, i) => (
                <div
                  key={i}
                  style={{
                    display: 'flex',
                    gap: '6px',
                    padding: '2px 0',
                    fontSize: '10px',
                    borderBottom: '1px solid #111',
                  }}
                >
                  <span style={{ color: '#5599ff', minWidth: '80px', flexShrink: 0 }}>
                    {tc.name ?? '?'}
                  </span>
                  {tc.kind && <span style={{ color: '#666' }}>{tc.kind}</span>}
                  {tc.ok !== null && tc.ok !== undefined && (
                    <span style={{ color: tc.ok ? '#00ff88' : '#ff4444' }}>
                      {tc.ok ? 'ok' : 'err'}
                    </span>
                  )}
                  {tc.detail && (
                    <span
                      style={{
                        color: '#555',
                        overflow: 'hidden',
                        textOverflow: 'ellipsis',
                        whiteSpace: 'nowrap',
                      }}
                    >
                      {tc.detail}
                    </span>
                  )}
                </div>
              ))}
            </div>
          )}
          {run.tokens && run.tokens.total > 0 && (
            <div style={{ color: '#555', fontSize: '10px' }}>
              tokens: {run.tokens.input} in + {run.tokens.output} out ={' '}
              {run.tokens.total} total
              {run.tokens.costUsd > 0 && ` · $${run.tokens.costUsd.toFixed(6)} USD`}
            </div>
          )}

          {Array.isArray(run.events) && run.events.length > 0 && (
            <div style={{ marginTop: '8px' }}>
              <div
                style={{
                  color: '#555',
                  marginBottom: '3px',
                  textTransform: 'uppercase',
                  fontSize: '10px',
                  letterSpacing: '0.5px',
                }}
              >
                Raw Events ({run.events.length})
              </div>
              <pre
                style={{
                  margin: 0,
                  maxHeight: '180px',
                  overflowY: 'auto',
                  background: '#111',
                  border: '1px solid #222',
                  padding: '6px',
                  color: '#aaa',
                  whiteSpace: 'pre-wrap',
                  wordBreak: 'break-word',
                }}
              >
                {JSON.stringify(run.events, null, 2)}
              </pre>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
