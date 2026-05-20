/**
 * Agent connection - handles spawning the debug agent RPC and JSON line communication.
 */

import { spawn, type ChildProcess } from 'node:child_process';
import { createInterface, type Interface as ReadlineInterface } from 'node:readline';
import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket, { type RawData } from 'ws';
import type {
  ServerMessage,
  ClientCommand,
  ReadyMessage,
  ApprovalDecision,
} from './types.js';

export const AGENT_RESTART_EXIT_CODE = 75;

export interface AgentConnectionOptions {
  /** Working directory for the agent */
  cwd?: string;
  /** Model specification in format "provider:model_id" */
  model?: string;
  /** Base URL override for the model provider */
  baseUrl?: string;
  /** Custom system prompt */
  systemPrompt?: string;
  /** Enable debug mode */
  debug?: boolean;
  /** Enable UI support (required for overlays) */
  ui?: boolean;
  /** Session file to resume */
  sessionFile?: string;
  /** Path to the lemon project root */
  lemonPath?: string;
  /** Additional root hints used while discovering the lemon project root */
  lemonRootHints?: string[];
  /** Custom resolver for lemon project root discovery */
  lemonPathResolver?: () => string | null;
  /** Command used to launch the local agent process */
  agentCommand?: string;
  /** Base command args used to launch the local agent process */
  agentCommandArgs?: string[];
  /** Path to the rpc script used by the local agent command */
  agentScriptPath?: string;
  /** Exit code that triggers automatic restart in the TUI */
  agentRestartExitCode?: number;
  /** WebSocket URL for LemonControlPlane (OpenClaw) */
  wsUrl?: string;
  /** Auth token for WebSocket connection */
  wsToken?: string;
  /** Role for WebSocket connection (operator/node/device) */
  wsRole?: string;
  /** Scopes for WebSocket connection (strings) */
  wsScopes?: string[];
  /** Client ID for WebSocket connection */
  wsClientId?: string;
  /** Default session key for WebSocket connection */
  wsSessionKey?: string;
  /** Default agent ID for WebSocket connection */
  wsAgentId?: string;
}

// ============================================================================
// OpenClaw WebSocket Frame Types (Control Plane)
// ============================================================================

interface OpenClawRequestFrame {
  type: 'req';
  id: string;
  method: string;
  params?: Record<string, unknown> | null;
}

interface OpenClawResponseFrame {
  type: 'res';
  id: string;
  ok: boolean;
  payload?: Record<string, unknown> | null;
  error?: { code?: string; message?: string; details?: unknown } | null;
}

interface OpenClawEventFrame {
  type: 'event';
  event: string;
  payload?: Record<string, unknown> | null;
  seq?: number;
  stateVersion?: Record<string, unknown> | null;
}

interface OpenClawHelloOkFrame {
  type: 'hello-ok';
  protocol: number;
  server: Record<string, unknown>;
  features: Record<string, unknown>;
  snapshot: Record<string, unknown>;
  policy: Record<string, unknown>;
  auth?: Record<string, unknown> | null;
}

type OpenClawFrame =
  | OpenClawRequestFrame
  | OpenClawResponseFrame
  | OpenClawEventFrame
  | OpenClawHelloOkFrame;

type OpenClawPendingRequest = {
  method: string;
  sessionId?: string | null;
  meta?: Record<string, unknown>;
};

type GoalCommandOptions = {
  maxContinuations?: number;
  maxTicks?: number;
  intervalMs?: number;
  waitTimeoutMs?: number;
  judgeModel?: string;
  judgeFailurePolicy?: string;
  model?: string;
  auto?: boolean;
};

type KanbanCommandOptions = {
  status?: string;
  owner?: string;
  workspace?: string;
  priority?: string;
  assignee?: string;
  workerProfile?: string;
  sessionKey?: string;
  runId?: string;
  author?: string;
  limit?: number;
  intervalMs?: number;
  maxConcurrency?: number;
  leaseMs?: number;
  workerId?: string;
};

const WS_RECONNECT_BASE_DELAY_MS = 500;
const WS_RECONNECT_MAX_DELAY_MS = 10_000;
const WS_COMMAND_QUEUE_LIMIT = 200;

type ParsedOpenClawEventAction =
  | {
      kind: 'agent_started';
      sessionKey: string;
      runId?: string;
    }
  | {
      kind: 'agent_completed';
      sessionKey: string;
      runId?: string;
      answer?: string;
    }
  | {
      kind: 'chat_delta';
      sessionKey: string;
      runId: string;
      text: string;
    }
  | {
      kind: 'tool_started';
      sessionKey: string;
      id: string;
      name: string;
      args: Record<string, unknown>;
    }
  | {
      kind: 'tool_updated';
      sessionKey: string;
      id: string;
      name: string;
      args: Record<string, unknown>;
      partialResult: unknown;
    }
  | {
      kind: 'tool_ended';
      sessionKey: string;
      id: string;
      name: string;
      result: unknown;
      isError: boolean;
    }
  | {
      kind: 'ui_notify';
      message: string;
      notifyType: 'info' | 'warning' | 'success' | 'error';
    };

function readNonEmptyString(value: unknown): string | null {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function asRecord(value: unknown): Record<string, unknown> {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return {};
}

function readFiniteNumber(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  return null;
}

function formatInlineList(value: unknown): string {
  if (!Array.isArray(value)) {
    return 'none';
  }

  const values = value
    .map((item) => String(item).trim())
    .filter((item) => item.length > 0);

  return values.length > 0 ? values.join(', ') : 'none';
}

function formatActionMap(value: unknown): string {
  const record = asRecord(value);
  const entries = Object.entries(record)
    .map(([key, item]) => `${key}: ${String(item)}`)
    .filter((item) => item.length > 0);

  return entries.length > 0 ? entries.join(', ') : 'none';
}

function formatSamplingApprovalLines(action: Record<string, unknown>): string[] {
  if (readNonEmptyString(action.type) !== 'mcp_sampling') {
    return [];
  }

  const model = readNonEmptyString(action.requested_model) || 'unspecified';
  const maxTokens = readFiniteNumber(action.max_tokens);
  const messageCount = readFiniteNumber(action.message_count);
  const textChars = readFiniteNumber(action.text_char_count);
  const requestHash = readNonEmptyString(action.request_hash) || 'unknown';

  return [
    `MCP sampling: model ${model} | max tokens ${maxTokens ?? 'unknown'} | messages ${messageCount ?? 'unknown'} | text chars ${textChars ?? 'unknown'}`,
    `roles: ${formatInlineList(action.roles)} | content: ${formatActionMap(action.content_kinds)} | request: ${requestHash}`,
  ];
}

function formatApprovalRequestedNotification(payload: Record<string, unknown>): string {
  const tool = readNonEmptyString(payload.tool) || 'tool';
  const rationale = readNonEmptyString(payload.rationale);
  const action = asRecord(payload.action);
  const authorizationUrl = readNonEmptyString(action.authorization_url);

  if (authorizationUrl) {
    const resource = readNonEmptyString(action.resource);
    const scope = readNonEmptyString(action.scope);
    const redirectUri = readNonEmptyString(action.redirect_uri);
    const context = [
      resource ? `resource: ${resource}` : null,
      scope ? `scope: ${scope}` : null,
      redirectUri ? `redirect: ${redirectUri}` : null,
    ].filter(Boolean);

    return [
      `Approval required for ${tool}.`,
      rationale,
      `Open OAuth: ${authorizationUrl}`,
      context.length > 0 ? context.join(' | ') : null,
    ].filter(Boolean).join(' ');
  }

  return [
    `Approval required for ${tool}.`,
    rationale,
    ...formatSamplingApprovalLines(action),
  ].filter(Boolean).join(' ');
}

function copyGoalOption(params: Record<string, unknown>, key: string, value: unknown): void {
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (trimmed.length > 0) {
      params[key] = trimmed;
    }
    return;
  }

  if (typeof value === 'number' && Number.isFinite(value)) {
    params[key] = value;
    return;
  }

  if (typeof value === 'boolean') {
    params[key] = value;
  }
}

function copyKanbanOption(params: Record<string, unknown>, key: string, value: unknown): void {
  copyGoalOption(params, key, value);
}

function parseSessionCwd(payload: Record<string, unknown>): string {
  return (
    readNonEmptyString(payload.cwd)
    || readNonEmptyString(payload.path)
    || readNonEmptyString(payload.workdir)
    || ''
  );
}

