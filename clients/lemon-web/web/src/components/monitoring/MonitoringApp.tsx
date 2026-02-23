import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useControlPlane } from '../../rpc/useControlPlane';
import { useMonitoringStore } from '../../store/monitoringStore';
import type { ControlPlaneEventHandler } from '../../rpc/controlPlaneTransport';
import type { MonitoringSession, SessionDetail } from '../../../../shared/src/monitoringTypes';
import { StatusStrip } from './StatusStrip';
import { AgentSessionsSidebar } from './AgentSessionsSidebar';
import { SessionsExplorer } from './SessionsExplorer';
import { SessionDetailPanel } from './SessionDetailPanel';
import { RunInspector } from './RunInspector';
import { TaskInspector } from './TaskInspector';
import { EventFeed } from './EventFeed';
import { CronInspector } from './CronInspector';
import type { FeedEvent } from '../../../../shared/src/monitoringTypes';

type MonitoringScreen = 'overview' | 'sessions' | 'run' | 'tasks' | 'cron' | 'events';

// ============================================================================
// OverviewPanel (inline component)
// ============================================================================

interface OverviewPanelProps {
  onNavigate: (screen: MonitoringScreen) => void;
}

function OverviewPanel({ onNavigate }: OverviewPanelProps) {
  const instance = useMonitoringStore((s) => s.instance);
  const activeSessions = useMonitoringStore((s) => s.sessions.active);
  const historicalSessions = useMonitoringStore((s) => s.sessions.historical);
  const agents = useMonitoringStore((s) => s.agents);
  const eventFeed = useMonitoringStore((s) => s.eventFeed);

  const activeSessionCount = Object.keys(activeSessions).length;
  const totalSessionCount = useMemo(() => {
    const allKeys = new Set<string>([
      ...Object.keys(activeSessions),
      ...historicalSessions.map((s) => s.sessionKey),
    ]);
    return allKeys.size;
  }, [activeSessions, historicalSessions]);

  const agentCount = Object.keys(agents).length;

  const recentErrors = useMemo<FeedEvent[]>(() => {
    return eventFeed
      .filter((ev) => ev.level === 'warn' || ev.level === 'error')
      .slice(-5)
      .reverse();
  }, [eventFeed]);

  const cardStyle: React.CSSProperties = {
    background: '#1a1a1a',
    border: '1px solid #333',
    borderRadius: '4px',
    padding: '12px 16px',
    flex: '1 1 180px',
    minWidth: '160px',
  };

  const navBtnStyle: React.CSSProperties = {
    padding: '6px 12px',
    border: '1px solid #333',
    borderRadius: '3px',
    background: '#1a1a1a',
    color: '#00ff88',
    fontFamily: 'monospace',
    fontSize: '11px',
    cursor: 'pointer',
  };

  return (
    <div data-testid="overview-panel" style={{ fontFamily: 'monospace', fontSize: '11px', color: '#e0e0e0' }}>
      <div style={{ fontWeight: 'bold', fontSize: '15px', marginBottom: '16px' }}>Overview</div>

      <div style={{ display: 'flex', gap: '12px', flexWrap: 'wrap', marginBottom: '16px' }}>
        {/* Health Card */}
        <div style={cardStyle}>
          <div style={{ color: '#888', marginBottom: '6px', textTransform: 'uppercase', fontSize: '10px' }}>
            Health
          </div>
          <div style={{ fontSize: '16px', color: instance.status === 'healthy' ? '#00ff88' : '#ffaa00' }}>
            {instance.status}
          </div>
          <div style={{ color: '#666', marginTop: '4px' }}>node: {instance.nodeId ?? '--'}</div>
          <div style={{ color: '#666' }}>
            up: {instance.uptimeMs != null ? `${Math.floor(instance.uptimeMs / 60_000)}m` : '--'}
          </div>
        </div>

        {/* Activity Card */}
        <div style={cardStyle}>
          <div style={{ color: '#888', marginBottom: '6px', textTransform: 'uppercase', fontSize: '10px' }}>
            Activity
          </div>
          <div>
            <span style={{ color: '#00ff88', fontSize: '16px' }}>{instance.activeRuns}</span>
            <span style={{ color: '#888' }}> active runs</span>
          </div>
          <div style={{ color: '#666', marginTop: '4px' }}>
            queued: {instance.queuedRuns} | completed: {instance.completedToday}
          </div>
        </div>

        {/* Sessions Card */}
        <div style={cardStyle}>
          <div style={{ color: '#888', marginBottom: '6px', textTransform: 'uppercase', fontSize: '10px' }}>
            Sessions
          </div>
          <div>
            <span style={{ color: '#5599ff', fontSize: '16px' }}>{activeSessionCount}</span>
            <span style={{ color: '#888' }}> active</span>
          </div>
          <div style={{ color: '#666', marginTop: '4px' }}>total loaded: {totalSessionCount}</div>
        </div>

        {/* Agents Card */}
        {agentCount > 0 && (
          <div style={cardStyle}>
            <div style={{ color: '#888', marginBottom: '6px', textTransform: 'uppercase', fontSize: '10px' }}>
              Agents
            </div>
            <div>
              <span style={{ color: '#ffaa00', fontSize: '16px' }}>{agentCount}</span>
              <span style={{ color: '#888' }}> registered</span>
            </div>
            <div style={{ color: '#666', marginTop: '4px' }}>
              {Object.values(agents).filter((a) => a.status === 'active').length} active
            </div>
          </div>
        )}
      </div>

      {/* Recent errors */}
      <div style={{ marginBottom: '16px' }}>
        <div style={{ color: '#888', marginBottom: '6px', textTransform: 'uppercase', fontSize: '10px' }}>
          Recent Warnings & Errors
        </div>
        {recentErrors.length === 0 ? (
          <div style={{ color: '#666' }}>No recent issues</div>
        ) : (
          recentErrors.map((ev) => (
            <div
              key={ev.id}
              style={{
                display: 'flex',
                gap: '8px',
                padding: '3px 0',
                borderBottom: '1px solid #1a1a1a',
              }}
            >
              <span style={{ color: ev.level === 'error' ? '#ff4444' : '#ffaa00', width: '40px' }}>
                {ev.level}
              </span>
              <span style={{ color: '#aaa' }}>{ev.eventName}</span>
            </div>
          ))
        )}
      </div>

      {/* Navigation */}
      <div style={{ display: 'flex', gap: '8px', flexWrap: 'wrap' }}>
        <button type="button" style={navBtnStyle} onClick={() => onNavigate('sessions')}>
          Sessions
        </button>
        <button type="button" style={navBtnStyle} onClick={() => onNavigate('events')}>
          Event Feed
        </button>
        <button type="button" style={navBtnStyle} onClick={() => onNavigate('tasks')}>
          Tasks
        </button>
        <button type="button" style={navBtnStyle} onClick={() => onNavigate('cron')}>
          Cron
        </button>
      </div>
    </div>
  );
}

