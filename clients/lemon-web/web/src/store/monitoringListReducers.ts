import type { MonitoringState } from './monitoringStore';
import type {
  MonitoringChannel,
  MonitoringCronJob,
  MonitoringCronRun,
  MonitoringCronStatus,
  MonitoringRun,
  MonitoringSession,
  MonitoringTask,
  MonitoringTransport,
} from '../../../shared/src/monitoringTypes';
import {
  MAX_RECENT_RUNS,
  MAX_RECENT_TASKS,
  mergeSession,
  normalizeSession,
} from './monitoringReducerHelpers';

export function applyAgentsList(state: MonitoringState, agents: unknown[]): MonitoringState {
  const agentsMap: MonitoringState['agents'] = {};
  for (const raw of agents) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) continue;
    const agent = raw as Record<string, unknown>;
    const agentId = (agent['agentId'] ?? agent['id']) as string | undefined;
    if (!agentId) continue;
    const activeSessionCount =
      typeof agent['activeSessionCount'] === 'number'
        ? agent['activeSessionCount']
        : Object.values(state.sessions.active).filter((session) => session.agentId === agentId).length;
    const rawStatus = agent['status'] as string | undefined;
    const status: 'active' | 'idle' | 'unknown' =
      rawStatus === 'active' ? 'active' : rawStatus === 'idle' ? 'idle' : 'unknown';
    agentsMap[agentId] = {
      agentId,
      name: (agent['name'] ?? agentId) as string,
      status: activeSessionCount > 0 ? 'active' : status,
      activeSessionCount,
      sessionCount: typeof agent['sessionCount'] === 'number' ? agent['sessionCount'] : 0,
      routeCount: typeof agent['routeCount'] === 'number' ? agent['routeCount'] : 0,
      latestSessionKey: (agent['latestSessionKey'] ?? null) as string | null,
      latestUpdatedAtMs:
        typeof agent['latestUpdatedAtMs'] === 'number' ? agent['latestUpdatedAtMs'] : null,
      description: (agent['description'] ?? null) as string | null,
      model: (agent['model'] ?? null) as string | null,
      engine: (agent['engine'] ?? null) as string | null,
    };
  }
  return { ...state, agents: agentsMap };
}

export function applyRunsActiveList(
  state: MonitoringState,
  payload: { runs: MonitoringRun[]; total: number }
): MonitoringState {
  const active: Record<string, MonitoringRun> = {};
  for (const run of payload.runs) if (run.runId) active[run.runId] = run;
  return {
    ...state,
    runs: { ...state.runs, active },
    instance: { ...state.instance, activeRuns: Object.keys(active).length },
  };
}

export function applyRunsRecentList(
  state: MonitoringState,
  payload: { runs: MonitoringRun[]; total: number }
): MonitoringState {
  return { ...state, runs: { ...state.runs, recent: payload.runs.slice(0, MAX_RECENT_RUNS) } };
}

export function applySessionsActiveList(
  state: MonitoringState,
  sessions: unknown[]
): MonitoringState {
  const active: Record<string, MonitoringSession> = {};
  for (const raw of sessions) {
    const session = normalizeSession(raw);
    if (!session) continue;
    const existing =
      state.sessions.active[session.sessionKey] ??
      state.sessions.historical.find((item) => item.sessionKey === session.sessionKey) ??
      null;
    active[session.sessionKey] = mergeSession(existing, session);
  }
  return { ...state, sessions: { ...state.sessions, active } };
}

export function applySessionsList(state: MonitoringState, sessions: unknown[]): MonitoringState {
  const previousByKey = new Map<string, MonitoringSession>();
  for (const session of state.sessions.historical) previousByKey.set(session.sessionKey, session);
  for (const session of Object.values(state.sessions.active)) {
    previousByKey.set(session.sessionKey, session);
  }

  const historical = sessions
    .map(normalizeSession)
    .filter((session): session is MonitoringSession => session !== null)
    .map((incoming) => mergeSession(previousByKey.get(incoming.sessionKey) ?? null, incoming))
    .sort((a, b) => (b.updatedAtMs ?? 0) - (a.updatedAtMs ?? 0));
  return { ...state, sessions: { ...state.sessions, historical } };
}

export function applyTasksActiveList(
  state: MonitoringState,
  tasks: MonitoringTask[]
): MonitoringState {
  const active: Record<string, MonitoringTask> = {};
  for (const task of tasks) if (task.taskId) active[task.taskId] = task;
  return { ...state, tasks: { ...state.tasks, active } };
}