function parseSessionModel(payload: Record<string, unknown>): { provider: string; id: string } | undefined {
  const rawModel = payload.model;

  if (rawModel && typeof rawModel === 'object') {
    const modelPayload = rawModel as Record<string, unknown>;
    const provider =
      readNonEmptyString(modelPayload.provider)
      || readNonEmptyString(payload.provider);
    const modelId =
      readNonEmptyString(modelPayload.id)
      || readNonEmptyString(modelPayload.model)
      || readNonEmptyString(payload.model_id)
      || readNonEmptyString(payload.modelId);

    if (provider || modelId) {
      return {
        provider: provider || 'unknown',
        id: modelId || 'unknown',
      };
    }
  }

  const provider =
    readNonEmptyString(payload.provider)
    || readNonEmptyString(payload.model_provider)
    || readNonEmptyString(payload.modelProvider);

  let modelId: string | null =
    readNonEmptyString(payload.model_id)
    || readNonEmptyString(payload.modelId)
    || (typeof rawModel === 'string' ? readNonEmptyString(rawModel) : null);

  if (!provider && modelId?.includes(':')) {
    const [parsedProvider, ...rest] = modelId.split(':');
    const parsedId = rest.join(':').trim();
    if (parsedProvider && parsedId) {
      return {
        provider: parsedProvider,
        id: parsedId,
      };
    }
  }

  if (!provider && !modelId) {
    return undefined;
  }

  modelId = modelId || 'unknown';
  return {
    provider: provider || 'unknown',
    id: modelId,
  };
}

function formatGoalResponse(method: string, payload: Record<string, unknown>): string {
  if (method === 'goal.clear') {
    return 'Goal cleared.';
  }

  if (
    (method === 'goal.loop.start' || method === 'goal.loop.stop' || method === 'goal.loop.status')
    && payload.loop
  ) {
    const loop = asRecord(payload.loop);
    const goal = asRecord(payload.goal);
    const lines = [
      method === 'goal.loop.start'
        ? 'Goal Loop Started'
        : method === 'goal.loop.stop'
          ? 'Goal Loop Stopped'
          : 'Goal Loop Status',
      `Loop status: ${readNonEmptyString(loop.status) || 'unknown'}`,
      `Session: ${readNonEmptyString(loop.sessionKey || loop.session_key) || 'unknown'}`,
    ];

    const maxTicks = Number(loop.maxTicks || loop.max_ticks || 0) || 0;
    if (maxTicks > 0) {
      lines.push(`Max ticks: ${maxTicks}`);
    }

    const goalStatus = readNonEmptyString(goal.status);
    if (goalStatus) {
      lines.push(`Goal status: ${goalStatus}`);
    }

    return lines.join('\n');
  }

  const goal = asRecord(payload.goal || payload);
  if (Object.keys(goal).length === 0) {
    return 'Goal Status\nState: none';
  }

  const status = readNonEmptyString(goal.status) || 'unknown';
  const id = readNonEmptyString(goal.id) || 'unknown';
  const objective = readNonEmptyString(goal.objective);
  const objectiveBytes =
    (objective ? Buffer.byteLength(objective, 'utf8') : 0)
    || Number(goal.objectiveBytes || goal.objective_bytes || 0)
    || 0;
  const continuations = Number(goal.continuationCount || goal.continuation_count || 0) || 0;

  const title =
    method === 'goal.set'
      ? 'Goal Set'
      : method === 'goal.pause'
        ? 'Goal Paused'
        : method === 'goal.resume'
          ? 'Goal Resumed'
          : method === 'goal.continue'
            ? 'Goal Continuation Submitted'
            : method === 'goal.loop.once'
              ? 'Goal Loop Tick'
              : method === 'goal.loop.start'
                ? 'Goal Loop Started'
                : method === 'goal.loop.stop'
                  ? 'Goal Loop Stopped'
                  : method === 'goal.loop.status'
                    ? 'Goal Loop Status'
              : 'Goal Status';

  const runId = readNonEmptyString(payload.runId || payload.run_id);
  const verdict = asRecord(payload.verdict);
  const verdictAction = readNonEmptyString(verdict.action);
  const verdictReason = readNonEmptyString(verdict.reason);

  const lines = [
    title,
    `Status: ${status}`,
    `Goal id: ${id}`,
    `Objective bytes: ${objectiveBytes}`,
    `Continuations: ${continuations}`,
  ];

  if (runId) {
    lines.push(`Run id: ${runId}`);
  }

  if (verdictAction) {
    lines.push(`Verdict: ${verdictAction}`);
  }

  if (verdictReason) {
    lines.push(`Reason: ${verdictReason}`);
  }

  return lines.join('\n');
}

function formatKanbanResponse(method: string, payload: Record<string, unknown>): string {
  if (method === 'kanban.board.list') {
    const boards = Array.isArray(payload.boards) ? payload.boards : [];
    const total = Number(payload.total || boards.length) || 0;
    const lines = [`Kanban Boards: ${total}`];
    boards.slice(0, 8).forEach((rawBoard) => {
      const board = asRecord(rawBoard);
      const id = readNonEmptyString(board.id) || 'unknown';
      const status = readNonEmptyString(board.status) || 'unknown';
      const owner = readNonEmptyString(board.owner);
      lines.push(`${id} - ${status}${owner ? ` - ${owner}` : ''}`);
    });
    return lines.join('\n');
  }

  if (method === 'kanban.board.get' || method === 'kanban.board.archive') {
    const board = asRecord(payload.board || payload);
    const tasks = Array.isArray(payload.tasks) ? payload.tasks : [];
    const id = readNonEmptyString(board.id) || 'unknown';
    const status = readNonEmptyString(board.status) || 'unknown';
    const lines = [
      method === 'kanban.board.archive' ? 'Kanban Board Archived' : 'Kanban Board',
      `Board id: ${id}`,
      `Status: ${status}`,
    ];
    if (method === 'kanban.board.get') {
      lines.push(`Tasks: ${Number(payload.totalTasks || tasks.length) || 0}`);
    }
    tasks.slice(0, 8).forEach((rawTask) => {
      const task = asRecord(rawTask);
      const taskId = readNonEmptyString(task.id) || 'unknown';
      const taskStatus = readNonEmptyString(task.status) || 'unknown';
      const priority = readNonEmptyString(task.priority);
      lines.push(`${taskId} - ${taskStatus}${priority ? ` - ${priority}` : ''}`);
    });
    return lines.join('\n');
  }

  if (method.startsWith('kanban.dispatcher.')) {
    const dispatcher = asRecord(payload.dispatcher);
    const running = typeof payload.running === 'boolean' ? payload.running : null;
    const status =
      readNonEmptyString(dispatcher.status)
      || (running === null ? 'unknown' : running ? 'running' : 'stopped');
    const lines = [
      method === 'kanban.dispatcher.start'
        ? 'Kanban Dispatcher Started'
        : method === 'kanban.dispatcher.stop'
          ? 'Kanban Dispatcher Stopped'
          : 'Kanban Dispatcher Status',
      `Status: ${status}`,
    ];
    const boardId = readNonEmptyString(dispatcher.boardId || dispatcher.board_id);
    if (boardId) {
      lines.push(`Board id: ${boardId}`);
    }
    return lines.join('\n');
  }

  const title =
    method === 'kanban.board.create'
      ? 'Kanban Board Created'
      : method === 'kanban.task.create'
        ? 'Kanban Task Created'
        : method === 'kanban.task.update'
          ? 'Kanban Task Updated'
          : method === 'kanban.task.comment'
            ? 'Kanban Task Commented'
            : 'Kanban Updated';
  const board = method === 'kanban.board.create' ? asRecord(payload) : asRecord(payload.board);
  const task = method.startsWith('kanban.task.') ? asRecord(payload.task || payload) : {};
  const taskId = readNonEmptyString(task.id);
  const boardId = readNonEmptyString(board.id || task.boardId || task.board_id);
  const status = readNonEmptyString(task.status || board.status) || 'unknown';
  const lines = [title, `Status: ${status}`];
  if (boardId) lines.push(`Board id: ${boardId}`);
  if (taskId) lines.push(`Task id: ${taskId}`);
  return lines.join('\n');
}

function formatCheckpointResponse(method: string, payload: Record<string, unknown>): string {
  const checkpointId = readNonEmptyString(payload.checkpointId || payload.checkpoint_id) || 'unknown';

  if (method === 'checkpoint.restore') {
    const restored = Array.isArray(payload.restored) ? payload.restored : [];
    const count = Number(payload.restoredCount || payload.restored_count || restored.length) || 0;
    const lines = ['Checkpoint Restored', `Checkpoint id: ${checkpointId}`, `Restored paths: ${count}`];
    restored.slice(0, 8).forEach((pathValue) => {
      const pathText = readNonEmptyString(pathValue);
      if (pathText) lines.push(pathText);
    });
    return lines.join('\n');
  }

  const changed = Array.isArray(payload.changed) ? payload.changed : [];
  const count = Number(payload.changedCount || payload.changed_count || changed.length) || 0;
  const output = readNonEmptyString(payload.output);
  const lines = ['Checkpoint Diff', `Checkpoint id: ${checkpointId}`, `Changed paths: ${count}`];
  changed.slice(0, 8).forEach((pathValue) => {
    const pathText = readNonEmptyString(pathValue);
    if (pathText) lines.push(pathText);
  });
  if (output) lines.push('', output);
  return lines.join('\n');
}

