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

// Agent in directory
export interface MonitoringAgent {
  agentId: string;
  name: string | null;
  status: 'active' | 'idle' | 'unknown';
  activeSessionCount: number;
  lastActivityMs: number | null;
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
  startedAtMs: number | null;
  completedAtMs: number | null;
  durationMs: number | null;
  status: 'active' | 'completed' | 'error' | 'timeout' | 'aborted';
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
  timeRangeMs: number | null;  // show events from last N ms
  eventTypes: string[];         // empty = all
}

export interface MonitoringUIState {
  selectedSessionKey: string | null;
  selectedRunId: string | null;
  selectedTaskId: string | null;
  filters: MonitoringUIFilters;
  eventFeedPaused: boolean;
  sidebarTab: 'agents' | 'sessions';
}
