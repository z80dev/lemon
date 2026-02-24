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
import { RunnersInspector } from './RunnersInspector';
import type { FeedEvent } from '../../../../shared/src/monitoringTypes';

type MonitoringScreen = 'overview' | 'sessions' | 'runners' | 'run' | 'tasks' | 'cron' | 'events';

function isHealthyChannelStatus(status: string | null): boolean {
  if (!status) return false;
  const normalized = status.toLowerCase();
  return normalized === 'connected' || normalized === 'running' || normalized === 'enabled' || normalized === 'active';
}

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
  const system = useMonitoringStore((s) => s.system);
  const eventFeed = useMonitoringStore((s) => s.eventFeed);
  const activeRuns = useMonitoringStore((s) => s.runs.active);
  const recentRuns = useMonitoringStore((s) => s.runs.recent);
  const activeTasks = useMonitoringStore((s) => s.tasks.active);
  const recentTasks = useMonitoringStore((s) => s.tasks.recent);

  const activeSessionCount = Object.keys(activeSessions).length;
  const totalSessionCount = useMemo(() => {
    const allKeys = new Set<string>([
      ...Object.keys(activeSessions),
      ...historicalSessions.map((s) => s.sessionKey),
    ]);
    return allKeys.size;
  }, [activeSessions, historicalSessions]);

  const agentCount = Object.keys(agents).length;
  const connectedChannels = system.channels.filter((c) => isHealthyChannelStatus(c.status)).length;
  const enabledTransports = system.transports.filter((t) => t.enabled).length;

  const recentErrors = useMemo<FeedEvent[]>(() => {
    return eventFeed
      .filter((ev) => ev.level === 'warn' || ev.level === 'error')
      .slice(-5)
      .reverse();
  }, [eventFeed]);

  const engineBreakdown = useMemo(() => {
    const taskEngines = [...Object.values(activeTasks), ...recentTasks]
      .map((t) => t.engine)
      .filter((e): e is string => typeof e === 'string' && e.trim().length > 0);
    const engines = [...Object.values(activeRuns), ...recentRuns]
      .map((r) => r.engine)
      .filter((e): e is string => typeof e === 'string' && e.trim().length > 0)
      .concat(taskEngines);
    const counts: Record<string, number> = {};
    for (const engine of engines) counts[engine] = (counts[engine] ?? 0) + 1;
    return Object.entries(counts).sort((a, b) => b[1] - a[1]).slice(0, 6);
  }, [activeRuns, recentRuns, activeTasks, recentTasks]);

  const taskStatusSummary = useMemo(() => {
    const all = [...Object.values(activeTasks), ...recentTasks];
    const summary: Record<string, number> = {};
    for (const task of all) summary[task.status] = (summary[task.status] ?? 0) + 1;
    return summary;
  }, [activeTasks, recentTasks]);

  const topTools = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const ev of eventFeed.slice(-1200)) {
      const p = (ev.payload ?? {}) as Record<string, unknown>;
      const action = (p['action'] ?? {}) as Record<string, unknown>;
      const toolName =
        (p['tool_name'] as string | undefined) ??
        (action['title'] as string | undefined) ??
        (p['name'] as string | undefined);
      const type = p['type'];
      if (type !== 'tool_use' && type !== 'tool_execution' && !toolName) continue;
      if (!toolName) continue;
      counts[toolName] = (counts[toolName] ?? 0) + 1;
    }
    const taskEventSources = [...Object.values(activeTasks), ...recentTasks];
    for (const task of taskEventSources) {
      if (!Array.isArray(task.events)) continue;
      for (const raw of task.events.slice(-80)) {
        if (!raw || typeof raw !== 'object' || Array.isArray(raw)) continue;
        const entry = raw as Record<string, unknown>;
        const details = (entry['details'] ?? {}) as Record<string, unknown>;
        const currentAction = (details['current_action'] ?? {}) as Record<string, unknown>;
        const title = currentAction['title'];
        if (typeof title === 'string' && title.trim().length > 0) {
          counts[title] = (counts[title] ?? 0) + 1;
        }
      }
    }
    return Object.entries(counts).sort((a, b) => b[1] - a[1]).slice(0, 8);
  }, [eventFeed, activeTasks, recentTasks]);

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

        <div style={cardStyle}>
          <div style={{ color: '#888', marginBottom: '6px', textTransform: 'uppercase', fontSize: '10px' }}>
            Infra
          </div>
          <div>
            <span style={{ color: '#ffaa00', fontSize: '16px' }}>{enabledTransports}</span>
            <span style={{ color: '#888' }}> transport(s) enabled</span>
          </div>
          <div style={{ color: '#666', marginTop: '4px' }}>
            channels: {connectedChannels}/{system.channels.length || 0} connected
          </div>
          <div style={{ color: '#666' }}>
            skills: {system.skills.enabled}/{system.skills.installed} enabled
          </div>
        </div>
      </div>

      <div style={{ marginBottom: '16px', display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '12px' }}>
        <div style={{ border: '1px solid #333', borderRadius: '4px', padding: '8px 10px', background: '#141414' }}>
          <div style={{ color: '#888', marginBottom: '4px', textTransform: 'uppercase', fontSize: '10px' }}>
            Channels
          </div>
          {system.channels.length === 0 ? (
            <div style={{ color: '#666' }}>No channel adapters detected</div>
          ) : (
            system.channels.slice(0, 8).map((channel, idx) => (
              <div key={`${channel.channelId ?? 'channel'}-${idx}`} style={{ display: 'flex', gap: '8px', padding: '2px 0' }}>
                <span style={{ color: '#aaa', minWidth: '90px' }}>{channel.channelId ?? 'unknown'}</span>
                <span style={{ color: '#666' }}>{channel.type ?? '--'}</span>
                <span style={{ marginLeft: 'auto', color: isHealthyChannelStatus(channel.status) ? '#00ff88' : '#888' }}>
                  {channel.status ?? 'unknown'}
                </span>
              </div>
            ))
          )}
        </div>
        <div style={{ border: '1px solid #333', borderRadius: '4px', padding: '8px 10px', background: '#141414' }}>
          <div style={{ color: '#888', marginBottom: '4px', textTransform: 'uppercase', fontSize: '10px' }}>
            Transports
          </div>
          {system.transports.length === 0 ? (
            <div style={{ color: '#666' }}>No gateway transports detected</div>
          ) : (
            system.transports.slice(0, 8).map((transport, idx) => (
              <div key={`${transport.transportId ?? 'transport'}-${idx}`} style={{ display: 'flex', gap: '8px', padding: '2px 0' }}>
                <span style={{ color: '#aaa', minWidth: '90px' }}>{transport.transportId ?? 'unknown'}</span>
                <span style={{ color: '#666', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {transport.module ?? '--'}
                </span>
                <span style={{ marginLeft: 'auto', color: transport.enabled ? '#00ff88' : '#888' }}>
                  {transport.status ?? (transport.enabled ? 'enabled' : 'disabled')}
                </span>
              </div>
            ))
          )}
        </div>
      </div>

      <div style={{ marginBottom: '16px', display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '12px' }}>
        <div style={{ border: '1px solid #333', borderRadius: '4px', padding: '8px 10px', background: '#141414' }}>
          <div style={{ color: '#888', marginBottom: '4px', textTransform: 'uppercase', fontSize: '10px' }}>
            Runner Engines
          </div>
          {engineBreakdown.length === 0 ? (
            <div style={{ color: '#666' }}>No run engine data yet</div>
          ) : (
            engineBreakdown.map(([engine, count]) => (
              <div key={engine} style={{ display: 'flex', gap: '8px', padding: '2px 0' }}>
                <span style={{ color: '#aaa', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {engine}
                </span>
                <span style={{ marginLeft: 'auto', color: '#5599ff' }}>{count}</span>
              </div>
            ))
          )}
        </div>
        <div style={{ border: '1px solid #333', borderRadius: '4px', padding: '8px 10px', background: '#141414' }}>
          <div style={{ color: '#888', marginBottom: '4px', textTransform: 'uppercase', fontSize: '10px' }}>
            Task Status
          </div>
          {Object.keys(taskStatusSummary).length === 0 ? (
            <div style={{ color: '#666' }}>No task history loaded</div>
          ) : (
            Object.entries(taskStatusSummary)
              .sort((a, b) => b[1] - a[1])
              .map(([status, count]) => (
                <div key={status} style={{ display: 'flex', gap: '8px', padding: '2px 0' }}>
                  <span style={{ color: '#aaa' }}>{status}</span>
                  <span style={{ marginLeft: 'auto', color: status === 'error' || status === 'timeout' ? '#ff6666' : '#5599ff' }}>
                    {count}
                  </span>
                </div>
              ))
          )}
        </div>
      </div>

      <div style={{ marginBottom: '16px', border: '1px solid #333', borderRadius: '4px', padding: '8px 10px', background: '#141414' }}>
        <div style={{ color: '#888', marginBottom: '4px', textTransform: 'uppercase', fontSize: '10px' }}>
          Top Tools (Recent)
        </div>
        {topTools.length === 0 ? (
          <div style={{ color: '#666' }}>No tool activity detected yet</div>
        ) : (
          topTools.map(([tool, count]) => (
            <div key={tool} style={{ display: 'flex', gap: '8px', padding: '2px 0' }}>
              <span style={{ color: '#aaa', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {tool}
              </span>
              <span style={{ marginLeft: 'auto', color: '#ffaa00' }}>{count}</span>
            </div>
          ))
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
        <button type="button" style={navBtnStyle} onClick={() => onNavigate('runners')}>
          Runners
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
  const [refreshing, setRefreshing] = useState(false);
  const lastSessionPrefetchRef = useRef(0);
  const activeRunCount = useMonitoringStore((s) => s.instance.activeRuns);

  const handleEvent = useCallback<ControlPlaneEventHandler>((eventName, payload, seq) => {
    useMonitoringStore.getState().applyEvent(eventName, payload, seq);
  }, []);

  const { connectionState, isConnected, request } = useControlPlane(handleEvent, {
    autoConnect: true,
  });

  const prefetchSessionDetails = useCallback(
    async (sessionKeys: string[]) => {
      const now = Date.now();
      if (now - lastSessionPrefetchRef.current < 20_000) return;
      lastSessionPrefetchRef.current = now;

      const store = useMonitoringStore.getState();
      const candidates = sessionKeys
        .filter((key) => !store.sessionDetails[key])
        .slice(0, 6);

      await Promise.allSettled(
        candidates.map(async (sessionKey) => {
          const result = await request('session.detail', {
            sessionKey,
            limit: 20,
            historyLimit: 500,
            eventLimit: 120,
            toolCallLimit: 80,
            includeRawEvents: false,
            includeRunRecord: true,
            includeFullText: false,
          });

          const r = result as Record<string, unknown>;
          const detail: SessionDetail = {
            sessionKey,
            session: (r['session'] ?? {}) as Partial<MonitoringSession>,
            runs: Array.isArray(r['runs']) ? (r['runs'] as SessionDetail['runs']) : [],
            runCount: typeof r['runCount'] === 'number' ? r['runCount'] : 0,
            loadedAtMs: Date.now(),
          };
          useMonitoringStore.getState().applySessionDetail(detail);
        })
      );
    },
    [request]
  );

  const loadMonitoringData = useCallback(async () => {
    setRefreshing(true);
    try {
      const store = useMonitoringStore.getState();

      const results = await Promise.allSettled([
        request('status', {}),
        request('introspection.snapshot', { includeActiveSessions: true, sessionLimit: 250, activeLimit: 250 }),
        request('agent.directory.list', { includeSessions: true, limit: 250 }),
        request('sessions.list', { limit: 250 }),
        request('sessions.active.list', { limit: 250 }),
        request('runs.active.list', { limit: 200 }),
        request('runs.recent.list', { limit: 200 }),
        request('tasks.active.list', { limit: 200, includeEvents: true, includeRecord: true, eventLimit: 200 }),
        request('tasks.recent.list', { limit: 200, includeEvents: true, includeRecord: true, eventLimit: 200 }),
        request('agents.list', {}),
        request('channels.status', {}),
        request('transports.status', {}),
        request('skills.status', {}),
        request('cron.status', {}),
        request('cron.list', {}),
      ]);

      const [
        statusRes,
        snapshotRes,
        directoryRes,
        sessionsRes,
        activeSessionsRes,
        runsActiveRes,
        runsRecentRes,
        tasksActiveRes,
        tasksRecentRes,
        agentsRes,
        channelsRes,
        transportsRes,
        skillsRes,
        cronStatusRes,
        cronListRes,
      ] = results;

      if (agentsRes.status === 'fulfilled') {
        const val = agentsRes.value as Record<string, unknown>;
        store.applyAgentsList((val['agents'] as unknown[]) ?? []);
      }

      if (snapshotRes.status === 'fulfilled') {
        store.applySnapshot(snapshotRes.value as Record<string, unknown>);
      }

      if (directoryRes.status === 'fulfilled') {
        const val = directoryRes.value as Record<string, unknown>;
        if (Array.isArray(val['agents'])) store.applyAgentsList(val['agents'] as unknown[]);
        if (Array.isArray(val['sessions'])) store.applySessionsList(val['sessions'] as unknown[]);
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
      if (tasksRecentRes.status === 'fulfilled') {
        const val = tasksRecentRes.value as Record<string, unknown>;
        store.applyTasksRecentList((val['tasks'] as unknown[]) ?? []);
      }
      if (channelsRes.status === 'fulfilled') {
        store.applyChannelsStatus(channelsRes.value);
      }
      if (transportsRes.status === 'fulfilled') {
        store.applyTransportsStatus(transportsRes.value);
      }
      if (skillsRes.status === 'fulfilled') {
        const val = (skillsRes.value ?? {}) as Record<string, unknown>;
        useMonitoringStore.setState((s) => ({
          system: {
            ...s.system,
            skills: {
              installed:
                typeof val['installed'] === 'number' ? val['installed'] : s.system.skills.installed,
              enabled: typeof val['enabled'] === 'number' ? val['enabled'] : s.system.skills.enabled,
            },
          },
        }));
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

      if (statusRes.status === 'fulfilled') {
        store.applySystemStatus(statusRes.value);
      }

      const activeKeys = Object.keys(useMonitoringStore.getState().sessions.active);
      if (activeKeys.length > 0) {
        await prefetchSessionDetails(activeKeys);
      }
    } finally {
      setRefreshing(false);
    }
  }, [prefetchSessionDetails, request]);

  // Fetch initial data and run periodic refresh when connected
  useEffect(() => {
    if (isConnected && !prevConnectedRef.current) {
      prevConnectedRef.current = true;
      void request('events.subscribe', { topics: ['all', 'system', 'cron', 'channels', 'presence'] }).catch(() => {});
      void loadMonitoringData();
    } else if (!isConnected) {
      prevConnectedRef.current = false;
    }

    if (!isConnected) return;
    const intervalMs = activeRunCount > 0 ? 5_000 : 15_000;
    const interval = window.setInterval(() => {
      void loadMonitoringData();
    }, intervalMs);

    return () => {
      window.clearInterval(interval);
    };
  }, [isConnected, loadMonitoringData, activeRunCount]);

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
        <button type="button" style={navStyle('runners')} onClick={() => setActiveScreen('runners')}>
          Runners
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
        <button
          type="button"
          style={{
            marginLeft: 'auto',
            padding: '3px 8px',
            border: '1px solid #333',
            borderRadius: '3px',
            background: 'transparent',
            color: refreshing ? '#ffaa00' : '#888',
            fontFamily: 'monospace',
            fontSize: '10px',
            cursor: 'pointer',
            alignSelf: 'center',
          }}
          onClick={() => void loadMonitoringData()}
        >
          {refreshing ? 'Refreshing…' : 'Refresh'}
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
                onSelectRun={handleSelectRun}
              />
            </div>
          </div>
        ) : (
          <main style={{ flex: 1, overflow: 'auto', padding: '16px' }}>
            {activeScreen === 'overview' && <OverviewPanel onNavigate={setActiveScreen} />}
            {activeScreen === 'runners' && (
              <RunnersInspector request={request} onSelectRun={handleSelectRun} onNavigateToTasks={handleNavigateToTasks} />
            )}
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