function formatCronResponse(method: string, payload: Record<string, unknown>): string {
  if (method === 'cron.abort') {
    const run = asRecord(payload.run || payload);
    const runId = readNonEmptyString(run.id || run.runId || run.run_id) || 'unknown';
    const status = readNonEmptyString(run.status) || 'aborted';
    return ['Cron Run Aborted', `Run id: ${runId}`, `Status: ${status}`].join('\n');
  }

  return 'Cron Updated';
}

function formatApprovalResolveResponse(payload: Record<string, unknown>): string {
  const approvalId = readNonEmptyString(payload.approvalId || payload.approval_id) || 'unknown';
  const decision = readNonEmptyString(payload.decision) || 'resolved';
  return ['Approval Resolved', `Approval id: ${approvalId}`, `Decision: ${decision}`].join('\n');
}

function formatApprovalListResponse(payload: Record<string, unknown>): string {
  const pending = Array.isArray(payload.pending) ? payload.pending : [];
  const lines = [`Pending Approvals: ${pending.length}`];

  pending.slice(0, 8).forEach((rawPending) => {
    const item = asRecord(rawPending);
    const id = readNonEmptyString(item.id || item.approvalId || item.approval_id) || 'unknown';
    const tool = readNonEmptyString(item.tool) || 'tool';
    const action = asRecord(item.action);
    const authorizationUrl = readNonEmptyString(action.authorization_url);
    lines.push(`${id} - ${tool}`);

    if (authorizationUrl) {
      const resource = readNonEmptyString(action.resource);
      const scope = readNonEmptyString(action.scope);
      const redirectUri = readNonEmptyString(action.redirect_uri);
      const context = [
        resource ? `resource: ${resource}` : null,
        scope ? `scope: ${scope}` : null,
        redirectUri ? `redirect: ${redirectUri}` : null,
      ].filter(Boolean);

      lines.push(`Open OAuth: ${authorizationUrl}`);
      if (context.length > 0) {
        lines.push(context.join(' | '));
      }
    }

    lines.push(...formatSamplingApprovalLines(action));
  });

  return lines.join('\n');
}

function parseOpenClawFrame(payload: string): OpenClawFrame | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(payload);
  } catch {
    return null;
  }

  if (!parsed || typeof parsed !== 'object') {
    return null;
  }

  const frame = parsed as { type?: unknown };
  if (
    frame.type !== 'req'
    && frame.type !== 'res'
    && frame.type !== 'event'
    && frame.type !== 'hello-ok'
  ) {
    return null;
  }

  return parsed as OpenClawFrame;
}

function mapOpenClawResponseToMessages(
  frame: OpenClawResponseFrame,
  pending?: OpenClawPendingRequest,
  now: () => number = () => Date.now()
): ServerMessage[] {
  if (!frame.ok) {
    const message =
      frame.error?.message
      || frame.error?.code
      || 'Control-plane request failed';
    return [{
      type: 'error',
      message,
      session_id: pending?.sessionId || undefined,
    }];
  }

  const method = pending?.method;
  const payload = asRecord(frame.payload);

  switch (method) {
    case 'models.list': {
      const models = Array.isArray(payload.models) ? payload.models : [];
      const providers = new Map<string, Array<{ id: string; name?: string }>>();
      for (const model of models) {
        const modelPayload = asRecord(model);
        const provider = String(modelPayload.provider || 'unknown');
        const list = providers.get(provider) || [];
        list.push({
          id: String(modelPayload.id || ''),
          name: modelPayload.name ? String(modelPayload.name) : undefined,
        });
        providers.set(provider, list);
      }

      return [{
        type: 'models_list',
        providers: Array.from(providers.entries()).map(([id, providerModels]) => ({
          id,
          models: providerModels,
        })),
        error: null,
      }];
    }

    case 'sessions.list':
    case 'sessions.list.running':
    case 'sessions.active.list.running': {
      const sessionsPayload = Array.isArray(payload.sessions) ? payload.sessions : [];
      const mapped = sessionsPayload.map((session) => {
        const sessionPayload = asRecord(session);
        const isStreaming =
          method === 'sessions.active.list.running'
            ? sessionPayload.active !== false
              || readNonEmptyString(sessionPayload.runId) !== null
            : false;

        return {
          path: String(sessionPayload.sessionKey || sessionPayload.id || ''),
          id: String(sessionPayload.sessionKey || sessionPayload.id || ''),
          timestamp: Number(sessionPayload.updatedAtMs || sessionPayload.createdAtMs || now()),
          cwd: parseSessionCwd(sessionPayload),
          model: parseSessionModel(sessionPayload),
          is_streaming: isStreaming,
        };
      });

      if (method === 'sessions.list') {
        return [{
          type: 'sessions_list',
          sessions: mapped.map((session) => ({
            path: session.path,
            id: session.id,
            timestamp: session.timestamp,
            cwd: session.cwd,
            model: session.model,
          })),
        }];
      }

      return [{
        type: 'running_sessions',
        sessions: mapped.map((session) => ({
          session_id: session.id,
          cwd: session.cwd,
          is_streaming: session.is_streaming,
          model: session.model,
        })),
        error: null,
      }];
    }

    case 'sessions.delete': {
      return [{
        type: 'session_closed',
        session_id: pending?.sessionId || '',
        reason: 'normal',
      }];
    }

    case 'sessions.start': {
      const session_id =
        readNonEmptyString(pending?.sessionId)
        || readNonEmptyString(payload.sessionKey)
        || '';

      const pendingMeta = asRecord(pending?.meta);
      const cwd =
        readNonEmptyString(pendingMeta.cwd)
        || readNonEmptyString(payload.cwd)
        || '';

      const model =
        parseSessionModel(payload)
        || parseSessionModel(pendingMeta)
        || { provider: 'unknown', id: 'unknown' };

      return [
        {
          type: 'session_started',
          session_id,
          cwd,
          model,
        },
        {
          type: 'active_session',
          session_id,
        },
      ];
    }

    case 'sessions.active.set': {
      const session_id =
        readNonEmptyString(pending?.sessionId)
        || readNonEmptyString(payload.sessionKey)
        || null;

      return [{
        type: 'active_session',
        session_id,
      }];
    }

    case 'sessions.reset': {
      return [{
        type: 'ui_notify',
        params: {
          message: `Session reset: ${pending?.sessionId || ''}`,
          notify_type: 'success',
        },
      }];
    }

    case 'chat.abort': {
      return [{
        type: 'ui_notify',
        params: {
          message: 'Abort requested',
          notify_type: 'info',
        },
      }];
    }

    case 'goal.set':
    case 'goal.pause':
    case 'goal.resume':
    case 'goal.continue':
    case 'goal.loop.once':
    case 'goal.loop.start':
    case 'goal.loop.stop':
    case 'goal.loop.status':
    case 'goal.clear':
    case 'goal.status': {
      return [{
        type: 'ui_notify',
        params: {
          message: formatGoalResponse(method, payload),
          notify_type: method === 'goal.clear' ? 'success' : 'info',
        },
      }];
    }

    case 'kanban.board.create':
    case 'kanban.board.list':
    case 'kanban.board.get':
    case 'kanban.board.archive':
    case 'kanban.task.create':
    case 'kanban.task.update':
    case 'kanban.task.comment':
    case 'kanban.dispatcher.start':
    case 'kanban.dispatcher.status':
    case 'kanban.dispatcher.stop': {
      return [{
        type: 'ui_notify',
        params: {
          message: formatKanbanResponse(method, payload),
          notify_type: method === 'kanban.board.create' || method === 'kanban.board.archive' || method === 'kanban.task.create' ? 'success' : 'info',
        },
      }];
    }

    case 'checkpoint.diff':
    case 'checkpoint.restore': {
      return [{
        type: 'ui_notify',
        params: {
          message: formatCheckpointResponse(method, payload),
          notify_type: method === 'checkpoint.restore' ? 'success' : 'info',
        },
      }];
    }

    case 'cron.abort': {
      return [{
        type: 'ui_notify',
        params: {
          message: formatCronResponse(method, payload),
          notify_type: 'success',
        },
      }];
    }

    case 'exec.approval.resolve': {
      const decision = readNonEmptyString(payload.decision) || '';
      return [{
        type: 'ui_notify',
        params: {
          message: formatApprovalResolveResponse(payload),
          notify_type: decision === 'deny' ? 'error' : 'success',
        },
      }];
    }

    case 'exec.approvals.get': {
      return [{
        type: 'ui_notify',
        params: {
          message: formatApprovalListResponse(payload),
          notify_type: 'info',
        },
      }];
    }

    case 'health': {
      return [{ type: 'pong' }];
    }

    default:
      return [];
  }
}

