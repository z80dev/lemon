import type { MonitoringState } from './monitoringStore';
import type {
  FeedEvent,
  MonitoringRun,
  MonitoringSession,
  MonitoringTask,
  MonitoringCronJob,
  MonitoringCronRun,
  MonitoringCronStatus,
} from '../../../shared/src/monitoringTypes';

export const MAX_FEED_EVENTS = 5000;
const MAX_RECENT_RUNS = 200;
const MAX_RECENT_TASKS = 200;

// ============================================================================
// ID generation
// ============================================================================

let feedEventCounter = 0;
function nextFeedId(seq: number): string {
  feedEventCounter += 1;
  return `feed-${seq}-${feedEventCounter}`;
}

// ============================================================================
// Snapshot application
// ============================================================================

/**
 * Apply a snapshot response (from introspection.snapshot, sessions.active.list, etc.)
 */
export function applySnapshot(
  state: MonitoringState,
  snapshot: Record<string, unknown>
): MonitoringState {
  let next = state;

  // Agents (from introspection.snapshot "agents" field)
  const snapshotAgents = snapshot['agents'];
  if (Array.isArray(snapshotAgents)) {
    next = applyAgentsList(next, snapshotAgents);
  }

  // Active sessions (introspection.snapshot uses "activeSessions" key)
  const activeSessions = snapshot['activeSessions'];
  if (Array.isArray(activeSessions)) {
    next = applySessionsActiveList(next, activeSessions);
  }

  // Historical sessions (introspection.snapshot uses "sessions" key)
  const historicalSessions = snapshot['sessions'];
  if (Array.isArray(historicalSessions)) {
    next = applySessionsList(next, historicalSessions);
  }

  // Run counts from introspection.snapshot "runs" field (it's {active:int, queued:int, completed_today:int})
  const snapshotRuns = snapshot['runs'];
  if (snapshotRuns && typeof snapshotRuns === 'object' && !Array.isArray(snapshotRuns)) {
    const r = snapshotRuns as Record<string, unknown>;
    if (typeof r['active'] === 'number' || typeof r['queued'] === 'number' || typeof r['completed_today'] === 'number') {
      next = {
        ...next,
        instance: {
          ...next.instance,
          activeRuns: typeof r['active'] === 'number' ? r['active'] : next.instance.activeRuns,
          queuedRuns: typeof r['queued'] === 'number' ? r['queued'] : next.instance.queuedRuns,
          completedToday: typeof r['completed_today'] === 'number' ? r['completed_today'] : next.instance.completedToday,
          lastUpdatedMs: Date.now(),
        },
      };
    }
  }

  // Tasks (only present when snapshot comes from hello-ok or custom format)
  const snapshotTasks = snapshot['tasks'];
  if (snapshotTasks && typeof snapshotTasks === 'object' && !Array.isArray(snapshotTasks)) {
    const tasksObj = snapshotTasks as Record<string, unknown>;
    if (Array.isArray(tasksObj['active'])) {
      next = applyTasksActiveList(next, tasksObj['active'] as MonitoringTask[]);
    }
    if (Array.isArray(tasksObj['recent'])) {
      next = applyTasksRecentList(next, tasksObj['recent'] as MonitoringTask[]);
    }
  }

  const snapshotCron = snapshot['cron'];
  if (snapshotCron && typeof snapshotCron === 'object' && !Array.isArray(snapshotCron)) {
    const c = snapshotCron as Record<string, unknown>;
    next = applyCronStatus(next, {
      enabled: Boolean(c['enabled']),
      jobCount: typeof c['job_count'] === 'number' ? c['job_count'] : 0,
      activeJobs: typeof c['active_jobs'] === 'number' ? c['active_jobs'] : 0,
      nextRunAtMs: typeof c['next_run_at_ms'] === 'number' ? c['next_run_at_ms'] : null,
    });
  }

  // Instance health from snapshot (legacy/custom format)
  const health = snapshot['health'];
  if (health && typeof health === 'object' && !Array.isArray(health)) {
    const h = health as Record<string, unknown>;
    next = {
      ...next,
      instance: {
        ...next.instance,
        status: (h['status'] as MonitoringState['instance']['status']) ?? next.instance.status,
        activeRuns: typeof h['active_runs'] === 'number' ? h['active_runs'] : next.instance.activeRuns,
        queuedRuns: typeof h['queued_runs'] === 'number' ? h['queued_runs'] : next.instance.queuedRuns,
        completedToday:
          typeof h['completed_today'] === 'number'
            ? h['completed_today']
            : next.instance.completedToday,
        lastUpdatedMs: Date.now(),
      },
    };
  }

  return next;
}

