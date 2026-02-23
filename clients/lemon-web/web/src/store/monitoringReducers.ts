import type { MonitoringState } from './monitoringStore';
import type {
  FeedEvent,
  MonitoringRun,
  MonitoringSession,
  MonitoringTask,
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

  // Sessions
  const snapshotSessions = snapshot['sessions'];
  if (Array.isArray(snapshotSessions)) {
    next = applySessionsActiveList(next, snapshotSessions);
  }

  // Runs
  const snapshotRuns = snapshot['runs'];
  if (snapshotRuns && typeof snapshotRuns === 'object' && !Array.isArray(snapshotRuns)) {
    const runsObj = snapshotRuns as Record<string, unknown>;
    if (Array.isArray(runsObj['active'])) {
      next = applyRunsActiveList(next, {
        runs: runsObj['active'] as MonitoringRun[],
        total: (runsObj['active'] as unknown[]).length,
      });
    }
    if (Array.isArray(runsObj['recent'])) {
      next = applyRunsRecentList(next, {
        runs: runsObj['recent'] as MonitoringRun[],
        total: (runsObj['recent'] as unknown[]).length,
      });
    }
  }

  // Tasks
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

  // Instance health from snapshot
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
        const completedTask: MonitoringTask = {
          ...(existing ?? buildFallbackTask(taskId)),
          status: taskStatus,
          completedAtMs: Date.now(),
          durationMs:
            existing?.startedAtMs != null ? Date.now() - existing.startedAtMs : null,
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
    startedAtMs: Date.now(),
    completedAtMs: null,
    durationMs: null,
    status,
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
    runCount: typeof s['run_count'] === 'number' ? s['run_count'] : 0,
    createdAtMs: typeof s['created_at_ms'] === 'number' ? s['created_at_ms'] : null,
    updatedAtMs: typeof s['updated_at_ms'] === 'number' ? s['updated_at_ms'] : null,
    route: (s['route'] ?? {}) as Record<string, string | null>,
  };
}