function mapOpenClawEventToActions(
  frame: OpenClawEventFrame,
  defaultSessionKey: string
): ParsedOpenClawEventAction[] {
  if (frame.event === 'agent') {
    const payload = asRecord(frame.payload);
    const eventType = String(payload.type || '');
    const sessionKey =
      readNonEmptyString(payload.sessionKey)
      || defaultSessionKey;
    const runId = readNonEmptyString(payload.runId) || undefined;

    if (eventType === 'started') {
      return [{
        kind: 'agent_started',
        sessionKey,
        runId,
      }];
    }

    if (eventType === 'completed') {
      return [{
        kind: 'agent_completed',
        sessionKey,
        runId,
        answer: readNonEmptyString(payload.answer) || undefined,
      }];
    }

    if (eventType === 'tool_use') {
      const action = asRecord(payload.action);
      const detail = asRecord(action.detail);
      const id =
        readNonEmptyString(action.id)
        || readNonEmptyString(action.title)
        || `tool-${Date.now()}`;
      const name =
        readNonEmptyString(detail.name)
        || readNonEmptyString(action.title)
        || 'tool';
      const args = asRecord(detail.args);
      const phase = String(payload.phase || '');
      const result =
        detail.result !== undefined
          ? detail.result
          : readNonEmptyString(payload.message) || payload.message || detail;

      if (phase === 'started' || phase === 'start') {
        return [{ kind: 'tool_started', sessionKey, id, name, args }];
      }

      if (phase === 'completed' || phase === 'complete' || phase === 'ended' || phase === 'end') {
        return [
          { kind: 'tool_started', sessionKey, id, name, args },
          {
            kind: 'tool_ended',
            sessionKey,
            id,
            name,
            result,
            isError: payload.ok === false,
          },
        ];
      }

      return [{
        kind: 'tool_updated',
        sessionKey,
        id,
        name,
        args,
        partialResult: result,
      }];
    }
  }

  if (frame.event === 'chat') {
    const payload = asRecord(frame.payload);
    const eventType = String(payload.type || '');
    if (eventType !== 'delta') {
      return [];
    }
    const runId = String(payload.runId || '');
    const sessionKey =
      readNonEmptyString(payload.sessionKey)
      || defaultSessionKey;
    const text = String(payload.text || '');
    return [{
      kind: 'chat_delta',
      sessionKey,
      runId,
      text,
    }];
  }

  if (frame.event === 'exec.approval.requested') {
    const payload = asRecord(frame.payload);
    return [{
      kind: 'ui_notify',
      message: formatApprovalRequestedNotification(payload),
      notifyType: 'warning',
    }];
  }

  if (frame.event === 'exec.approval.resolved') {
    const payload = asRecord(frame.payload);
    const decision = readNonEmptyString(payload.decision) || 'resolved';
    const approvalId = readNonEmptyString(payload.approvalId || payload.approval_id);
    const tool = readNonEmptyString(payload.tool);
    const suffix = [
      approvalId ? `id: ${approvalId}` : null,
      tool ? `tool: ${tool}` : null,
    ].filter(Boolean);
    return [{
      kind: 'ui_notify',
      message: suffix.length > 0
        ? `Approval ${decision}. ${suffix.join(' | ')}`
        : `Approval ${decision}.`,
      notifyType: decision === 'denied' || decision === 'deny' || decision === 'timeout' ? 'error' : 'success',
    }];
  }

  return [];
}

function parseRestartExitCode(value: unknown): number | null {
  if (typeof value === 'number' && Number.isInteger(value) && value >= 0) {
    return value;
  }
  if (typeof value === 'string') {
    const parsed = Number.parseInt(value, 10);
    if (Number.isInteger(parsed) && parsed >= 0) {
      return parsed;
    }
  }
  return null;
}

function parseRootHints(raw: string | undefined): string[] {
  if (!raw) {
    return [];
  }
  return raw
    .split(path.delimiter)
    .map((hint) => hint.trim())
    .filter(Boolean);
}

export interface AgentConnectionEvents {
  ready: [ReadyMessage];
  message: [ServerMessage];
  error: [Error];
  close: [number | null];
}

export class AgentConnection extends EventEmitter<AgentConnectionEvents> {
  private process: ChildProcess | null = null;
  private readline: ReadlineInterface | null = null;
  private ws: WebSocket | null = null;
  private ready = false;
  private readyPromise: Promise<ReadyMessage> | null = null;
  private readyResolve: ((msg: ReadyMessage) => void) | null = null;
  private readyReject: ((err: Error) => void) | null = null;
  private primarySessionId: string | null = null;
  private activeSessionId: string | null = null;
  private wsPendingRequests = new Map<string, OpenClawPendingRequest>();
  private wsRunBuffers = new Map<string, { sessionKey: string | null; text: string }>();
  private wsLastRunBySession = new Map<string, string>();
  private wsQueuedCommands: ClientCommand[] = [];
  private wsReconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private wsReconnectAttempts = 0;
  private wsExplicitStop = false;
  private wsSessionKey: string | null = null;
  private restartExitCode: number | null = null;

  constructor(private options: AgentConnectionOptions = {}) {
    super();
  }

  private cleanupProcess(): void {
    if (this.readline) {
      try {
        this.readline.close();
      } catch {
        // ignore
      }
      this.readline = null;
    }
    this.process = null;
  }

  private cleanupSocket(closeSocket = true): void {
    if (this.ws) {
      try {
        this.ws.removeAllListeners();
        if (closeSocket) {
          this.ws.close();
        }
      } catch {
        // ignore
      }
      this.ws = null;
    }
  }

  /**
   * Starts the agent process and waits for the ready message.
   */
  async start(): Promise<ReadyMessage> {
    if (this.process) {
      throw new Error('Agent already started');
    }
    if (this.ws) {
      throw new Error('Agent already started');
    }

    if (this.shouldUseWebSocket()) {
      return await this.startWebSocket();
    }

    const lemonPath = this.resolveLemonPath();

    if (!lemonPath) {
      throw new Error(
        'Could not find lemon project. Set LEMON_PATH env var or pass lemonPath option.'
      );
    }

    const launchConfig = this.buildLocalAgentLaunch(lemonPath);

    // Create promise for ready message
    this.readyPromise = new Promise((resolve, reject) => {
      this.readyResolve = resolve;
      this.readyReject = reject;
    });

    this.process = spawn(launchConfig.command, launchConfig.args, {
      cwd: launchConfig.cwd,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: {
        ...process.env,
        MIX_ENV: 'dev',
      },
    });

    // Set up line reader for stdout
    this.readline = createInterface({
      input: this.process.stdout!,
      crlfDelay: Infinity,
    });

    this.readline.on('line', (line) => {
      this.handleLine(line);
    });

    // Handle stderr (debug output)
    this.process.stderr?.on('data', (data) => {
      if (this.options.debug) {
        process.stderr.write(data);
      }
    });

    // Handle process close
    this.process.on('close', (code) => {
      this.ready = false;
      // If we never got "ready", unblock start() callers.
      if (!this.ready && this.readyReject) {
        this.readyReject(new Error(`Agent exited before ready (code: ${code})`));
        this.readyResolve = null;
        this.readyReject = null;
      }
      this.cleanupProcess();
      this.emit('close', code);
    });

    // Handle process error
    this.process.on('error', (err) => {
      if (!this.ready && this.readyReject) {
        this.readyReject(err);
      }
      this.emit('error', err);
    });

    // Wait for ready message
    const readyMsg = await this.readyPromise;
    this.ready = true;
    return readyMsg;
  }

  private shouldUseWebSocket(): boolean {
    return Boolean(
      this.options.wsUrl
      || process.env.LEMON_WS_URL
    );
  }

  private resolveWsUrl(): string {
    const url = this.options.wsUrl || process.env.LEMON_WS_URL;
    if (!url) {
      throw new Error('WebSocket URL required. Set --ws-url or LEMON_WS_URL.');
    }
    return url;
  }

  private resolveWsSessionKey(): string {
    if (this.wsSessionKey) {
      return this.wsSessionKey;
    }
    const sessionKey =
      this.options.wsSessionKey
      || process.env.LEMON_SESSION_KEY
      || this.defaultSessionKey();
    this.wsSessionKey = sessionKey;
    return sessionKey;
  }

  private defaultSessionKey(): string {
    const agentId =
      this.options.wsAgentId
      || process.env.LEMON_AGENT_ID
      || 'default';
    return `agent:${agentId}:main`;
  }

  private parseModelInfo(): { provider: string; id: string } {
    const model = this.options.model || process.env.LEMON_DEFAULT_MODEL || 'remote';
    const parts = model.split(':');
    if (parts.length >= 2) {
      return { provider: parts.shift() || 'remote', id: parts.join(':') || 'remote' };
    }
    return { provider: 'remote', id: model };
  }

  getRestartExitCode(): number {
    if (this.restartExitCode !== null) {
      return this.restartExitCode;
    }

    this.restartExitCode =
      parseRestartExitCode(this.options.agentRestartExitCode)
      ?? parseRestartExitCode(process.env.LEMON_AGENT_RESTART_EXIT_CODE)
      ?? AGENT_RESTART_EXIT_CODE;

    return this.restartExitCode;
  }