// ============================================================================
// Hello-ok application
// ============================================================================

/**
 * Apply a hello-ok server frame (instance info, initial snapshot)
 */
export function applyHelloOk(
  state: MonitoringState,
  frame: {
    server: { version?: string; nodeId?: string; uptimeMs?: number };
    features: Record<string, boolean>;
    snapshot?: Record<string, unknown>;
  }
): MonitoringState {
  const { server, snapshot } = frame;

  let next: MonitoringState = {
    ...state,
    instance: {
      ...state.instance,
      version: server.version ?? state.instance.version,
      nodeId: server.nodeId ?? state.instance.nodeId,
      uptimeMs: typeof server.uptimeMs === 'number' ? server.uptimeMs : state.instance.uptimeMs,
      status: 'healthy',
      lastUpdatedMs: Date.now(),
    },
  };

  if (snapshot) {
    next = applySnapshot(next, snapshot);
  }

  return next;
}

// ============================================================================
// Event routing
// ============================================================================

/**
 * Apply a WS event to monitoring state.
 */
export function applyEvent(
  state: MonitoringState,
  eventName: string,
  payload: unknown,
  seq: number
): MonitoringState {
  // If feed is paused we still update data slices, just skip adding to feed.
  // (The spec says to add to feed regardless, but paused means we don't append.)
  const p = (payload ?? {}) as Record<string, unknown>;

  let next = state;

  switch (eventName) {
    case 'agent': {
      const type = p['type'] as string | undefined;
      if (type === 'started') {
        const run = buildRunFromAgentPayload(p, 'active');
        if (run) {
          next = {
            ...next,
            runs: {
              ...next.runs,
              active: { ...next.runs.active, [run.runId]: run },
            },
            instance: {
              ...next.instance,
              activeRuns: Object.keys({ ...next.runs.active, [run.runId]: run }).length,
            },
          };
        }
      } else if (type === 'completed') {
        const runId = (p['run_id'] ?? p['runId']) as string | undefined;
        if (runId) {
          const existing = next.runs.active[runId];
          const completedRun: MonitoringRun = {
            ...(existing ?? buildFallbackRun(runId)),
            status: (p['ok'] === false ? 'error' : 'completed') as MonitoringRun['status'],
            ok: typeof p['ok'] === 'boolean' ? p['ok'] : null,
            completedAtMs: Date.now(),
            durationMs:
              existing?.startedAtMs != null ? Date.now() - existing.startedAtMs : null,
          };
          const active = { ...next.runs.active };
          delete active[runId];
          const recent = [completedRun, ...next.runs.recent].slice(0, MAX_RECENT_RUNS);
          next = {
            ...next,
            runs: { active, recent },
            instance: {
              ...next.instance,
              activeRuns: Object.keys(active).length,
            },
          };
        }
      }
      // tool_use and other subtypes fall through to feed only
      break;
    }

    case 'task.started': {
      const task = buildTaskFromPayload(p, 'active');
      if (task) {
        next = {
          ...next,
          tasks: {
            ...next.tasks,
            active: { ...next.tasks.active, [task.taskId]: task },
          },
        };
      }
      break;
    }

    case 'task.completed':
    case 'task.error':
    case 'task.timeout':
    case 'task.aborted': {
      const taskStatus = eventNameToTaskStatus(eventName);
      const taskId = (p['task_id'] ?? p['taskId']) as string | undefined;
      if (taskId) {
        const existing = next.tasks.active[taskId];
        const resultPreview = (p['result_preview'] ?? p['resultPreview']) as string | undefined;
        const completedTask: MonitoringTask = {
          ...(existing ?? buildFallbackTask(taskId)),
          status: taskStatus,
          runId: (p['run_id'] ?? p['runId'] ?? existing?.runId ?? null) as string | null,
          parentRunId: (p['parent_run_id'] ?? p['parentRunId'] ?? existing?.parentRunId ?? null) as string | null,
          sessionKey: (p['session_key'] ?? p['sessionKey'] ?? existing?.sessionKey ?? null) as string | null,
          agentId: (p['agent_id'] ?? p['agentId'] ?? existing?.agentId ?? null) as string | null,
          description: (p['description'] ?? existing?.description ?? null) as string | null,
          engine: (p['engine'] ?? existing?.engine ?? null) as string | null,
          role: (p['role'] ?? existing?.role ?? null) as string | null,
          error: p['error'] ?? existing?.error,
          result: resultPreview != null ? { preview: resultPreview } : existing?.result,
          durationMs:
            (typeof p['duration_ms'] === 'number' ? p['duration_ms'] :
             typeof p['durationMs'] === 'number' ? p['durationMs'] : existing?.durationMs ?? null),
          completedAtMs: Date.now(),
        };
        const active = { ...next.tasks.active };
        delete active[taskId];
        const recent = [completedTask, ...next.tasks.recent].slice(0, MAX_RECENT_TASKS);
        next = {
          ...next,
          tasks: { active, recent },
        };
      }
      break;
    }

    case 'run.graph.changed': {
      const runId = (p['run_id'] ?? p['runId']) as string | undefined;
      const status = (p['status'] as string | undefined)?.toLowerCase();
      if (runId && status) {
        const existing = next.runs.active[runId] ?? next.runs.recent.find((r) => r.runId === runId) ?? null;
        const normalizedStatus = normalizeRunStatus(status);
        const patch: MonitoringRun = {
          ...(existing ?? buildFallbackRun(runId)),
          status: normalizedStatus,
          completedAtMs:
            normalizedStatus === 'active' ? null : (existing?.completedAtMs ?? Date.now()),
          ok:
            normalizedStatus === 'completed'
              ? true
              : normalizedStatus === 'error' || normalizedStatus === 'aborted'
                ? false
                : existing?.ok ?? null,
          durationMs:
            normalizedStatus === 'active'
              ? existing?.durationMs ?? null
              : existing?.startedAtMs != null
                ? Date.now() - existing.startedAtMs
                : existing?.durationMs ?? null,
        };

        if (normalizedStatus === 'active') {
          next = {
            ...next,
            runs: {
              ...next.runs,
              active: { ...next.runs.active, [runId]: patch },
            },
          };
        } else {
          const active = { ...next.runs.active };
          delete active[runId];
          const recent = [patch, ...next.runs.recent.filter((r) => r.runId !== runId)].slice(0, MAX_RECENT_RUNS);
          next = {
            ...next,
            runs: { active, recent },
          };
        }
      }
      break;
    }

    case 'presence': {
      const count = p['count'] ?? p['connected_clients'];
      if (typeof count === 'number') {
        next = {
          ...next,
          instance: { ...next.instance, connectedClients: count },
        };
      }
      break;
    }

    case 'heartbeat': {
      const uptimeMs = p['uptime_ms'] ?? p['uptimeMs'];
      next = {
        ...next,
        instance: {
          ...next.instance,
          uptimeMs: typeof uptimeMs === 'number' ? uptimeMs : next.instance.uptimeMs,
          status: 'healthy',
          lastUpdatedMs: Date.now(),
        },
      };
      break;
    }

    case 'cron': {
      const jobId = (p['job_id'] ?? p['jobId']) as string | undefined;
      if (jobId) {
        const incoming = buildCronRunFromPayload(p, jobId);
        const existing = next.cron.runsByJob[jobId] ?? [];
        const merged = upsertCronRun(existing, incoming).slice(0, MAX_RECENT_RUNS);
        next = {
          ...next,
          cron: {
            ...next.cron,
            runsByJob: {
              ...next.cron.runsByJob,
              [jobId]: merged,
            },
          },
        };
      }
      break;
    }

    case 'cron.job': {
      const type = (p['type'] ?? 'updated') as string;
      const jobId = (p['job_id'] ?? p['jobId']) as string | undefined;
      if (jobId) {
        if (type === 'deleted') {
          next = {
            ...next,
            cron: {
              ...next.cron,
              jobs: next.cron.jobs.filter((job) => job.id !== jobId),
              runsByJob: Object.fromEntries(
                Object.entries(next.cron.runsByJob).filter(([id]) => id !== jobId)
              ),
            },
          };
        } else {
          const patch: MonitoringCronJob = {
            id: jobId,
            name: ((p['name'] ?? 'cron job') as string),
            schedule: ((p['schedule'] ?? '* * * * *') as string),
            enabled: Boolean(p['enabled']),
            agentId: (p['agent_id'] ?? p['agentId'] ?? null) as string | null,
            sessionKey: (p['session_key'] ?? p['sessionKey'] ?? null) as string | null,
            prompt: (p['prompt'] ?? null) as string | null,
            timezone: ((p['timezone'] ?? 'UTC') as string),
            jitterSec: (typeof p['jitter_sec'] === 'number' ? p['jitter_sec'] : 0) as number,
            timeoutMs: (typeof p['timeout_ms'] === 'number' ? p['timeout_ms'] : null) as number | null,
            createdAtMs: (typeof p['created_at_ms'] === 'number' ? p['created_at_ms'] : null) as number | null,
            updatedAtMs: (typeof p['updated_at_ms'] === 'number' ? p['updated_at_ms'] : null) as number | null,
            lastRunAtMs: (typeof p['last_run_at_ms'] === 'number' ? p['last_run_at_ms'] : null) as number | null,
            nextRunAtMs: (typeof p['next_run_at_ms'] === 'number' ? p['next_run_at_ms'] : null) as number | null,
          };

          next = applyCronList(next, upsertCronJob(next.cron.jobs, patch));
        }
      }
      break;
    }

    case 'health': {
      const healthStatus = p['status'] as MonitoringState['instance']['status'] | undefined;
      next = {
        ...next,
        instance: {
          ...next.instance,
          status: healthStatus ?? next.instance.status,
          lastUpdatedMs: Date.now(),
        },
      };
      break;
    }

    // chat and run.graph.changed fall through to feed-only handling
    default:
      break;
  }

  // Always add to event feed (unless paused)
  if (!state.ui.eventFeedPaused) {
    next = addFeedEvent(next, {
      eventName,
      payload,
      seq,
      runId: (p['run_id'] ?? p['runId'] ?? null) as string | null | undefined,
      sessionKey: (p['session_key'] ?? p['sessionKey'] ?? null) as string | null | undefined,
      agentId: (p['agent_id'] ?? p['agentId'] ?? null) as string | null | undefined,
      level: determineFeedLevel(eventName, p),
    });
  }

  return next;
}