export function applyTasksRecentList(
  state: MonitoringState,
  tasks: MonitoringTask[]
): MonitoringState {
  return { ...state, tasks: { ...state.tasks, recent: tasks.slice(0, MAX_RECENT_TASKS) } };
}

export function applyCronStatus(
  state: MonitoringState,
  status: MonitoringCronStatus
): MonitoringState {
  return { ...state, cron: { ...state.cron, status } };
}

export function applyCronList(
  state: MonitoringState,
  jobs: MonitoringCronJob[]
): MonitoringState {
  const normalized = jobs.map((job) => ({
    ...job,
    timezone: job.timezone ?? 'UTC',
    jitterSec: job.jitterSec ?? 0,
  }));
  return { ...state, cron: { ...state.cron, jobs: normalized } };
}

export function applyCronRuns(
  state: MonitoringState,
  jobId: string,
  runs: MonitoringCronRun[]
): MonitoringState {
  return {
    ...state,
    cron: { ...state.cron, runsByJob: { ...state.cron.runsByJob, [jobId]: runs } },
  };
}

export function applyChannelsStatus(state: MonitoringState, payload: unknown): MonitoringState {
  const record = (payload ?? {}) as Record<string, unknown>;
  const rawChannels = Array.isArray(record['channels'])
    ? record['channels']
    : Array.isArray(payload)
      ? payload
      : [];
  const channels: MonitoringChannel[] = [];
  for (const raw of rawChannels) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) continue;
    const channel = raw as Record<string, unknown>;
    channels.push({
      channelId: (channel['channelId'] ?? channel['channel_id'] ?? null) as string | null,
      type: (channel['type'] ?? null) as string | null,
      status: (channel['status'] ?? null) as string | null,
      accountId: (channel['accountId'] ?? channel['account_id'] ?? null) as string | null,
      capabilities:
        channel['capabilities'] &&
        typeof channel['capabilities'] === 'object' &&
        !Array.isArray(channel['capabilities'])
          ? (channel['capabilities'] as Record<string, unknown>)
          : undefined,
    });
  }
  return { ...state, system: { ...state.system, channels } };
}

export function applyTransportsStatus(state: MonitoringState, payload: unknown): MonitoringState {
  const record = (payload ?? {}) as Record<string, unknown>;
  const rawTransports = Array.isArray(record['transports'])
    ? record['transports']
    : Array.isArray(payload)
      ? payload
      : [];
  const transports: MonitoringTransport[] = rawTransports
    .map((raw) => {
      if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
      const transport = raw as Record<string, unknown>;
      return {
        transportId: (transport['transportId'] ?? transport['transport_id'] ?? null) as
          | string
          | null,
        module: (transport['module'] ?? null) as string | null,
        enabled: Boolean(transport['enabled']),
        status: (transport['status'] ?? null) as string | null,
      };
    })
    .filter((transport): transport is MonitoringTransport => transport !== null);
  return { ...state, system: { ...state.system, transports } };
}

export function applySystemStatus(state: MonitoringState, payload: unknown): MonitoringState {
  const record = (payload ?? {}) as Record<string, unknown>;
  const server = (record['server'] ?? {}) as Record<string, unknown>;
  const connections = (record['connections'] ?? {}) as Record<string, unknown>;
  const runs = (record['runs'] ?? {}) as Record<string, unknown>;
  const skills = (record['skills'] ?? {}) as Record<string, unknown>;
  return {
    ...state,
    instance: {
      ...state.instance,
      activeRuns: typeof runs['active'] === 'number' ? runs['active'] : state.instance.activeRuns,
      queuedRuns: typeof runs['queued'] === 'number' ? runs['queued'] : state.instance.queuedRuns,
      completedToday:
        typeof runs['completed_today'] === 'number'
          ? runs['completed_today']
          : state.instance.completedToday,
      connectedClients:
        typeof connections['active'] === 'number'
          ? connections['active']
          : state.instance.connectedClients,
      version: typeof server['version'] === 'string' ? server['version'] : state.instance.version,
      uptimeMs:
        typeof server['uptime_ms'] === 'number' ? server['uptime_ms'] : state.instance.uptimeMs,
      status: 'healthy',
      lastUpdatedMs: Date.now(),
    },
    system: {
      ...state.system,
      skills: {
        installed:
          typeof skills['installed'] === 'number'
            ? skills['installed']
            : state.system.skills.installed,
        enabled:
          typeof skills['enabled'] === 'number' ? skills['enabled'] : state.system.skills.enabled,
      },
    },
  };
}
