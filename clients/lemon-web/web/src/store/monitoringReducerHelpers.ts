import type {
  FeedEvent,
  MonitoringCronJob,
  MonitoringCronRun,
  MonitoringRun,
  MonitoringSession,
  MonitoringTask,
} from '../../../shared/src/monitoringTypes';

export const MAX_RECENT_RUNS = 200;
export const MAX_RECENT_TASKS = 200;

export function determineFeedLevel(
  eventName: string,
  payload: Record<string, unknown>
): FeedEvent['level'] {
  if (eventName === 'health') {
    const status = payload['status'] as string | undefined;
    if (status && status !== 'healthy') return 'warn';
  }
  if (eventName === 'task.error' || eventName === 'task.timeout') return 'warn';
  if (eventName === 'cron' && payload['type'] === 'completed' && payload['status'] !== 'completed') {
    return 'warn';
  }
  return 'info';
}

export function eventNameToTaskStatus(eventName: string): MonitoringTask['status'] {
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

export function buildRunFromAgentPayload(
  payload: Record<string, unknown>,
  status: MonitoringRun['status']
): MonitoringRun | null {
  const runId = (payload['run_id'] ?? payload['runId']) as string | undefined;
  if (!runId) return null;
  return {
    runId,
    sessionKey: (payload['session_key'] ?? payload['sessionKey'] ?? null) as string | null,
    agentId: (payload['agent_id'] ?? payload['agentId'] ?? null) as string | null,
    engine: (payload['engine'] ?? null) as string | null,
    startedAtMs: Date.now(),
    completedAtMs: null,
    durationMs: null,
    status,
    ok: null,
    parentRunId: (payload['parent_run_id'] ?? payload['parentRunId'] ?? null) as string | null,
  };
}

export function buildFallbackRun(runId: string): MonitoringRun {
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

export function buildTaskFromPayload(
  payload: Record<string, unknown>,
  status: MonitoringTask['status']
): MonitoringTask | null {
  const taskId = (payload['task_id'] ?? payload['taskId']) as string | undefined;
  if (!taskId) return null;
  return {
    taskId,
    parentRunId: (payload['parent_run_id'] ?? payload['parentRunId'] ?? null) as string | null,
    runId: (payload['run_id'] ?? payload['runId'] ?? null) as string | null,
    sessionKey: (payload['session_key'] ?? payload['sessionKey'] ?? null) as string | null,
    agentId: (payload['agent_id'] ?? payload['agentId'] ?? null) as string | null,
    description: (payload['description'] ?? null) as string | null,
    engine: (payload['engine'] ?? null) as string | null,
    role: (payload['role'] ?? null) as string | null,
    startedAtMs: Date.now(),
    completedAtMs: null,
    durationMs: null,
    status,
    error: payload['error'],
    result:
      payload['result_preview'] != null || payload['resultPreview'] != null
        ? { preview: payload['result_preview'] ?? payload['resultPreview'] }
        : undefined,
  };
}

export function buildFallbackTask(taskId: string): MonitoringTask {
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

export function normalizeRunStatus(status: string): MonitoringRun['status'] {
  if (status === 'queued' || status === 'running' || status === 'active') return 'active';
  if (status === 'completed') return 'completed';
  if (status === 'aborted' || status === 'cancelled' || status === 'killed' || status === 'lost') {
    return 'aborted';
  }
  return 'error';
}

export function buildCronRunFromPayload(
  payload: Record<string, unknown>,
  jobId: string
): MonitoringCronRun {
  const cronRunId =
    ((payload['cron_run_id'] ?? payload['cronRunId'] ?? payload['run_id'] ?? payload['runId']) as
      | string
      | undefined) ?? `cron-${Date.now()}`;
  return {
    id: cronRunId,
    jobId,
    routerRunId: (payload['run_id'] ?? payload['runId'] ?? null) as string | null,
    status: (payload['status'] ?? payload['type'] ?? 'running') as string,
    triggeredBy: (payload['triggered_by'] ?? payload['triggeredBy'] ?? 'schedule') as string,
    startedAtMs: (payload['started_at_ms'] ?? payload['startedAtMs'] ?? null) as number | null,
    completedAtMs: (payload['completed_at_ms'] ?? payload['completedAtMs'] ?? null) as number | null,
    durationMs: (payload['duration_ms'] ?? payload['durationMs'] ?? null) as number | null,
    output: (payload['output'] ?? null) as string | null,
    outputPreview: (payload['output_preview'] ?? payload['outputPreview'] ?? null) as string | null,
    error: (payload['error'] ?? null) as string | null,
    suppressed: Boolean(payload['suppressed']),
    sessionKey: (payload['session_key'] ?? payload['sessionKey'] ?? null) as string | null,
    agentId: (payload['agent_id'] ?? payload['agentId'] ?? null) as string | null,
  };
}

export function upsertCronRun(
  existing: MonitoringCronRun[],
  incoming: MonitoringCronRun
): MonitoringCronRun[] {
  const next = [...existing];
  const index = next.findIndex((run) => run.id === incoming.id);
  if (index >= 0) next[index] = { ...next[index], ...incoming };
  else next.unshift(incoming);
  return next.sort((a, b) => (b.startedAtMs ?? 0) - (a.startedAtMs ?? 0));
}

export function upsertCronJob(
  existing: MonitoringCronJob[],
  incoming: MonitoringCronJob
): MonitoringCronJob[] {
  const next = [...existing];
  const index = next.findIndex((job) => job.id === incoming.id);
  if (index >= 0) next[index] = { ...next[index], ...incoming };
  else next.unshift(incoming);
  return next.sort((a, b) => (b.updatedAtMs ?? 0) - (a.updatedAtMs ?? 0));
}

export function normalizeSession(raw: unknown): MonitoringSession | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const session = raw as Record<string, unknown>;
  const sessionKey = (session['session_key'] ?? session['sessionKey']) as string | undefined;
  if (!sessionKey) return null;
  return {
    sessionKey,
    agentId: (session['agent_id'] ?? session['agentId'] ?? null) as string | null,
    kind: (session['kind'] ?? null) as string | null,
    channelId: (session['channel_id'] ?? session['channelId'] ?? null) as string | null,
    accountId: (session['account_id'] ?? session['accountId'] ?? null) as string | null,
    peerKind: (session['peer_kind'] ?? session['peerKind'] ?? null) as string | null,
    peerId: (session['peer_id'] ?? session['peerId'] ?? null) as string | null,
    peerLabel: (session['peer_label'] ?? session['peerLabel'] ?? null) as string | null,
    peerUsername: (session['peer_username'] ?? session['peerUsername'] ?? null) as string | null,
    threadId: (session['thread_id'] ?? session['threadId'] ?? null) as string | null,
    target: (session['target'] ?? null) as string | null,
    topicName: (session['topic_name'] ?? session['topicName'] ?? null) as string | null,
    chatType: (session['chat_type'] ?? session['chatType'] ?? null) as string | null,
    subId: (session['sub_id'] ?? session['subId'] ?? null) as string | null,
    active: Boolean(session['active']),
    runId: (session['run_id'] ?? session['runId'] ?? null) as string | null,
    runCount:
      typeof session['run_count'] === 'number'
        ? session['run_count']
        : typeof session['runCount'] === 'number'
          ? session['runCount']
          : 0,
    createdAtMs:
      typeof session['created_at_ms'] === 'number'
        ? session['created_at_ms']
        : typeof session['createdAtMs'] === 'number'
          ? session['createdAtMs']
          : null,
    updatedAtMs:
      typeof session['updated_at_ms'] === 'number'
        ? session['updated_at_ms']
        : typeof session['updatedAtMs'] === 'number'
          ? session['updatedAtMs']
          : null,
    route: (session['route'] ?? {}) as Record<string, string | null>,
    origin: (session['origin'] ?? null) as string | null,
  };
}

export function mergeSession(
  existing: MonitoringSession | null,
  incoming: MonitoringSession
): MonitoringSession {
  if (!existing) return incoming;
  const incomingRouteHasData = incoming.route && Object.keys(incoming.route).length > 0;
  const existingRouteHasData = existing.route && Object.keys(existing.route).length > 0;

  return {
    ...existing,
    ...incoming,
    agentId: incoming.agentId ?? existing.agentId,
    kind: incoming.kind ?? existing.kind,
    channelId: incoming.channelId ?? existing.channelId,
    accountId: incoming.accountId ?? existing.accountId,
    peerKind: incoming.peerKind ?? existing.peerKind,
    peerId: incoming.peerId ?? existing.peerId,
    peerLabel: incoming.peerLabel ?? existing.peerLabel,
    peerUsername: incoming.peerUsername ?? existing.peerUsername,
    threadId: incoming.threadId ?? existing.threadId,
    target: incoming.target ?? existing.target,
    topicName: incoming.topicName ?? existing.topicName,
    chatType: incoming.chatType ?? existing.chatType,
    subId: incoming.subId ?? existing.subId,
    runId: incoming.runId ?? existing.runId,
    runCount: Math.max(incoming.runCount ?? 0, existing.runCount ?? 0),
    createdAtMs: incoming.createdAtMs ?? existing.createdAtMs,
    updatedAtMs: incoming.updatedAtMs ?? existing.updatedAtMs,
    route: incomingRouteHasData
      ? incoming.route
      : existingRouteHasData
        ? existing.route
        : incoming.route,
    origin:
      incoming.origin && incoming.origin !== 'unknown'
        ? incoming.origin
        : existing.origin ?? incoming.origin,
  };
}