// ============================================================================
// List application helpers
// ============================================================================

/**
 * Apply agents.list response — populates the agents map keyed by agentId
 */
export function applyAgentsList(
  state: MonitoringState,
  agents: unknown[]
): MonitoringState {
  const agentsMap: MonitoringState['agents'] = {};
  for (const raw of agents) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) continue;
    const a = raw as Record<string, unknown>;
    // Support both simple format (id) and rich AgentDirectoryList format (agentId)
    const agentId = (a['agentId'] ?? a['id']) as string | undefined;
    if (!agentId) continue;
    const activeSessionCount =
      typeof a['activeSessionCount'] === 'number'
        ? a['activeSessionCount']
        : Object.values(state.sessions.active).filter((s) => s.agentId === agentId).length;
    const rawStatus = a['status'] as string | undefined;
    const status: 'active' | 'idle' | 'unknown' =
      rawStatus === 'active' ? 'active' : rawStatus === 'idle' ? 'idle' : 'unknown';
    agentsMap[agentId] = {
      agentId,
      name: (a['name'] ?? agentId) as string,
      status: activeSessionCount > 0 ? 'active' : status,
      activeSessionCount,
      sessionCount: typeof a['sessionCount'] === 'number' ? a['sessionCount'] : 0,
      routeCount: typeof a['routeCount'] === 'number' ? a['routeCount'] : 0,
      latestSessionKey: (a['latestSessionKey'] ?? null) as string | null,
      latestUpdatedAtMs: typeof a['latestUpdatedAtMs'] === 'number' ? a['latestUpdatedAtMs'] : null,
      description: (a['description'] ?? null) as string | null,
      model: (a['model'] ?? null) as string | null,
    };
  }
  return { ...state, agents: agentsMap };
}

