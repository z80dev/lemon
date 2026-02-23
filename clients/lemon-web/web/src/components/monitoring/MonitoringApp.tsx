import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useControlPlane } from '../../rpc/useControlPlane';
import { useMonitoringStore } from '../../store/monitoringStore';
import type { ControlPlaneEventHandler } from '../../rpc/controlPlaneTransport';
import { StatusStrip } from './StatusStrip';
import { AgentSessionsSidebar } from './AgentSessionsSidebar';
import { SessionsExplorer } from './SessionsExplorer';
import { RunInspector } from './RunInspector';
import { TaskInspector } from './TaskInspector';
import { EventFeed } from './EventFeed';
import type { FeedEvent } from '../../../../shared/src/monitoringTypes';

type MonitoringScreen = 'overview' | 'sessions' | 'run' | 'tasks' | 'events';

// ============================================================================
// OverviewPanel (inline component)
// ============================================================================

interface OverviewPanelProps {
  onNavigate: (screen: MonitoringScreen) => void;
}

function OverviewPanel({ onNavigate }: OverviewPanelProps) {
  const instance = useMonitoringStore((s) => s.instance);
  const activeSessions = useMonitoringStore((s) => s.sessions.active);
  const eventFeed = useMonitoringStore((s) => s.eventFeed);

  const activeSessionCount = Object.keys(activeSessions).length;

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
    flex: '1 1 200px',
    minWidth: '200px',
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
      <div style={{ fontWeight: 'bold', fontSize: '15px', marginBottom: '16px' }}>
        Overview
      </div>

      <div style={{ display: 'flex', gap: '12px', flexWrap: 'wrap', marginBottom: '16px' }}>
        {/* Health Card */}
        <div style={cardStyle}>
          <div style={{ color: '#888', marginBottom: '6px', textTransform: 'uppercase', fontSize: '10px' }}>
            Health
          </div>
          <div style={{ fontSize: '16px', color: instance.status === 'healthy' ? '#00ff88' : '#ffaa00' }}>
            {instance.status}
          </div>
          <div style={{ color: '#666', marginTop: '4px' }}>
            node: {instance.nodeId ?? '--'}
          </div>
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
        </div>
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
        request('tasks.active.list', {}),
      ]);

      const [
        _statusRes,
        snapshotRes,
        sessionsRes,
        activeSessionsRes,
        runsActiveRes,
        runsRecentRes,
        tasksActiveRes,
      ] = results;

      if (snapshotRes.status === 'fulfilled') {
        store.applySnapshot(snapshotRes.value as Record<string, unknown>);
      }
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
    }
  }, [isConnected, request]);

  const handleSelectSession = useCallback(
    (sessionKey: string) => {
      useMonitoringStore.getState().setSelectedSession(sessionKey);
      setActiveScreen('sessions');
    },
    []
  );

  const handleSelectRun = useCallback(
    (runId: string) => {
      useMonitoringStore.getState().setSelectedRun(runId);
      setActiveScreen('run');
    },
    []
  );

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
        <button type="button" style={navStyle('events')} onClick={() => setActiveScreen('events')}>
          Events
        </button>
      </div>

      <div style={{ display: 'flex', flex: 1, overflow: 'hidden' }}>
        <AgentSessionsSidebar
          onSelectSession={handleSelectSession}
          onSelectRun={handleSelectRun}
        />
        <main style={{ flex: 1, overflow: 'auto', padding: '16px' }}>
          {activeScreen === 'overview' && <OverviewPanel onNavigate={setActiveScreen} />}
          {activeScreen === 'sessions' && <SessionsExplorer />}
          {activeScreen === 'run' && <RunInspector onNavigateToTasks={handleNavigateToTasks} />}
          {activeScreen === 'tasks' && <TaskInspector />}
          {activeScreen === 'events' && <EventFeed />}
        </main>
        {activeScreen !== 'events' && <EventFeed collapsed />}
      </div>
    </div>
  );
}
