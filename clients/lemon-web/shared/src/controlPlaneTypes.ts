/**
 * Shared types for the Lemon control-plane WebSocket protocol.
 *
 * The control-plane endpoint is /ws and uses a request/response + server-push
 * event model distinct from the bridge-based protocol in types.ts.
 */

// ============================================================================
// Control-Plane Protocol Frames
// ============================================================================

/** Server sends this immediately after a token-authenticated connection. */
export interface CPHelloOkFrame {
  type: 'hello-ok';
  protocol: number;
  server: {
    version?: string;
    nodeId?: string;
    uptimeMs?: number;
  };
  features: Record<string, boolean>;
  snapshot?: Record<string, unknown>;
  policy?: Record<string, unknown>;
  auth?: Record<string, unknown>;
}

/** Client request frame. */
export interface CPReqFrame {
  type: 'req';
  id: string;
  method: string;
  params?: Record<string, unknown>;
}

/** Server response frame. */
export interface CPResFrame {
  type: 'res';
  id: string;
  ok: boolean;
  payload?: unknown;
  error?: {
    code: string;
    message: string;
    details?: unknown;
  };
}

/** Server-push event frame. */
export interface CPEventFrame {
  type: 'event';
  event: string;
  payload: unknown;
  seq: number;
  stateVersion: Record<string, number>;
}

/** Pong from server in response to a client ping. */
export interface CPPongFrame {
  type: 'pong';
}

/** Union of all frames the server may send. */
export type CPServerFrame = CPHelloOkFrame | CPResFrame | CPEventFrame | CPPongFrame;

// ============================================================================
// Method Response Payload Types
// ============================================================================

export interface RunSummary {
  runId: string;
  sessionKey: string | null;
  agentId: string | null;
  engine: string | null;
  startedAtMs: number | null;
  status: 'active' | 'completed' | 'error' | 'aborted';
  completedAtMs?: number | null;
  durationMs?: number | null;
  ok?: boolean | null;
  parentRunId?: string | null;
}

export interface TaskSummary {
  taskId: string;
  parentRunId: string | null;
  runId: string | null;
  sessionKey: string | null;
  agentId: string | null;
  startedAtMs: number | null;
  status: 'active' | 'completed' | 'error' | 'timeout' | 'aborted';
  completedAtMs?: number | null;
  durationMs?: number | null;
}

export interface RunGraphNode {
  runId: string;
  status: string;
  startedAtMs?: number | null;
  completedAtMs?: number | null;
  children: RunGraphNode[];
}

export interface RunsActiveListPayload {
  runs: RunSummary[];
  total: number;
  filters: Record<string, unknown>;
}

export interface RunsRecentListPayload {
  runs: RunSummary[];
  total: number;
  filters: Record<string, unknown>;
}

export interface TasksActiveListPayload {
  tasks: TaskSummary[];
  total: number;
  filters: Record<string, unknown>;
}

export interface TasksRecentListPayload {
  tasks: TaskSummary[];
  total: number;
  filters: Record<string, unknown>;
}

export interface RunGraphGetPayload {
  runId: string;
  graph: RunGraphNode;
  nodeCount: number;
}
