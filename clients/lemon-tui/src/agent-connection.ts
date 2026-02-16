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

type OpenClawPendingRequest = { method: string; sessionId?: string | null };

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
    case 'sessions.list.running': {
      const sessionsPayload = Array.isArray(payload.sessions) ? payload.sessions : [];
      const mapped = sessionsPayload.map((session) => {
        const sessionPayload = asRecord(session);
        return {
          path: String(sessionPayload.sessionKey || sessionPayload.id || ''),
          id: String(sessionPayload.sessionKey || sessionPayload.id || ''),
          timestamp: Number(sessionPayload.updatedAtMs || sessionPayload.createdAtMs || now()),
          cwd: parseSessionCwd(sessionPayload),
          model: parseSessionModel(sessionPayload),
        };
      });

      if (method === 'sessions.list') {
        return [{
          type: 'sessions_list',
          sessions: mapped,
        }];
      }

      return [{
        type: 'running_sessions',
        sessions: mapped.map((session) => ({
          session_id: session.id,
          cwd: session.cwd,
          is_streaming: false,
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

  private cleanupSocket(): void {
    if (this.ws) {
      try {
        this.ws.removeAllListeners();
        this.ws.close();
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
    return {
      type: 'ready',
      cwd: this.options.cwd || process.cwd(),
      model: this.parseModelInfo(),
      debug: Boolean(this.options.debug),
      ui: false,
      primary_session_id: sessionKey,
      active_session_id: sessionKey,
    };
  }

  private async startWebSocket(): Promise<ReadyMessage> {
    const wsUrl = this.resolveWsUrl();

    this.readyPromise = new Promise((resolve, reject) => {
      this.readyResolve = resolve;
      this.readyReject = reject;
    });

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
      }
    });

    this.ws.on('message', (data: RawData) => {
      this.handleWebSocketMessage(this.decodeWsData(data));
    });

    this.ws.on('close', (code: number) => {
      this.ready = false;
      if (!this.ready && this.readyReject) {
        this.readyReject(new Error(`WebSocket closed before ready (code: ${code})`));
        this.readyResolve = null;
        this.readyReject = null;
      }
      this.cleanupSocket();
      this.emit('close', code);
    });

    this.ws.on('error', (err: Error) => {
      if (!this.ready && this.readyReject) {
        this.readyReject(err);
      }
      this.emit('error', err);
    });

    const readyMsg = await this.readyPromise;
    this.ready = true;
    return readyMsg;
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
    if (this.ws) {
      this.sendWebSocketCommand(command);
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
        this.sendOpenClawRequest('sessions.list', { limit: 100, offset: 0 }, null, 'sessions.list.running');
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
        const model = this.parseModelInfo();
        const cwd = command.cwd || this.options.cwd || process.cwd();
        this.emit('message', {
          type: 'session_started',
          session_id: sessionId,
          cwd,
          model,
        });
        break;
      }

      case 'close_session': {
        this.sendOpenClawRequest('sessions.delete', { sessionKey: command.session_id }, command.session_id);
        break;
      }

      case 'set_active_session': {
        this.activeSessionId = command.session_id;
        this.emit('message', {
          type: 'active_session',
          session_id: command.session_id,
        });
        break;
      }

      case 'ping': {
        this.sendOpenClawRequest('health', {}, null);
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
    pendingMethod?: string
  ): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error('Agent not connected');
    }

    const id = randomUUID();
    this.wsPendingRequests.set(id, { method: pendingMethod || method, sessionId });

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
        if (this.readyResolve) {
          this.readyResolve(ready);
          this.readyResolve = null;
          this.readyReject = null;
        }
        this.emit('ready', ready);
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