// ============================================================================
// MonitoringApp
// ============================================================================

export function MonitoringApp() {
  const [activeScreen, setActiveScreen] = useState<MonitoringScreen>('overview');
  const prevConnectedRef = useRef(false);
  const [sessionDetailLoading, setSessionDetailLoading] = useState(false);

  const handleEvent = useCallback<ControlPlaneEventHandler>((eventName, payload, seq) => {
    useMonitoringStore.getState().applyEvent(eventName, payload, seq);
  }, []);

  const { connectionState, isConnected, request } = useControlPlane(handleEvent, {
    autoConnect: true,
  });

  // Fetch initial data when connected
  useEffect(() => {
    if (isConnected && !prevConnectedRef.current) {
      prevConnectedRef.current = true;
      fetchInitialData();
    } else if (!isConnected) {
      prevConnectedRef.current = false;
    }

    async function fetchInitialData() {
      const store = useMonitoringStore.getState();

      const results = await Promise.allSettled([
        request('status', {}),
        request('introspection.snapshot', { includeActiveSessions: true }),
        request('sessions.list', { limit: 100 }),
        request('sessions.active.list', {}),
        request('runs.active.list', {}),
        request('runs.recent.list', { limit: 50 }),
        request('tasks.active.list', { includeEvents: true, includeRecord: true, eventLimit: 200 }),
        request('tasks.recent.list', { limit: 200, includeEvents: true, includeRecord: true, eventLimit: 200 }),
        request('agents.list', {}),
        request('cron.status', {}),
        request('cron.list', {}),
      ]);

      const [
        statusRes,
        snapshotRes,
        sessionsRes,
        activeSessionsRes,
        runsActiveRes,
        runsRecentRes,
        tasksActiveRes,
        tasksRecentRes,
        agentsRes,
        cronStatusRes,
        cronListRes,
      ] = results;

      // Apply agents first so session counts are accurate
      if (agentsRes.status === 'fulfilled') {
        const val = agentsRes.value as Record<string, unknown>;
        store.applyAgentsList((val['agents'] as unknown[]) ?? []);
      }

      // snapshot includes activeSessions, sessions (historical), agents, run counts
      if (snapshotRes.status === 'fulfilled') {
        store.applySnapshot(snapshotRes.value as Record<string, unknown>);
      }

      // Dedicated requests override snapshot data (more targeted/fresh)
      if (sessionsRes.status === 'fulfilled') {
        const val = sessionsRes.value as Record<string, unknown>;
        store.applySessionsList((val['sessions'] as unknown[]) ?? []);
      }
      if (activeSessionsRes.status === 'fulfilled') {
        const val = activeSessionsRes.value as Record<string, unknown>;
        store.applySessionsActiveList((val['sessions'] as unknown[]) ?? []);
      }
      if (runsActiveRes.status === 'fulfilled') {
        store.applyRunsActiveList(runsActiveRes.value);
      }
      if (runsRecentRes.status === 'fulfilled') {
        store.applyRunsRecentList(runsRecentRes.value);
      }
      if (tasksActiveRes.status === 'fulfilled') {
        const val = tasksActiveRes.value as Record<string, unknown>;
        store.applyTasksActiveList((val['tasks'] as unknown[]) ?? []);
      }
      if (tasksRecentRes.status === 'fulfilled') {
        const val = tasksRecentRes.value as Record<string, unknown>;
        store.applyTasksRecentList((val['tasks'] as unknown[]) ?? []);
      }
      if (cronStatusRes.status === 'fulfilled') {
        store.applyCronStatus(cronStatusRes.value);
      }
      if (cronListRes.status === 'fulfilled') {
        store.applyCronList(cronListRes.value);
      }

      if (runsActiveRes.status === 'fulfilled') {
        const payload = runsActiveRes.value as Record<string, unknown>;
        const runs = Array.isArray(payload['runs']) ? (payload['runs'] as Array<Record<string, unknown>>) : [];
        await Promise.allSettled(
          runs
            .map((run) => run['runId'])
            .filter((runId): runId is string => typeof runId === 'string' && runId.length > 0)
            .map((runId) => request('events.subscribe', { runId }))
        );
      }

      // Apply status counts to instance health
      if (statusRes.status === 'fulfilled') {
        const val = statusRes.value as Record<string, unknown>;
        const runs = (val['runs'] ?? {}) as Record<string, unknown>;
        const server = (val['server'] ?? {}) as Record<string, unknown>;
        const connections = (val['connections'] ?? {}) as Record<string, unknown>;
        useMonitoringStore.setState((s) => ({
          instance: {
            ...s.instance,
            activeRuns: typeof runs['active'] === 'number' ? runs['active'] : s.instance.activeRuns,
            queuedRuns: typeof runs['queued'] === 'number' ? runs['queued'] : s.instance.queuedRuns,
            completedToday:
              typeof runs['completed_today'] === 'number'
                ? runs['completed_today']
                : s.instance.completedToday,
            connectedClients:
              typeof connections['active'] === 'number'
                ? connections['active']
                : s.instance.connectedClients,
            version: typeof server['version'] === 'string' ? server['version'] : s.instance.version,
            uptimeMs:
              typeof server['uptime_ms'] === 'number' ? server['uptime_ms'] : s.instance.uptimeMs,
            status: 'healthy',
            lastUpdatedMs: Date.now(),
          },
        }));
      }
    }
  }, [isConnected, request]);

  // Load session detail when selected session changes
  const selectedSessionKey = useMonitoringStore((s) => s.ui.selectedSessionKey);
  useEffect(() => {
    if (!selectedSessionKey || !isConnected) return;
    const existing = useMonitoringStore.getState().sessionDetails[selectedSessionKey];
    if (existing) return; // already loaded

    setSessionDetailLoading(true);
    request('session.detail', {
      sessionKey: selectedSessionKey,
      limit: 100,
      historyLimit: 1500,
      eventLimit: 500,
      toolCallLimit: 250,
      includeRawEvents: true,
      includeRunRecord: true,
      includeFullText: true,
    })
      .then((result) => {
        const r = result as Record<string, unknown>;
        const detail: SessionDetail = {
          sessionKey: selectedSessionKey,
          session: (r['session'] ?? {}) as Partial<MonitoringSession>,
          runs: Array.isArray(r['runs']) ? (r['runs'] as SessionDetail['runs']) : [],
          runCount: typeof r['runCount'] === 'number' ? r['runCount'] : 0,
          loadedAtMs: Date.now(),
        };
        useMonitoringStore.getState().applySessionDetail(detail);
      })
      .catch(() => {
        // Store empty detail so we don't retry on every render
        useMonitoringStore.getState().applySessionDetail({
          sessionKey: selectedSessionKey,
          session: {},
          runs: [],
          runCount: 0,
          loadedAtMs: Date.now(),
        });
      })
      .finally(() => setSessionDetailLoading(false));
  }, [selectedSessionKey, isConnected, request]);

  const handleSelectSession = useCallback((sessionKey: string) => {
    useMonitoringStore.getState().setSelectedSession(sessionKey);
    setActiveScreen('sessions');
  }, []);

  const handleSelectRun = useCallback((runId: string) => {
    useMonitoringStore.getState().setSelectedRun(runId);
    setActiveScreen('run');
  }, []);

  const handleNavigateToTasks = useCallback(() => {
    setActiveScreen('tasks');
  }, []);

  const navStyle = (screen: MonitoringScreen): React.CSSProperties => ({
    padding: '4px 10px',
    border: 'none',
    borderBottom: activeScreen === screen ? '2px solid #00ff88' : '2px solid transparent',
    background: 'transparent',
    color: activeScreen === screen ? '#00ff88' : '#888',
    fontFamily: 'monospace',
    fontSize: '11px',
    cursor: 'pointer',
    textTransform: 'uppercase',
  });

  return (
    <div
      data-testid="monitoring-app"
      style={{
        display: 'flex',
        flexDirection: 'column',
        height: '100vh',
        fontFamily: 'monospace',
        background: '#0f0f0f',
        color: '#e0e0e0',
      }}
    >
      <StatusStrip connectionState={connectionState} />

      {/* Nav bar */}
      <div
        style={{
          display: 'flex',
          gap: '4px',
          padding: '0 16px',
          background: '#141414',
          borderBottom: '1px solid #333',
        }}
      >
        <button type="button" style={navStyle('overview')} onClick={() => setActiveScreen('overview')}>
          Overview
        </button>
        <button type="button" style={navStyle('sessions')} onClick={() => setActiveScreen('sessions')}>
          Sessions
        </button>
        <button type="button" style={navStyle('run')} onClick={() => setActiveScreen('run')}>
          Run
        </button>
        <button type="button" style={navStyle('tasks')} onClick={() => setActiveScreen('tasks')}>
          Tasks
        </button>
        <button type="button" style={navStyle('cron')} onClick={() => setActiveScreen('cron')}>
          Cron
        </button>
        <button type="button" style={navStyle('events')} onClick={() => setActiveScreen('events')}>
          Events
        </button>
      </div>

      <div style={{ display: 'flex', flex: 1, overflow: 'hidden' }}>
        <AgentSessionsSidebar
          onSelectSession={handleSelectSession}
          onSelectRun={handleSelectRun}
        />

        {/* Sessions screen: split layout — table left, detail right */}
        {activeScreen === 'sessions' ? (
          <div style={{ flex: 1, display: 'flex', overflow: 'hidden' }}>
            <div style={{ flex: '0 0 55%', overflow: 'auto', padding: '16px', borderRight: '1px solid #222' }}>
              <SessionsExplorer />
            </div>
            <div style={{ flex: '0 0 45%', overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
              <SessionDetailPanel
                sessionKey={selectedSessionKey}
                loading={sessionDetailLoading}
              />
            </div>
          </div>
        ) : (
          <main style={{ flex: 1, overflow: 'auto', padding: '16px' }}>
            {activeScreen === 'overview' && <OverviewPanel onNavigate={setActiveScreen} />}
            {activeScreen === 'run' && <RunInspector onNavigateToTasks={handleNavigateToTasks} request={request} />}
            {activeScreen === 'tasks' && <TaskInspector />}
            {activeScreen === 'cron' && <CronInspector request={request} />}
            {activeScreen === 'events' && <EventFeed />}
          </main>
        )}

        {activeScreen !== 'events' && <EventFeed collapsed />}
      </div>
    </div>
  );
}