/**
 * Apply runs.active.list response
 */
export function applyRunsActiveList(
  state: MonitoringState,
  payload: { runs: MonitoringRun[]; total: number }
): MonitoringState {
  const active: Record<string, MonitoringRun> = {};
  for (const run of payload.runs) {
    if (run.runId) {
      active[run.runId] = run;
    }
  }
  return {
    ...state,
    runs: { ...state.runs, active },
    instance: {
      ...state.instance,
      activeRuns: Object.keys(active).length,
    },
  };
}

/**
 * Apply runs.recent.list response
 */
export function applyRunsRecentList(
  state: MonitoringState,
  payload: { runs: MonitoringRun[]; total: number }
): MonitoringState {
  const recent = [...payload.runs].slice(0, MAX_RECENT_RUNS);
  return {
    ...state,
    runs: { ...state.runs, recent },
  };
}

/**
 * Apply sessions.active.list response
 */
export function applySessionsActiveList(
  state: MonitoringState,
  sessions: unknown[]
): MonitoringState {
  const active: Record<string, MonitoringSession> = {};
  for (const raw of sessions) {
    const s = normalizeSession(raw);
    if (s) {
      active[s.sessionKey] = s;
    }
  }
  return {
    ...state,
    sessions: { ...state.sessions, active },
  };
}

