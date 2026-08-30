import type { MonitoringState } from './monitoringStore';
import type {
  FeedEvent,
  MonitoringRun,
  MonitoringTask,
  MonitoringCronJob,
} from '../../../shared/src/monitoringTypes';
import {
  applyAgentsList,
  applyChannelsStatus,
  applyCronList,
  applyCronStatus,
  applySessionsActiveList,
  applySessionsList,
  applyTasksActiveList,
  applyTasksRecentList,
  applyTransportsStatus,
} from './monitoringListReducers';
import {
  MAX_RECENT_RUNS,
  MAX_RECENT_TASKS,
  buildCronRunFromPayload,
  buildFallbackRun,
  buildFallbackTask,
  buildRunFromAgentPayload,
  buildTaskFromPayload,
  determineFeedLevel,
  eventNameToTaskStatus,
  normalizeRunStatus,
  upsertCronJob,
  upsertCronRun,
} from './monitoringReducerHelpers';

export {
  applyAgentsList,
  applyChannelsStatus,
  applyCronList,
  applyCronRuns,
  applyCronStatus,
  applyRunsActiveList,
  applyRunsRecentList,
  applySessionsActiveList,
  applySessionsList,
  applySystemStatus,
  applyTasksActiveList,
  applyTasksRecentList,
  applyTransportsStatus,
} from './monitoringListReducers';

export const MAX_FEED_EVENTS = 5000;

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

  const snapshotChannels = snapshot['channels'];
  if (Array.isArray(snapshotChannels)) {
    next = applyChannelsStatus(next, { channels: snapshotChannels });
  }

  const snapshotTransports = snapshot['transports'];
  if (Array.isArray(snapshotTransports)) {
    next = applyTransportsStatus(next, { transports: snapshotTransports });
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
