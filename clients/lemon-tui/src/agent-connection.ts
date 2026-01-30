/**
 * Agent connection - handles spawning the debug agent RPC and JSON line communication.
 */

import { spawn, type ChildProcess } from 'node:child_process';
import { createInterface, type Interface as ReadlineInterface } from 'node:readline';
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import path from 'node:path';
import type { ServerMessage, ClientCommand, ReadyMessage } from './types.js';

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

  constructor(private options: AgentConnectionOptions = {}) {
    super();
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
  prompt(text: string): void {
    this.send({ type: 'prompt', text });
  }

  /**
   * Sends an abort command to stop the current operation.
   */
  abort(): void {
    this.send({ type: 'abort' });
  }

  /**
   * Sends a reset command to clear the session.
   */
  reset(): void {
    this.send({ type: 'reset' });
  }

  /**
   * Sends a save command to persist the session.
   */
  save(): void {
    this.send({ type: 'save' });
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
  stats(): void {
    this.send({ type: 'stats' });
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
      this.emit('error', new Error(`Failed to parse JSON: ${line}`));
      return;
    }

    // Handle ready message specially
    if (message.type === 'ready') {
      if (this.readyResolve) {
        this.readyResolve(message);
        this.readyResolve = null;
        this.readyReject = null;
      }
      this.emit('ready', message);
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