/**
 * Apply sessions list (historical) response
 */
export function applySessionsList(
  state: MonitoringState,
  sessions: unknown[]
): MonitoringState {
  const historical = sessions
    .map((raw) => normalizeSession(raw))
    .filter((s): s is MonitoringSession => s !== null)
    .sort((a, b) => (b.updatedAtMs ?? 0) - (a.updatedAtMs ?? 0));
  return {
    ...state,
    sessions: { ...state.sessions, historical },
  };
}

/**
 * Apply tasks.active.list response
 */
export function applyTasksActiveList(
  state: MonitoringState,
  tasks: MonitoringTask[]
): MonitoringState {
  const active: Record<string, MonitoringTask> = {};
  for (const task of tasks) {
    if (task.taskId) {
      active[task.taskId] = task;
    }
  }
  return {
    ...state,
    tasks: { ...state.tasks, active },
  };
}

/**
 * Apply tasks.recent.list response
 */
export function applyTasksRecentList(
  state: MonitoringState,
  tasks: MonitoringTask[]
): MonitoringState {
  const recent = [...tasks].slice(0, MAX_RECENT_TASKS);
  return {
    ...state,
    tasks: { ...state.tasks, recent },
  };
}

/**
 * Apply cron.status response
 */
export function applyCronStatus(
  state: MonitoringState,
  status: MonitoringCronStatus
): MonitoringState {
  return {
    ...state,
    cron: {
      ...state.cron,
      status,
    },
  };
}

/**
 * Apply cron.list response
 */
export function applyCronList(
  state: MonitoringState,
  jobs: MonitoringCronJob[]
): MonitoringState {
  const normalized = jobs.map((job) => ({
    ...job,
    timezone: job.timezone ?? 'UTC',
    jitterSec: job.jitterSec ?? 0,
  }));

  return {
    ...state,
    cron: {
      ...state.cron,
      jobs: normalized,
    },
  };
}

/**
 * Apply cron.runs response for a specific job
 */
export function applyCronRuns(
  state: MonitoringState,
  jobId: string,
  runs: MonitoringCronRun[]
): MonitoringState {
  return {
    ...state,
    cron: {
      ...state.cron,
      runsByJob: {
        ...state.cron.runsByJob,
        [jobId]: runs,
      },
    },
  };
}

// ============================================================================
// Feed helpers
// ============================================================================

/**
 * Add an event to the feed (with capping)
 */
