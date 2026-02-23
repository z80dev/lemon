// Instance health & status
export interface InstanceHealth {
  status: 'healthy' | 'degraded' | 'unhealthy' | 'unknown';
  uptimeMs: number | null;
  connectedClients: number;
  activeRuns: number;
  queuedRuns: number;
  completedToday: number;
  nodeId: string | null;
  version: string | null;
  lastUpdatedMs: number | null;
}

// Agent in directory (rich format from AgentDirectoryList)
export interface MonitoringAgent {
  agentId: string;
  name: string | null;
  status: 'active' | 'idle' | 'unknown';
  activeSessionCount: number;
  sessionCount: number;
  routeCount: number;
  latestSessionKey: string | null;
  latestUpdatedAtMs: number | null;
  description: string | null;
  model: string | null;
}

// Session summary for monitoring
export interface MonitoringSession {
  sessionKey: string;
  agentId: string | null;
  kind: string | null;
  channelId: string | null;
  accountId: string | null;
  peerId: string | null;
  peerLabel: string | null;
  active: boolean;
  runId: string | null;
  runCount: number;
  createdAtMs: number | null;
  updatedAtMs: number | null;
  route: Record<string, string | null>;
  origin: string | null;
}

// A single tool call within a run
export interface RunToolCall {
  name: string;
  kind: string | null;
  ok: boolean | null;
  phase: string | null;
  detail: string | null;
  raw?: unknown;
}

// Token usage for a run
export interface RunTokenUsage {
  input: number;
  output: number;
  total: number;
  costUsd: number;
}

// A run within a session (from session.detail)
export interface SessionRunSummary {
  runId?: string | null;
  startedAtMs: number | null;
  engine: string | null;
  prompt: string | null;       // user message, truncated
  answer: string | null;       // AI response, truncated
  promptFull?: string | null;
  answerFull?: string | null;
  ok: boolean | null;
  error: string | null;
  durationMs: number | null;
  toolCallCount: number;
  toolCalls: RunToolCall[];
  tokens: RunTokenUsage | null;
  eventCount?: number;
  eventDigest?: unknown[];
  events?: unknown[];
  summaryRaw?: unknown;
  completedRaw?: unknown;
  runRecord?: unknown;
}

// Full session detail (from session.detail method)
export interface SessionDetail {
  sessionKey: string;
  session: Partial<MonitoringSession>;
  runs: SessionRunSummary[];
  runCount: number;
  loadedAtMs: number;
}

// Run summary for monitoring
export interface MonitoringRun {
  runId: string;
  sessionKey: string | null;
  agentId: string | null;
  engine: string | null;
  startedAtMs: number | null;
  completedAtMs: number | null;
  durationMs: number | null;
  status: 'active' | 'completed' | 'error' | 'aborted';
  ok: boolean | null;
  parentRunId: string | null;
}

// Task/subagent summary
export interface MonitoringTask {
  taskId: string;
  parentRunId: string | null;
  runId: string | null;
  sessionKey: string | null;
  agentId: string | null;
  description?: string | null;
  engine?: string | null;
  role?: string | null;
  startedAtMs: number | null;
  completedAtMs: number | null;
  createdAtMs?: number | null;
  updatedAtMs?: number | null;
  durationMs: number | null;
  status: 'queued' | 'active' | 'completed' | 'error' | 'timeout' | 'aborted';
  error?: unknown;
  result?: unknown;
  eventCount?: number;
  events?: unknown[];
  record?: unknown;
}

export interface MonitoringCronJob {
  id: string;
  name: string;
  schedule: string;
  enabled: boolean;
  agentId: string | null;
  sessionKey: string | null;
  prompt: string | null;
  timezone: string;
  jitterSec: number;
  timeoutMs: number | null;
  createdAtMs: number | null;
  updatedAtMs: number | null;
  lastRunAtMs: number | null;
  nextRunAtMs: number | null;
  lastRunStatus?: string | null;
  activeRunCount?: number;
  meta?: unknown;
}

export interface MonitoringCronRun {
  id: string;
  jobId: string;
  routerRunId: string | null;
  status: string;
  triggeredBy: string;
  startedAtMs: number | null;
  completedAtMs: number | null;
  durationMs: number | null;
  output: string | null;
  outputPreview: string | null;
  error: string | null;
  suppressed: boolean;
  sessionKey?: string | null;
  agentId?: string | null;
  meta?: unknown;
  runRecord?: unknown;
  introspection?: unknown[];
}

export interface MonitoringCronStatus {
  enabled: boolean;
  jobCount: number;
  activeJobs: number;
  nextRunAtMs: number | null;
  activeRunCount?: number;
  recentRunCount?: number;
  lastRunAtMs?: number | null;
}

// Event feed entry (normalized from any WS event)
export interface FeedEvent {
  id: string;           // unique stable id for React key
  eventName: string;
  payload: unknown;
  seq: number;
  receivedAtMs: number;
  runId?: string | null;
  sessionKey?: string | null;
  agentId?: string | null;
  level: 'info' | 'warn' | 'error' | 'debug';
}

// Monitoring UI state
export interface MonitoringUIFilters {
  agentId: string | null;
  sessionKey: string | null;
  runId: string | null;
  status: string | null;
  timeRangeMs: number | null;
  eventTypes: string[];
}

export interface MonitoringUIState {
  selectedSessionKey: string | null;
  selectedRunId: string | null;
  selectedTaskId: string | null;
  filters: MonitoringUIFilters;
  eventFeedPaused: boolean;
  sidebarTab: 'agents' | 'sessions';
}