  private resolveLemonPath(): string | null {
    const explicitPath =
      readNonEmptyString(this.options.lemonPath)
      || readNonEmptyString(process.env.LEMON_PATH);
    if (explicitPath) {
      return explicitPath;
    }

    if (this.options.lemonPathResolver) {
      const resolved = this.options.lemonPathResolver();
      return readNonEmptyString(resolved);
    }

    const hints = [
      ...(this.options.lemonRootHints || []),
      ...parseRootHints(process.env.LEMON_ROOT_HINTS),
      this.options.cwd || '',
    ].filter(Boolean);

    return findLemonPath(hints);
  }

  private buildLocalAgentLaunch(lemonPath: string): { command: string; args: string[]; cwd: string } {
    const command =
      readNonEmptyString(this.options.agentCommand)
      || readNonEmptyString(process.env.LEMON_AGENT_COMMAND)
      || 'mix';

    const defaultScriptPath =
      readNonEmptyString(this.options.agentScriptPath)
      || readNonEmptyString(process.env.LEMON_AGENT_SCRIPT_PATH)
      || 'scripts/debug_agent_rpc.exs';

    const args = this.options.agentCommandArgs
      ? [...this.options.agentCommandArgs]
      : ['run', defaultScriptPath, '--'];

    if (this.options.cwd) {
      args.push('--cwd', this.options.cwd);
    }
    if (this.options.model) {
      args.push('--model', this.options.model);
    }
    if (this.options.baseUrl) {
      args.push('--base_url', this.options.baseUrl);
    }
    if (this.options.systemPrompt) {
      args.push('--system_prompt', this.options.systemPrompt);
    }
    if (this.options.sessionFile) {
      args.push('--session-file', this.options.sessionFile);
    }
    if (this.options.debug) {
      args.push('--debug');
    }
    if (this.options.ui === false) {
      args.push('--no-ui');
    }

    return {
      command,
      args,
      cwd: lemonPath,
    };
  }

  private buildReadyMessage(): ReadyMessage {
    const sessionKey = this.resolveWsSessionKey();
    const primarySessionId = this.primarySessionId || sessionKey;
    const activeSessionId = this.activeSessionId || primarySessionId;
    return {
      type: 'ready',
      cwd: this.options.cwd || process.cwd(),
      model: this.parseModelInfo(),
      debug: Boolean(this.options.debug),
      ui: false,
      primary_session_id: primarySessionId,
      active_session_id: activeSessionId,
    };
  }

  private async startWebSocket(): Promise<ReadyMessage> {
    this.wsExplicitStop = false;

    this.readyPromise = new Promise((resolve, reject) => {
      this.readyResolve = resolve;
      this.readyReject = reject;
    });

    this.connectWebSocket();

    const readyMsg = await this.readyPromise;
    this.ready = true;
    return readyMsg;
  }

  private connectWebSocket(): void {
    if (this.wsExplicitStop) {
      return;
    }

    if (this.wsReconnectTimer) {
      clearTimeout(this.wsReconnectTimer);
      this.wsReconnectTimer = null;
    }

    const wsUrl = this.resolveWsUrl();
    this.cleanupSocket(false);
    this.ws = new WebSocket(wsUrl);

    this.ws.on('open', () => {
      const connectFrame: OpenClawRequestFrame = {
        type: 'req',
        id: randomUUID(),
        method: 'connect',
        params: {
          role: this.options.wsRole || process.env.LEMON_WS_ROLE || 'operator',
          scopes: this.options.wsScopes || this.parseEnvScopes(),
          client: {
            id: this.options.wsClientId || process.env.LEMON_WS_CLIENT_ID || 'lemon-tui',
          },
          auth: this.options.wsToken || process.env.LEMON_WS_TOKEN
            ? { token: this.options.wsToken || process.env.LEMON_WS_TOKEN }
            : undefined,
        },
      };

      try {
        this.wsPendingRequests.set(connectFrame.id, { method: 'connect' });
        this.ws?.send(JSON.stringify(connectFrame));
      } catch (err) {
        this.readyReject?.(err as Error);
        this.emit('error', err as Error);
      }
    });

    this.ws.on('message', (data: RawData) => {
      this.handleWebSocketMessage(this.decodeWsData(data));
    });

    this.ws.on('close', (code: number) => {
      const startPending = Boolean(this.readyReject);
      this.ready = false;
      this.wsPendingRequests.clear();
      if (startPending && this.readyReject) {
        this.readyReject(new Error(`WebSocket closed before ready (code: ${code})`));
        this.readyResolve = null;
        this.readyReject = null;
      }

      this.cleanupSocket(false);
      this.emit('close', code);

      if (!this.wsExplicitStop) {
        this.scheduleWebSocketReconnect();
      }
    });

    this.ws.on('error', (err: Error) => {
      if (!this.ready && this.readyReject) {
        this.readyReject(err);
      }
      this.emit('error', err);
    });
  }

  private scheduleWebSocketReconnect(): void {
    if (this.wsExplicitStop || this.wsReconnectTimer) {
      return;
    }

    const delay = Math.min(
      WS_RECONNECT_MAX_DELAY_MS,
      WS_RECONNECT_BASE_DELAY_MS * Math.pow(2, this.wsReconnectAttempts)
    );
    this.wsReconnectAttempts += 1;

    this.wsReconnectTimer = setTimeout(() => {
      this.wsReconnectTimer = null;
      if (this.ws || this.wsExplicitStop) {
        return;
      }
      this.connectWebSocket();
    }, delay);
  }

  private queueWebSocketCommand(command: ClientCommand): void {
    if (this.wsQueuedCommands.length >= WS_COMMAND_QUEUE_LIMIT) {
      this.wsQueuedCommands.shift();
      this.emit('message', {
        type: 'error',
        message: 'WebSocket command queue full. Dropped oldest command.',
      });
    }

    this.wsQueuedCommands.push(command);
  }

