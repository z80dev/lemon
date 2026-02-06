/**
 * Agent connection - handles spawning the debug agent RPC and JSON line communication.
 */

import { spawn, type ChildProcess } from 'node:child_process';
import { createInterface, type Interface as ReadlineInterface } from 'node:readline';
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import path from 'node:path';
import type {
  ServerMessage,
  ClientCommand,
  ReadyMessage,
  SessionStartedMessage,
  SessionClosedMessage,
  RunningSessionsMessage,
  ActiveSessionMessage,
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
  private ready = false;
  private readyPromise: Promise<ReadyMessage> | null = null;
  private readyResolve: ((msg: ReadyMessage) => void) | null = null;
  private readyReject: ((err: Error) => void) | null = null;
  private primarySessionId: string | null = null;
  private activeSessionId: string | null = null;

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

  /**
   * Starts the agent process and waits for the ready message.
   */
  async start(): Promise<ReadyMessage> {
    if (this.process) {
      throw new Error('Agent already started');
    }

    const lemonPath = this.options.lemonPath || process.env.LEMON_PATH || findLemonPath();

    if (!lemonPath) {
      throw new Error(
        'Could not find lemon project. Set LEMON_PATH env var or pass lemonPath option.'
      );
    }

    // Build command arguments
    const args = ['run', 'scripts/debug_agent_rpc.exs', '--'];

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

    // Create promise for ready message
    this.readyPromise = new Promise((resolve, reject) => {
      this.readyResolve = resolve;
      this.readyReject = reject;
    });

    // Spawn the mix process
    this.process = spawn('mix', args, {
      cwd: lemonPath,
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

  /**
   * Sends a command to the agent.
   */
  send(command: ClientCommand): void {
    if (!this.process?.stdin?.writable) {
      throw new Error('Agent not connected');
    }

    const json = JSON.stringify(command);
    this.process.stdin.write(json + '\n');
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
 * Attempts to find the lemon project root by looking in common locations.
 */
function findLemonPath(): string | null {
  // Try relative to this package
  const cwd = process.cwd();

  // Check if we're already in lemon
  if (cwd.includes('lemon')) {
    // Walk up to find the root (contains mix.exs and apps/)
    let current = cwd;
    while (current !== '/') {
      try {
        if (
          fs.existsSync(`${current}/mix.exs`) &&
          fs.existsSync(`${current}/apps`)
        ) {
          return current;
        }
      } catch {
        // Ignore
      }
      current = path.dirname(current);
    }
  }

  // Common development locations
  const commonPaths = [
    '/home/z80/dev/lemon',
    `${process.env.HOME}/dev/lemon`,
    `${process.env.HOME}/projects/lemon`,
  ];

  for (const p of commonPaths) {
    try {
      if (fs.existsSync(`${p}/mix.exs`)) {
        return p;
      }
    } catch {
      // Ignore
    }
  }

  return null;
}