export function addFeedEvent(
  state: MonitoringState,
  event: Omit<FeedEvent, 'id' | 'receivedAtMs'>
): MonitoringState {
  const newEvent: FeedEvent = {
    ...event,
    id: nextFeedId(event.seq),
    receivedAtMs: Date.now(),
  };
  const feed = pruneFeedEvents([...state.eventFeed, newEvent]);
  return { ...state, eventFeed: feed };
}

/**
 * Prune old feed events (keep last MAX_FEED_EVENTS)
 */
export function pruneFeedEvents(feed: FeedEvent[]): FeedEvent[] {
  if (feed.length <= MAX_FEED_EVENTS) {
    return feed;
  }
  return feed.slice(feed.length - MAX_FEED_EVENTS);
}

// ============================================================================
// Private helpers
// ============================================================================

function determineFeedLevel(
  eventName: string,
  payload: Record<string, unknown>
): FeedEvent['level'] {
  if (eventName === 'health') {
    const status = payload['status'] as string | undefined;
    if (status && status !== 'healthy') {
      return 'warn';
    }
  }
  if (eventName === 'task.error' || eventName === 'task.timeout') {
    return 'warn';
  }
  if (eventName === 'cron' && payload['type'] === 'completed' && payload['status'] !== 'completed') {
    return 'warn';
  }
  return 'info';
}

function eventNameToTaskStatus(eventName: string): MonitoringTask['status'] {
  switch (eventName) {
    case 'task.completed':
      return 'completed';
    case 'task.error':
      return 'error';
    case 'task.timeout':
      return 'timeout';
    case 'task.aborted':
      return 'aborted';
    default:
      return 'completed';
  }
}

function buildRunFromAgentPayload(
  p: Record<string, unknown>,
  status: MonitoringRun['status']
): MonitoringRun | null {
  const runId = (p['run_id'] ?? p['runId']) as string | undefined;
  if (!runId) return null;
  return {
    runId,
    sessionKey: (p['session_key'] ?? p['sessionKey'] ?? null) as string | null,
    agentId: (p['agent_id'] ?? p['agentId'] ?? null) as string | null,
    engine: (p['engine'] ?? null) as string | null,
    startedAtMs: Date.now(),
    completedAtMs: null,
    durationMs: null,
    status,
    ok: null,
    parentRunId: (p['parent_run_id'] ?? p['parentRunId'] ?? null) as string | null,
  };
}

function buildFallbackRun(runId: string): MonitoringRun {
  return {
    runId,
    sessionKey: null,
    agentId: null,
    engine: null,
    startedAtMs: null,
    completedAtMs: null,
    durationMs: null,
    status: 'completed',
    ok: null,
    parentRunId: null,
  };
}

function buildTaskFromPayload(
  p: Record<string, unknown>,
  status: MonitoringTask['status']
): MonitoringTask | null {
  const taskId = (p['task_id'] ?? p['taskId']) as string | undefined;
  if (!taskId) return null;
  return {
    taskId,
    parentRunId: (p['parent_run_id'] ?? p['parentRunId'] ?? null) as string | null,
    runId: (p['run_id'] ?? p['runId'] ?? null) as string | null,
    sessionKey: (p['session_key'] ?? p['sessionKey'] ?? null) as string | null,
    agentId: (p['agent_id'] ?? p['agentId'] ?? null) as string | null,
    description: (p['description'] ?? null) as string | null,
    engine: (p['engine'] ?? null) as string | null,
    role: (p['role'] ?? null) as string | null,
    startedAtMs: Date.now(),
    completedAtMs: null,
    durationMs: null,
    status,
    error: p['error'],
    result:
      p['result_preview'] != null || p['resultPreview'] != null
        ? { preview: p['result_preview'] ?? p['resultPreview'] }
        : undefined,
  };
}

function buildFallbackTask(taskId: string): MonitoringTask {
  return {
    taskId,
    parentRunId: null,
    runId: null,
    sessionKey: null,
    agentId: null,
    startedAtMs: null,
    completedAtMs: null,
    durationMs: null,
    status: 'completed',
  };
}