  private flushQueuedWebSocketCommands(): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN || !this.ready) {
      return;
    }

    if (this.wsQueuedCommands.length === 0) {
      return;
    }

    const queued = [...this.wsQueuedCommands];
    this.wsQueuedCommands = [];

    for (const command of queued) {
      try {
        this.sendWebSocketCommand(command);
      } catch {
        this.wsQueuedCommands.push(command);
        break;
      }
    }
  }

  private decodeWsData(data: RawData): string {
    if (typeof data === 'string') {
      return data;
    }
    if (Buffer.isBuffer(data)) {
      return data.toString('utf8');
    }
    if (Array.isArray(data)) {
      return Buffer.concat(data).toString('utf8');
    }
    // ArrayBuffer
    return Buffer.from(data).toString('utf8');
  }

  private parseEnvScopes(): string[] | undefined {
    const raw = process.env.LEMON_WS_SCOPES;
    if (!raw) {
      return undefined;
    }
    return raw.split(',').map((s) => s.trim()).filter(Boolean);
  }

  /**
   * Sends a command to the agent.
   */
  send(command: ClientCommand): void {
    if (this.shouldUseWebSocket()) {
      if (this.ws && this.ws.readyState === WebSocket.OPEN && this.ready) {
        this.sendWebSocketCommand(command);
      } else {
        this.queueWebSocketCommand(command);
        if (!this.ws) {
          this.connectWebSocket();
        }
      }
      return;
    }

    if (!this.process?.stdin?.writable) {
      throw new Error('Agent not connected');
    }

    const json = JSON.stringify(command);
    this.process.stdin.write(json + '\n');
  }

  private sendWebSocketCommand(command: ClientCommand): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error('Agent not connected');
    }

    switch (command.type) {
      case 'prompt': {
        const sessionKey = command.session_id || this.resolveWsSessionKey();
        this.emitUserMessage(command.text, sessionKey);
        this.sendOpenClawRequest('chat.send', {
          sessionKey,
          prompt: command.text,
          agentId: this.options.wsAgentId || process.env.LEMON_AGENT_ID || 'default',
        }, sessionKey);
        break;
      }

      case 'abort': {
        const sessionKey = command.session_id || this.resolveWsSessionKey();
        const runId = this.wsLastRunBySession.get(sessionKey || '') || null;
        this.sendOpenClawRequest('chat.abort', {
          sessionKey,
          runId,
        }, sessionKey);
        break;
      }

      case 'reset': {
        const sessionKey = command.session_id || this.resolveWsSessionKey();
        this.sendOpenClawRequest('sessions.reset', { sessionKey }, sessionKey);
        break;
      }

      case 'save': {
        this.emit('message', {
          type: 'save_result',
          ok: false,
          error: 'Save is not supported over control-plane WebSocket.',
        });
        break;
      }

      case 'list_sessions': {
        this.sendOpenClawRequest('sessions.list', { limit: 100, offset: 0 }, null);
        break;
      }

      case 'list_running_sessions': {
        this.sendOpenClawRequest('sessions.active.list', { limit: 100 }, null, 'sessions.active.list.running');
        break;
      }

      case 'list_models': {
        this.sendOpenClawRequest('models.list', {}, null);
        break;
      }

      case 'stats': {
        this.emit('message', {
          type: 'error',
          message: 'Stats not supported over control-plane WebSocket.',
          session_id: command.session_id,
        });
        break;
      }

      case 'start_session': {
        const sessionId = this.generateSessionKey();
        const cwd = command.cwd || this.options.cwd || process.cwd();
        const parsedModel = this.parseModelInfo();

        this.sendOpenClawRequest(
          'sessions.active',
          { sessionKey: sessionId },
          sessionId,
          'sessions.start',
          {
            cwd,
            model:
              command.model
              || this.options.model
              || process.env.LEMON_DEFAULT_MODEL
              || `${parsedModel.provider}:${parsedModel.id}`,
          }
        );
        break;
      }

      case 'close_session': {
        this.sendOpenClawRequest('sessions.delete', { sessionKey: command.session_id }, command.session_id);
        break;
      }

      case 'set_active_session': {
        this.sendOpenClawRequest(
          'sessions.active',
          { sessionKey: command.session_id },
          command.session_id,
          'sessions.active.set'
        );
        break;
      }

      case 'ping': {
        this.sendOpenClawRequest('health', {}, null);
        break;
      }

      case 'goal': {
        const sessionKey = command.session_id || this.resolveWsSessionKey();
        const params: Record<string, unknown> = { sessionKey };
        let method = 'goal.status';

        if (command.action === 'set') {
          method = 'goal.set';
          params.objective = command.objective || '';
          params.agentId = this.options.wsAgentId || process.env.LEMON_AGENT_ID || 'default';
          copyGoalOption(params, 'maxContinuations', command.max_continuations);
        } else if (command.action === 'pause') {
          method = 'goal.pause';
        } else if (command.action === 'resume') {
          method = 'goal.resume';
        } else if (command.action === 'continue') {
          method = 'goal.continue';
          copyGoalOption(params, 'maxContinuations', command.max_continuations);
          copyGoalOption(params, 'model', command.model);
        } else if (command.action === 'loop_once') {
          method = 'goal.loop.once';
          copyGoalOption(params, 'maxContinuations', command.max_continuations);
          copyGoalOption(params, 'judgeModel', command.judge_model);
          copyGoalOption(params, 'judgeFailurePolicy', command.judge_failure_policy);
          copyGoalOption(params, 'model', command.model);
        } else if (command.action === 'loop_start') {
          method = 'goal.loop.start';
          copyGoalOption(params, 'maxTicks', command.max_ticks);
          copyGoalOption(params, 'maxContinuations', command.max_continuations);
          copyGoalOption(params, 'intervalMs', command.interval_ms);
          copyGoalOption(params, 'waitTimeoutMs', command.wait_timeout_ms);
          copyGoalOption(params, 'judgeModel', command.judge_model);
          copyGoalOption(params, 'judgeFailurePolicy', command.judge_failure_policy);
          copyGoalOption(params, 'model', command.model);
          copyGoalOption(params, 'auto', command.auto);
        } else if (command.action === 'loop_stop') {
          method = 'goal.loop.stop';
        } else if (command.action === 'loop_status') {
          method = 'goal.loop.status';
        } else if (command.action === 'clear') {
          method = 'goal.clear';
        }

        this.sendOpenClawRequest(method, params, sessionKey);
        break;
      }

      case 'kanban': {
        const params: Record<string, unknown> = {};
        let method = 'kanban.board.list';

        if (command.action === 'board_create') {
          method = 'kanban.board.create';
          params.name = command.name || '';
          copyKanbanOption(params, 'owner', command.owner);
          copyKanbanOption(params, 'workspace', command.workspace);
        } else if (command.action === 'board_get') {
          method = 'kanban.board.get';
          params.boardId = command.board_id || '';
          copyKanbanOption(params, 'limit', command.limit);
        } else if (command.action === 'board_archive') {
          method = 'kanban.board.archive';
          params.boardId = command.board_id || '';
        } else if (command.action === 'task_create') {
          method = 'kanban.task.create';
          params.boardId = command.board_id || '';
          params.title = command.title || '';
          copyKanbanOption(params, 'status', command.status);
          copyKanbanOption(params, 'priority', command.priority);
          copyKanbanOption(params, 'assignee', command.assignee);
          copyKanbanOption(params, 'workerProfile', command.worker_profile);
          copyKanbanOption(params, 'sessionKey', command.session_key);
          copyKanbanOption(params, 'runId', command.run_id);
        } else if (command.action === 'task_update') {
          method = 'kanban.task.update';
          params.taskId = command.task_id || '';
          copyKanbanOption(params, 'status', command.status);
          copyKanbanOption(params, 'priority', command.priority);
          copyKanbanOption(params, 'assignee', command.assignee);
          copyKanbanOption(params, 'workerProfile', command.worker_profile);
          copyKanbanOption(params, 'sessionKey', command.session_key);
          copyKanbanOption(params, 'runId', command.run_id);
        } else if (command.action === 'task_comment') {
          method = 'kanban.task.comment';
          params.taskId = command.task_id || '';
          params.body = command.body || '';
          copyKanbanOption(params, 'author', command.author);
        } else if (command.action === 'dispatcher_start') {
          method = 'kanban.dispatcher.start';
          params.boardId = command.board_id || '';
          copyKanbanOption(params, 'intervalMs', command.interval_ms);
          copyKanbanOption(params, 'maxConcurrency', command.max_concurrency);
          copyKanbanOption(params, 'leaseMs', command.lease_ms);
          copyKanbanOption(params, 'workerId', command.worker_id);
          copyKanbanOption(params, 'workerProfile', command.worker_profile);
        } else if (command.action === 'dispatcher_status') {
          method = 'kanban.dispatcher.status';
          params.boardId = command.board_id || '';
        } else if (command.action === 'dispatcher_stop') {
          method = 'kanban.dispatcher.stop';
          params.boardId = command.board_id || '';
        } else {
          copyKanbanOption(params, 'status', command.status);
          copyKanbanOption(params, 'owner', command.owner);
          copyKanbanOption(params, 'workspace', command.workspace);
          copyKanbanOption(params, 'limit', command.limit);
        }

        this.sendOpenClawRequest(method, params, null);
        break;
      }

      case 'checkpoint': {
        const params: Record<string, unknown> = {
          checkpointId: command.checkpoint_id,
        };
        if (Array.isArray(command.paths) && command.paths.length > 0) {
          params.paths = command.paths;
        }
        const method =
          command.action === 'restore' ? 'checkpoint.restore' : 'checkpoint.diff';
        this.sendOpenClawRequest(method, params, null);
        break;
      }

      case 'cron': {
        this.sendOpenClawRequest('cron.abort', { runId: command.run_id }, null);
        break;
      }

      case 'approval': {
        if (command.action === 'list') {
          this.sendOpenClawRequest('exec.approvals.get', {}, null);
        } else {
          this.sendOpenClawRequest('exec.approval.resolve', {
            approvalId: command.approval_id,
            decision: command.decision,
          }, null);
        }
        break;
      }

      case 'debug':
      case 'ui_response':
      case 'quit':
        // Not supported over control-plane WebSocket
        break;
    }
  }

  private sendOpenClawRequest(
    method: string,
    params: Record<string, unknown>,
    sessionId: string | null,
    pendingMethod?: string,
    pendingMeta?: Record<string, unknown>
  ): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error('Agent not connected');
    }

    const id = randomUUID();
    this.wsPendingRequests.set(id, {
      method: pendingMethod || method,
      sessionId,
      meta: pendingMeta,
    });

    const frame: OpenClawRequestFrame = {
      type: 'req',
      id,
      method,
      params,
    };

    this.ws.send(JSON.stringify(frame));
  }

  private generateSessionKey(): string {
    const agentId =
      this.options.wsAgentId
      || process.env.LEMON_AGENT_ID
      || 'default';
    const id = randomUUID();
    return `agent:${agentId}:tui:local:dm:${id}`;
  }

  private emitUserMessage(text: string, sessionId: string): void {
    const timestamp = Date.now();
    this.emit('message', {
      type: 'event',
      session_id: sessionId,
      event: {
        type: 'message_start',
        data: [
          {
            __struct__: 'Elixir.Ai.Types.UserMessage',
            role: 'user',
            content: text,
            timestamp,
          },
        ],
      },
    });
    this.emit('message', {
      type: 'event',
      session_id: sessionId,
      event: {
        type: 'message_end',
        data: [
          {
            __struct__: 'Elixir.Ai.Types.UserMessage',
            role: 'user',
            content: text,
            timestamp,
          },
        ],
      },
    });
  }

  /**
   * Sends a prompt to the agent.
   */
  prompt(text: string, sessionId?: string): void {
    this.send({ type: 'prompt', text, session_id: sessionId });
  }

  /**
   * Sends an abort command to stop the current operation.
   */
  abort(sessionId?: string): void {
    this.send({ type: 'abort', session_id: sessionId });
  }

  /**
   * Sends a reset command to clear the session.
   */
  reset(sessionId?: string): void {
    this.send({ type: 'reset', session_id: sessionId });
  }

  /**
   * Sends a save command to persist the session.
   */
  save(sessionId?: string): void {
    this.send({ type: 'save', session_id: sessionId });
  }

  /**
   * Requests the list of saved sessions for the current cwd.
   */
  listSessions(): void {
    this.send({ type: 'list_sessions' });
  }

  /**
   * Requests session stats.
   */
  stats(sessionId?: string): void {
    this.send({ type: 'stats', session_id: sessionId });
  }

  /**
   * Sends a ping to check connection.
   */
  ping(): void {
    this.send({ type: 'ping' });
  }

  goalStatus(sessionId?: string): void {
    this.send({ type: 'goal', action: 'status', session_id: sessionId });
  }

  goalSet(objective: string, sessionId?: string, options: GoalCommandOptions = {}): void {
    this.send({
      type: 'goal',
      action: 'set',
      objective,
      session_id: sessionId,
      max_continuations: options.maxContinuations,
    });
  }

  goalPause(sessionId?: string): void {
    this.send({ type: 'goal', action: 'pause', session_id: sessionId });
  }

  goalResume(sessionId?: string): void {
    this.send({ type: 'goal', action: 'resume', session_id: sessionId });
  }

  goalContinue(sessionId?: string, options: GoalCommandOptions = {}): void {
    this.send({
      type: 'goal',
      action: 'continue',
      session_id: sessionId,
      max_continuations: options.maxContinuations,
      model: options.model,
    });
  }

  goalLoopOnce(sessionId?: string, options: GoalCommandOptions = {}): void {
    this.send({
      type: 'goal',
      action: 'loop_once',
      session_id: sessionId,
      max_continuations: options.maxContinuations,
      judge_model: options.judgeModel,
      judge_failure_policy: options.judgeFailurePolicy,
      model: options.model,
    });
  }

  goalLoopStart(sessionId?: string, options: GoalCommandOptions = {}): void {
    this.send({
      type: 'goal',
      action: 'loop_start',
      session_id: sessionId,
      max_ticks: options.maxTicks,
      max_continuations: options.maxContinuations,
      interval_ms: options.intervalMs,
      wait_timeout_ms: options.waitTimeoutMs,
      judge_model: options.judgeModel,
      judge_failure_policy: options.judgeFailurePolicy,
      model: options.model,
      auto: options.auto,
    });
  }

  goalLoopStop(sessionId?: string): void {
    this.send({ type: 'goal', action: 'loop_stop', session_id: sessionId });
  }

  goalLoopStatus(sessionId?: string): void {
    this.send({ type: 'goal', action: 'loop_status', session_id: sessionId });
  }

  goalClear(sessionId?: string): void {
    this.send({ type: 'goal', action: 'clear', session_id: sessionId });
  }

  kanbanBoardList(options: KanbanCommandOptions = {}): void {
    this.send({
      type: 'kanban',
      action: 'board_list',
      status: options.status,
      owner: options.owner,
      workspace: options.workspace,
      limit: options.limit,
    });
  }

  kanbanBoardCreate(name: string, options: KanbanCommandOptions = {}): void {
    this.send({
      type: 'kanban',
      action: 'board_create',
      name,
      owner: options.owner,
      workspace: options.workspace || this.options.cwd,
    });
  }

  kanbanBoardGet(boardId: string, options: KanbanCommandOptions = {}): void {
    this.send({
      type: 'kanban',
      action: 'board_get',
      board_id: boardId,
      limit: options.limit,
    });
  }

  kanbanBoardArchive(boardId: string): void {
    this.send({
      type: 'kanban',
      action: 'board_archive',
      board_id: boardId,
    });
  }

  kanbanTaskCreate(boardId: string, title: string, options: KanbanCommandOptions = {}): void {
    this.send({
      type: 'kanban',
      action: 'task_create',
      board_id: boardId,
      title,
      status: options.status,
      priority: options.priority,
      assignee: options.assignee,
      worker_profile: options.workerProfile,
      session_key: options.sessionKey,
      run_id: options.runId,
    });
  }

  kanbanTaskUpdate(taskId: string, options: KanbanCommandOptions = {}): void {
    this.send({
      type: 'kanban',
      action: 'task_update',
      task_id: taskId,
      status: options.status,
      priority: options.priority,
      assignee: options.assignee,
      worker_profile: options.workerProfile,
      session_key: options.sessionKey,
      run_id: options.runId,
    });
  }

  kanbanTaskComment(taskId: string, body: string, options: KanbanCommandOptions = {}): void {
    this.send({
      type: 'kanban',
      action: 'task_comment',
      task_id: taskId,
      body,
      author: options.author || this.options.wsAgentId || process.env.LEMON_AGENT_ID || 'operator',
    });
  }

  kanbanDispatcherStart(boardId: string, options: KanbanCommandOptions = {}): void {
    this.send({
      type: 'kanban',
      action: 'dispatcher_start',
      board_id: boardId,
      interval_ms: options.intervalMs,
      max_concurrency: options.maxConcurrency,
      lease_ms: options.leaseMs,
      worker_id: options.workerId,
      worker_profile: options.workerProfile,
    });
  }

  kanbanDispatcherStatus(boardId: string): void {
    this.send({ type: 'kanban', action: 'dispatcher_status', board_id: boardId });
  }

  kanbanDispatcherStop(boardId: string): void {
    this.send({ type: 'kanban', action: 'dispatcher_stop', board_id: boardId });
  }

  checkpointDiff(checkpointId: string, paths: string[] = []): void {
    this.send({
      type: 'checkpoint',
      action: 'diff',
      checkpoint_id: checkpointId,
      paths,
    });
  }

  checkpointRestore(checkpointId: string, paths: string[] = []): void {
    this.send({
      type: 'checkpoint',
      action: 'restore',
      checkpoint_id: checkpointId,
      paths,
    });
  }

  cronAbort(runId: string): void {
    this.send({
      type: 'cron',
      action: 'abort',
      run_id: runId,
    });
  }

  approvalResolve(
    approvalId: string,
    decision: ApprovalDecision
  ): void {
    this.send({
      type: 'approval',
      action: 'resolve',
      approval_id: approvalId,
      decision,
    });
  }

  approvalList(): void {
    this.send({
      type: 'approval',
      action: 'list',
    });
  }

  /**
   * Sends a UI response back to the agent.
   */
  respondToUIRequest(id: string, result: unknown, error: string | null = null): void {
    this.send({
      type: 'ui_response',
      id,
      result,
      error,
    });
  }

  /**
   * Starts a new session.
   */
  startSession(opts?: {
    cwd?: string;
    model?: string;
    systemPrompt?: string;
    sessionFile?: string;
    parentSession?: string;
  }): void {
    this.send({
      type: 'start_session',
      cwd: opts?.cwd,
      model: opts?.model,
      system_prompt: opts?.systemPrompt,
      session_file: opts?.sessionFile,
      parent_session: opts?.parentSession,
    });
  }

  /**
   * Closes a running session.
   */
  closeSession(sessionId: string): void {
    this.send({ type: 'close_session', session_id: sessionId });
  }

  /**
   * Requests the list of currently running sessions.
   */
  listRunningSessions(): void {
    this.send({ type: 'list_running_sessions' });
  }

  /**
   * Requests the list of known model providers and models.
   */
  listModels(): void {
    this.send({ type: 'list_models' });
  }

  /**
   * Sets the active session (default session for commands without session_id).
   */
  setActiveSession(sessionId: string): void {
    this.send({ type: 'set_active_session', session_id: sessionId });
  }

  /**
   * Returns the primary session ID from the ready message.
   */
  getPrimarySessionId(): string | null {
    return this.primarySessionId;
  }

  /**
   * Returns the active session ID.
   */
  getActiveSessionId(): string | null {
    return this.activeSessionId;
  }

  /**
   * Stops the agent process.
   */
  stop(): void {
    this.wsExplicitStop = true;
    if (this.wsReconnectTimer) {
      clearTimeout(this.wsReconnectTimer);
      this.wsReconnectTimer = null;
    }
    this.wsQueuedCommands = [];
    this.wsPendingRequests.clear();

    if (this.ws) {
      try {
        this.ws.close();
      } catch {
        // ignore
      }
      return;
    }

    if (!this.process) {
      return;
    }

    try {
      this.send({ type: 'quit' });
    } catch {
      // Ignore errors if already closed
    }

    // Give it a moment to quit gracefully
    setTimeout(() => {
      if (this.process && !this.process.killed) {
        this.process.kill('SIGTERM');
      }
    }, 1000);
  }

  /**
   * Stops the agent process and waits for it to exit.
   */
  stopAndWait(timeoutMs = 5000): Promise<number | null> {
    if (this.ws) {
      return new Promise((resolve) => {
        const onClose = (code: number | null) => {
          clearTimeout(timer);
          this.off('close', onClose);
          resolve(code);
        };

        const timer = setTimeout(() => {
          this.off('close', onClose);
          try {
            this.ws?.terminate();
          } catch {
            // ignore
          }
          resolve(null);
        }, timeoutMs);

        this.on('close', onClose);
        this.stop();
      });
    }

    if (!this.process) {
      return Promise.resolve(null);
    }

    return new Promise((resolve) => {
      const onClose = (code: number | null) => {
        clearTimeout(timer);
        this.off('close', onClose);
        resolve(code);
      };

      const timer = setTimeout(() => {
        this.off('close', onClose);
        try {
          this.process?.kill('SIGKILL');
        } catch {
          // ignore
        }
        resolve(null);
      }, timeoutMs);

      this.on('close', onClose);
      this.stop();
    });
  }

  /**
   * Restarts the agent process (stop + start).
   */
  async restart(): Promise<ReadyMessage> {
    await this.stopAndWait();
    return await this.start();
  }

  /**
   * Returns true if the agent is connected and ready.
   */
  isReady(): boolean {
    return this.ready;
  }

  private handleWebSocketMessage(payload: string): void {
    if (!payload.trim()) {
      return;
    }

    const frame = parseOpenClawFrame(payload);
    if (!frame) {
      if (this.options.debug) {
        process.stderr.write(`[ws] Non-JSON frame: ${payload}\n`);
      }
      return;
    }

    switch (frame.type) {
      case 'hello-ok': {
        const ready = this.buildReadyMessage();
        this.primarySessionId = ready.primary_session_id;
        this.activeSessionId = ready.active_session_id;
        this.ready = true;
        this.wsReconnectAttempts = 0;
        if (this.readyResolve) {
          this.readyResolve(ready);
          this.readyResolve = null;
          this.readyReject = null;
        }
        this.emit('ready', ready);
        this.flushQueuedWebSocketCommands();
        break;
      }

      case 'event':
        this.handleOpenClawEvent(frame);
        break;

      case 'res':
        this.handleOpenClawResponse(frame);
        break;

      case 'req':
        // Client does not handle incoming requests
        break;
    }
  }

  private handleOpenClawResponse(frame: OpenClawResponseFrame): void {
    const pending = this.wsPendingRequests.get(frame.id);
    if (pending) {
      this.wsPendingRequests.delete(frame.id);
    }

    const messages = mapOpenClawResponseToMessages(frame, pending);
    for (const message of messages) {
      if (message.type === 'active_session') {
        this.activeSessionId = message.session_id;
      }
      this.emit('message', message);
    }
  }

  private handleOpenClawEvent(frame: OpenClawEventFrame): void {
    const actions = mapOpenClawEventToActions(frame, this.resolveWsSessionKey());
    for (const action of actions) {
      if (action.kind === 'agent_started') {
        if (action.runId && action.sessionKey) {
          this.wsLastRunBySession.set(action.sessionKey, action.runId);
        }
        this.emit('message', {
          type: 'event',
          session_id: action.sessionKey,
          event: { type: 'agent_start' },
        });
        continue;
      }

      if (action.kind === 'agent_completed') {
        if (action.runId && action.sessionKey) {
          this.wsLastRunBySession.set(action.sessionKey, action.runId);
        }
        this.emitAssistantCompletion(action.sessionKey, action.runId, action.answer);
        this.emit('message', {
          type: 'event',
          session_id: action.sessionKey,
          event: { type: 'agent_end', data: [[]] },
        });
        continue;
      }

      if (action.kind === 'tool_started') {
        this.emit('message', {
          type: 'event',
          session_id: action.sessionKey,
          event: { type: 'tool_execution_start', data: [action.id, action.name, action.args] },
        });
        continue;
      }

      if (action.kind === 'tool_updated') {
        this.emit('message', {
          type: 'event',
          session_id: action.sessionKey,
          event: {
            type: 'tool_execution_update',
            data: [action.id, action.name, action.args, action.partialResult],
          },
        });
        continue;
      }

      if (action.kind === 'tool_ended') {
        this.emit('message', {
          type: 'event',
          session_id: action.sessionKey,
          event: {
            type: 'tool_execution_end',
            data: [action.id, action.name, action.result, action.isError],
          },
        });
        continue;
      }

      if (action.kind === 'ui_notify') {
        this.emit('message', {
          type: 'ui_notify',
          params: {
            message: action.message,
            notify_type: action.notifyType,
          },
        });
        continue;
      }

      this.emitChatDelta(action.sessionKey, action.runId, action.text);
    }
  }

  private emitChatDelta(sessionKey: string, runId: string, text: string): void {
    if (!runId) {
      return;
    }

    let buffer = this.wsRunBuffers.get(runId);
    if (!buffer) {
      buffer = { sessionKey, text: '' };
      this.wsRunBuffers.set(runId, buffer);
      this.emit('message', {
        type: 'event',
        session_id: sessionKey,
        event: { type: 'agent_start' },
      });
    }

    buffer.text += text;
    const assistantMessage = this.buildAssistantMessage(buffer.text);

    const eventType = buffer.text === text ? 'message_start' : 'message_update';
    this.emit('message', {
      type: 'event',
      session_id: sessionKey,
      event: {
        type: eventType,
        data: eventType === 'message_update'
          ? [assistantMessage, []]
          : [assistantMessage],
      },
    });
  }

  private emitAssistantCompletion(
    sessionKey: string,
    runId?: string,
    answer?: string
  ): void {
    let text = answer || '';
    if (runId && this.wsRunBuffers.has(runId)) {
      const buffer = this.wsRunBuffers.get(runId);
      if (buffer) {
        text = buffer.text || text;
      }
      this.wsRunBuffers.delete(runId);
    }

    if (!text) {
      return;
    }

    const assistantMessage = this.buildAssistantMessage(text);
    this.emit('message', {
      type: 'event',
      session_id: sessionKey,
      event: {
        type: 'message_end',
        data: [assistantMessage],
      },
    });
  }

  private buildAssistantMessage(text: string): {
    __struct__: 'Elixir.Ai.Types.AssistantMessage';
    role: 'assistant';
    content: Array<Record<string, unknown>>;
    provider: string;
    model: string;
    api: string;
    stop_reason: 'stop';
    error_message: null;
    timestamp: number;
  } {
    const model = this.parseModelInfo();
    return {
      __struct__: 'Elixir.Ai.Types.AssistantMessage',
      role: 'assistant',
      content: [
        {
          __struct__: 'Elixir.Ai.Types.TextContent',
          type: 'text',
          text,
        },
      ],
      provider: model.provider,
      model: model.id,
      api: 'control_plane',
      stop_reason: 'stop',
      error_message: null,
      timestamp: Date.now(),
    };
  }

  private handleLine(line: string): void {
    if (!line.trim()) {
      return;
    }

    let message: ServerMessage;
    try {
      message = JSON.parse(line) as ServerMessage;
    } catch (err) {
      if (this.options.debug) {
        process.stderr.write(`[rpc] Non-JSON line: ${line}\n`);
      }
      return;
    }

    // Handle ready message specially
    if (message.type === 'ready') {
      this.primarySessionId = message.primary_session_id;
      this.activeSessionId = message.active_session_id;
      if (this.readyResolve) {
        this.readyResolve(message);
        this.readyResolve = null;
        this.readyReject = null;
      }
      this.emit('ready', message);
    }

    // Track active session changes
    if (message.type === 'active_session') {
      this.activeSessionId = message.session_id;
    }

    // Update active session tracking on session lifecycle events
    if (message.type === 'session_started') {
      // Optionally auto-switch to new session (configurable behavior)
      // For now, just track that the session exists
    }

    if (message.type === 'session_closed') {
      // Active session changes are driven by explicit active_session messages.
      if (this.activeSessionId === message.session_id) {
        this.activeSessionId = null;
      }
    }

    this.emit('message', message);
  }
}

/**
 * Attempts to find the lemon project root by walking up from candidate paths.
 */
function findLemonPath(hints: string[] = []): string | null {
  const moduleDir = path.dirname(fileURLToPath(import.meta.url));
  const candidateRoots = new Set<string>([
    process.cwd(),
    moduleDir,
    ...hints.map((hint) => path.resolve(hint)),
  ]);

  for (const candidate of candidateRoots) {
    const found = findLemonPathFrom(candidate);
    if (found) {
      return found;
    }
  }

  return null;
}

function findLemonPathFrom(start: string): string | null {
  let current = path.resolve(start);

  while (true) {
    if (isLemonProjectRoot(current)) {
      return current;
    }

    const parent = path.dirname(current);
    if (parent === current) {
      return null;
    }
    current = parent;
  }
}

function isLemonProjectRoot(candidate: string): boolean {
  try {
    return (
      fs.existsSync(path.join(candidate, 'mix.exs'))
      && fs.existsSync(path.join(candidate, 'apps'))
    );
  } catch {
    return false;
  }
}
