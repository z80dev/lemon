import { useCallback, useEffect, useMemo, useState } from 'react';
import { useMonitoringStore } from '../../store/monitoringStore';
import type { MonitoringCronRun } from '../../../../shared/src/monitoringTypes';

interface CronInspectorProps {
  request: <T = unknown>(method: string, params?: Record<string, unknown>) => Promise<T>;
}

function formatTimestamp(ms: number | null | undefined): string {
  if (!ms) return '--';
  return new Date(ms).toLocaleString('en-US', { hour12: false });
}

function formatDuration(ms: number | null | undefined): string {
  if (ms == null) return '--';
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.floor(ms / 60_000)}m ${Math.floor((ms % 60_000) / 1000)}s`;
}

export function CronInspector({ request }: CronInspectorProps) {
  const cronStatus = useMonitoringStore((s) => s.cron.status);
  const jobs = useMonitoringStore((s) => s.cron.jobs);
  const runsByJob = useMonitoringStore((s) => s.cron.runsByJob);
  const selectedJobId = useMonitoringStore((s) => s.cron.selectedJobId);
  const setSelectedJob = useMonitoringStore((s) => s.setSelectedCronJob);
  const applyCronRuns = useMonitoringStore((s) => s.applyCronRuns);

  const [loadingRuns, setLoadingRuns] = useState(false);
  const [expandedRunId, setExpandedRunId] = useState<string | null>(null);

  useEffect(() => {
    if (!selectedJobId && jobs.length > 0) {
      setSelectedJob(jobs[0]?.id ?? null);
    }
  }, [jobs, selectedJobId, setSelectedJob]);

  const loadRuns = useCallback(async (jobId: string) => {
    setLoadingRuns(true);
    try {
      const payload = await request('cron.runs', {
        id: jobId,
        limit: 200,
        includeOutput: true,
        includeMeta: true,
        includeRunRecord: true,
        includeIntrospection: true,
        introspectionLimit: 500,
      });
      applyCronRuns(jobId, payload);
    } finally {
      setLoadingRuns(false);
    }
  }, [applyCronRuns, request]);

  useEffect(() => {
    if (!selectedJobId) return;
    void loadRuns(selectedJobId);
  }, [selectedJobId, loadRuns]);

  const selectedRuns = useMemo<MonitoringCronRun[]>(() => {
    if (!selectedJobId) return [];
    return runsByJob[selectedJobId] ?? [];
  }, [runsByJob, selectedJobId]);

  return (
    <div data-testid="cron-inspector" style={{ fontFamily: 'monospace', fontSize: '11px', color: '#e0e0e0', height: '100%' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '12px', marginBottom: '10px' }}>
        <span style={{ fontWeight: 'bold', fontSize: '13px' }}>Cron Internals</span>
        {cronStatus && (
          <span style={{ color: '#888' }}>
            jobs: {cronStatus.jobCount} · active jobs: {cronStatus.activeJobs} · active runs: {cronStatus.activeRunCount ?? 0}
          </span>
        )}
        {selectedJobId && (
          <button
            type="button"
            onClick={() => void loadRuns(selectedJobId)}
            style={{
              marginLeft: 'auto',
              padding: '3px 8px',
              border: '1px solid #333',
              borderRadius: '3px',
              background: 'transparent',
              color: '#888',
              fontFamily: 'monospace',
              fontSize: '10px',
              cursor: 'pointer',
            }}
          >
            {loadingRuns ? 'Loading…' : 'Reload Runs'}
          </button>
        )}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '320px 1fr', gap: '12px', height: 'calc(100% - 40px)' }}>
        <div style={{ border: '1px solid #222', overflowY: 'auto' }}>
          {jobs.length === 0 ? (
            <div style={{ color: '#666', padding: '12px' }}>No cron jobs.</div>
          ) : (
            jobs.map((job) => (
              <button
                key={job.id}
                type="button"
                onClick={() => setSelectedJob(job.id)}
                style={{
                  width: '100%',
                  textAlign: 'left',
                  padding: '8px 10px',
                  border: 'none',
                  borderBottom: '1px solid #1a1a1a',
                  background: selectedJobId === job.id ? '#122018' : 'transparent',
                  color: selectedJobId === job.id ? '#00ff88' : '#ddd',
                  cursor: 'pointer',
                  fontFamily: 'monospace',
                  fontSize: '11px',
                }}
              >
                <div style={{ fontWeight: 'bold' }}>{job.name}</div>
                <div style={{ color: '#888', marginTop: '2px' }}>{job.id}</div>
                <div style={{ color: '#666', marginTop: '2px' }}>
                  next: {formatTimestamp(job.nextRunAtMs)} · {job.enabled ? 'enabled' : 'disabled'}
                </div>
              </button>
            ))
          )}
        </div>

        <div style={{ border: '1px solid #222', overflowY: 'auto', padding: '8px' }}>
          {!selectedJobId ? (
            <div style={{ color: '#666' }}>Select a cron job</div>
          ) : selectedRuns.length === 0 ? (
            <div style={{ color: '#666' }}>No runs for this job.</div>
          ) : (
            selectedRuns.map((run) => {
              const expanded = expandedRunId === run.id;
              return (
                <div key={run.id} style={{ borderBottom: '1px solid #1a1a1a', marginBottom: '4px' }}>
                  <button
                    type="button"
                    onClick={() => setExpandedRunId(expanded ? null : run.id)}
                    style={{
                      width: '100%',
                      textAlign: 'left',
                      border: 'none',
                      background: 'transparent',
                      color: '#ddd',
                      fontFamily: 'monospace',
                      fontSize: '11px',
                      padding: '6px 4px',
                      cursor: 'pointer',
                    }}
                  >
                    <span style={{ color: '#5599ff' }}>{run.id}</span>
                    <span style={{ color: '#888' }}> · status: {run.status}</span>
                    <span style={{ color: '#888' }}> · {formatDuration(run.durationMs)}</span>
                    {run.routerRunId && <span style={{ color: '#666' }}> · run: {run.routerRunId}</span>}
                  </button>

                  {expanded && (
                    <div style={{ padding: '4px 8px 10px 8px', color: '#aaa' }}>
                      <div>started: {formatTimestamp(run.startedAtMs)}</div>
                      <div>completed: {formatTimestamp(run.completedAtMs)}</div>
                      {run.agentId && <div>agent: {run.agentId}</div>}
                      {run.sessionKey && <div>session: {run.sessionKey}</div>}
                      {run.error && <div style={{ color: '#ff6666' }}>error: {run.error}</div>}
                      {run.output && (
                        <div style={{ marginTop: '6px' }}>
                          <div style={{ color: '#666', marginBottom: '2px' }}>output</div>
                          <pre style={{ margin: 0, whiteSpace: 'pre-wrap', color: '#ddd', background: '#111', padding: '6px', border: '1px solid #222' }}>
                            {run.output}
                          </pre>
                        </div>
                      )}
                      {Boolean(run.meta) && (
                        <div style={{ marginTop: '6px' }}>
                          <div style={{ color: '#666', marginBottom: '2px' }}>meta</div>
                          <pre style={{ margin: 0, whiteSpace: 'pre-wrap', color: '#bbb', background: '#111', padding: '6px', border: '1px solid #222' }}>
                            {JSON.stringify(run.meta, null, 2)}
                          </pre>
                        </div>
                      )}
                      {Boolean(run.runRecord) && (
                        <div style={{ marginTop: '6px' }}>
                          <div style={{ color: '#666', marginBottom: '2px' }}>runRecord</div>
                          <pre style={{ margin: 0, whiteSpace: 'pre-wrap', color: '#bbb', background: '#111', padding: '6px', border: '1px solid #222', maxHeight: '240px', overflowY: 'auto' }}>
                            {JSON.stringify(run.runRecord, null, 2)}
                          </pre>
                        </div>
                      )}
                      {Array.isArray(run.introspection) && run.introspection.length > 0 && (
                        <div style={{ marginTop: '6px' }}>
                          <div style={{ color: '#666', marginBottom: '2px' }}>
                            introspection ({run.introspection.length})
                          </div>
                          <pre style={{ margin: 0, whiteSpace: 'pre-wrap', color: '#bbb', background: '#111', padding: '6px', border: '1px solid #222', maxHeight: '240px', overflowY: 'auto' }}>
                            {JSON.stringify(run.introspection, null, 2)}
                          </pre>
                        </div>
                      )}
                    </div>
                  )}
                </div>
              );
            })
          )}
        </div>
      </div>
    </div>
  );
}