function normalizeRunStatus(status: string): MonitoringRun['status'] {
  if (status === 'queued' || status === 'running' || status === 'active') return 'active';
  if (status === 'completed') return 'completed';
  if (status === 'aborted' || status === 'cancelled' || status === 'killed' || status === 'lost') return 'aborted';
  return 'error';
}

function buildCronRunFromPayload(
  p: Record<string, unknown>,
  jobId: string
): MonitoringCronRun {
  const cronRunId = ((p['cron_run_id'] ?? p['cronRunId'] ?? p['run_id'] ?? p['runId']) as string | undefined) ?? `cron-${Date.now()}`;
  return {
    id: cronRunId,
    jobId,
    routerRunId: (p['run_id'] ?? p['runId'] ?? null) as string | null,
    status: (p['status'] ?? p['type'] ?? 'running') as string,
    triggeredBy: (p['triggered_by'] ?? p['triggeredBy'] ?? 'schedule') as string,
    startedAtMs: (p['started_at_ms'] ?? p['startedAtMs'] ?? null) as number | null,
    completedAtMs: (p['completed_at_ms'] ?? p['completedAtMs'] ?? null) as number | null,
    durationMs: (p['duration_ms'] ?? p['durationMs'] ?? null) as number | null,
    output: (p['output'] ?? null) as string | null,
    outputPreview: (p['output_preview'] ?? p['outputPreview'] ?? null) as string | null,
    error: (p['error'] ?? null) as string | null,
    suppressed: Boolean(p['suppressed']),
    sessionKey: (p['session_key'] ?? p['sessionKey'] ?? null) as string | null,
    agentId: (p['agent_id'] ?? p['agentId'] ?? null) as string | null,
  };
}

function upsertCronRun(existing: MonitoringCronRun[], incoming: MonitoringCronRun): MonitoringCronRun[] {
  const next = [...existing];
  const idx = next.findIndex((run) => run.id === incoming.id);
  if (idx >= 0) {
    next[idx] = { ...next[idx], ...incoming };
  } else {
    next.unshift(incoming);
  }
  return next.sort((a, b) => (b.startedAtMs ?? 0) - (a.startedAtMs ?? 0));
}

function upsertCronJob(existing: MonitoringCronJob[], incoming: MonitoringCronJob): MonitoringCronJob[] {
  const next = [...existing];
  const idx = next.findIndex((job) => job.id === incoming.id);
  if (idx >= 0) {
    next[idx] = { ...next[idx], ...incoming };
  } else {
    next.unshift(incoming);
  }
  return next.sort((a, b) => (b.updatedAtMs ?? 0) - (a.updatedAtMs ?? 0));
}

function normalizeSession(raw: unknown): MonitoringSession | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const s = raw as Record<string, unknown>;
  const sessionKey = (s['session_key'] ?? s['sessionKey']) as string | undefined;
  if (!sessionKey) return null;
  return {
    sessionKey,
    agentId: (s['agent_id'] ?? s['agentId'] ?? null) as string | null,
    kind: (s['kind'] ?? null) as string | null,
    channelId: (s['channel_id'] ?? s['channelId'] ?? null) as string | null,
    accountId: (s['account_id'] ?? s['accountId'] ?? null) as string | null,
    peerId: (s['peer_id'] ?? s['peerId'] ?? null) as string | null,
    peerLabel: (s['peer_label'] ?? s['peerLabel'] ?? null) as string | null,
    active: Boolean(s['active']),
    runId: (s['run_id'] ?? s['runId'] ?? null) as string | null,
    runCount: typeof s['run_count'] === 'number' ? s['run_count'] :
              typeof s['runCount'] === 'number' ? s['runCount'] : 0,
    createdAtMs: typeof s['created_at_ms'] === 'number' ? s['created_at_ms'] :
                 typeof s['createdAtMs'] === 'number' ? s['createdAtMs'] : null,
    updatedAtMs: typeof s['updated_at_ms'] === 'number' ? s['updated_at_ms'] :
                 typeof s['updatedAtMs'] === 'number' ? s['updatedAtMs'] : null,
    route: (s['route'] ?? {}) as Record<string, string | null>,
    origin: (s['origin'] ?? null) as string | null,
  };
}
