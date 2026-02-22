/**
 * Tests for the AgentConnection module.
 *
 * This module handles spawning the debug agent RPC process and JSON line communication.
 */

import { describe, it, expect, beforeEach, afterEach, vi, type Mock } from 'vitest';
import { EventEmitter } from 'node:events';
import type { ChildProcess } from 'node:child_process';
import type { Interface as ReadlineInterface } from 'node:readline';
import type { Readable, Writable } from 'node:stream';
import type {
  ReadyMessage,
  ServerMessage,
  SessionStartedMessage,
  SessionClosedMessage,
  ActiveSessionMessage,
} from './types.js';

const { MockWebSocket, mockWebSocketInstances } = vi.hoisted(() => {
  class MockWebSocket {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;
    static instances: MockWebSocket[] = [];

    readyState = MockWebSocket.CONNECTING;
    sentFrames: string[] = [];
    private listeners = new Map<string, Array<(...args: unknown[]) => void>>();

    constructor(public readonly url: string) {
      MockWebSocket.instances.push(this);
    }

    on(event: string, listener: (...args: unknown[]) => void): this {
      const list = this.listeners.get(event) || [];
      list.push(listener);
      this.listeners.set(event, list);
      return this;
    }

    emit(event: string, ...args: unknown[]): boolean {
      const list = this.listeners.get(event) || [];
      for (const listener of list) {
        listener(...args);
      }
      return list.length > 0;
    }

    removeAllListeners(): this {
      this.listeners.clear();
      return this;
    }

    send(data: string): void {
      this.sentFrames.push(String(data));
    }

    close(): void {
      this.readyState = MockWebSocket.CLOSED;
    }

    terminate(): void {
      this.readyState = MockWebSocket.CLOSED;
    }
  }

  return {
    MockWebSocket,
    mockWebSocketInstances: MockWebSocket.instances,
  };
});

// Mock child_process module
vi.mock('node:child_process', () => ({
  spawn: vi.fn(),
}));

// Mock readline module
vi.mock('node:readline', () => ({
  createInterface: vi.fn(),
}));

// Mock fs module
vi.mock('node:fs', () => ({
  default: {
    existsSync: vi.fn(),
  },
}));

vi.mock('ws', () => ({
  default: MockWebSocket,
}));

// Import after mocks are set up
import { AgentConnection, type AgentConnectionOptions } from './agent-connection.js';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import fs from 'node:fs';

/**
 * Creates a mock child process for testing.
 */
function createMockProcess(): {
  process: ChildProcess;
  stdin: Writable & { write: Mock };
  stdout: Readable;
  stderr: Readable;
  emitter: EventEmitter;
} {
  const emitter = new EventEmitter();
  const stdin = {
    writable: true,
    write: vi.fn().mockReturnValue(true),
  } as unknown as Writable & { write: Mock };

  const stdout = new EventEmitter() as Readable;
  const stderr = new EventEmitter() as Readable;

  const mockProcess = Object.assign(emitter, {
    stdin,
    stdout,
    stderr,
    killed: false,
    kill: vi.fn(),
    pid: 12345,
  }) as unknown as ChildProcess;

  return { process: mockProcess, stdin, stdout, stderr, emitter };
}

/**
 * Creates a mock readline interface.
 */
function createMockReadline(): {
  readline: ReadlineInterface;
  emitter: EventEmitter;
} {
  const emitter = new EventEmitter();
  const readline = emitter as unknown as ReadlineInterface;
  return { readline, emitter };
}

function getLastWebSocket(): MockWebSocket {
  const ws = mockWebSocketInstances[mockWebSocketInstances.length - 1];
  if (!ws) {
    throw new Error('No WebSocket instance created');
  }
  return ws;
}

function openWebSocket(ws: MockWebSocket): void {
  ws.readyState = MockWebSocket.OPEN;
  ws.emit('open');
}

function emitWebSocketMessage(ws: MockWebSocket, frame: unknown): void {
  const payload = typeof frame === 'string' ? frame : JSON.stringify(frame);
  ws.emit('message', payload);
}

function readFrameAt(ws: MockWebSocket, index: number): Record<string, unknown> {
  return JSON.parse(ws.sentFrames[index] || '{}') as Record<string, unknown>;
}

function readLastFrame(ws: MockWebSocket): Record<string, unknown> {
  return readFrameAt(ws, ws.sentFrames.length - 1);
}

async function startWebSocketConnection(connection: AgentConnection): Promise<MockWebSocket> {
  const startPromise = connection.start();
  const ws = getLastWebSocket();
  openWebSocket(ws);
  emitWebSocketMessage(ws, {
    type: 'hello-ok',
    protocol: 1,
    server: {},
    features: {},
    snapshot: {},
    policy: {},
  });
  await startPromise;
  return ws;
}

describe('AgentConnection', () => {
  let connection: AgentConnection;
  let mockProcess: ReturnType<typeof createMockProcess>;
  let mockReadline: ReturnType<typeof createMockReadline>;

  beforeEach(() => {
    vi.clearAllMocks();
    mockWebSocketInstances.length = 0;

    mockProcess = createMockProcess();
    mockReadline = createMockReadline();

    (spawn as Mock).mockReturnValue(mockProcess.process);
    (createInterface as Mock).mockReturnValue(mockReadline.readline);
    (fs.existsSync as Mock).mockReturnValue(true);

    connection = new AgentConnection({ lemonPath: '/test/lemon' });
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  describe('constructor', () => {
    it('should create an instance with default options', () => {
      const conn = new AgentConnection();
      expect(conn).toBeInstanceOf(AgentConnection);
      expect(conn).toBeInstanceOf(EventEmitter);
    });

    it('should create an instance with custom options', () => {
      const options: AgentConnectionOptions = {
        cwd: '/test/cwd',
        model: 'anthropic:claude-3',
        baseUrl: 'https://api.example.com',
        systemPrompt: 'Custom prompt',
        debug: true,
        ui: false,
        sessionFile: '/test/session.json',
        lemonPath: '/test/lemon',
      };
      const conn = new AgentConnection(options);
      expect(conn).toBeInstanceOf(AgentConnection);
    });
  });

  describe('start()', () => {
    it('should spawn the mix process with correct arguments', async () => {
      const startPromise = connection.start();

      // Simulate ready message
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));

      await startPromise;

      expect(spawn).toHaveBeenCalledWith(
        'mix',
        ['run', 'scripts/debug_agent_rpc.exs', '--'],
        expect.objectContaining({
          cwd: '/test/lemon',
          stdio: ['pipe', 'pipe', 'pipe'],
        })
      );
    });

    it('should allow overriding command and script path', async () => {
      const conn = new AgentConnection({
        lemonPath: '/test/lemon',
        agentCommand: 'custom-mix',
        agentScriptPath: 'scripts/custom_rpc.exs',
      });

      const startPromise = conn.start();
      mockReadline.emitter.emit('line', JSON.stringify({
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      } satisfies ReadyMessage));

      await startPromise;

      expect(spawn).toHaveBeenCalledWith(
        'custom-mix',
        ['run', 'scripts/custom_rpc.exs', '--'],
        expect.objectContaining({ cwd: '/test/lemon' })
      );
    });

    it('should allow overriding command args', async () => {
      const conn = new AgentConnection({
        lemonPath: '/test/lemon',
        agentCommand: 'elixir',
        agentCommandArgs: ['scripts/debug_agent_rpc.exs'],
      });

      const startPromise = conn.start();
      mockReadline.emitter.emit('line', JSON.stringify({
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      } satisfies ReadyMessage));

      await startPromise;

      expect(spawn).toHaveBeenCalledWith(
        'elixir',
        ['scripts/debug_agent_rpc.exs'],
        expect.objectContaining({ cwd: '/test/lemon' })
      );
    });

    it('should include cwd argument when specified', async () => {
      const conn = new AgentConnection({
        lemonPath: '/test/lemon',
        cwd: '/project/dir',
      });

      const startPromise = conn.start();

      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/project/dir',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));

      await startPromise;

      expect(spawn).toHaveBeenCalledWith(
        'mix',
        expect.arrayContaining(['--cwd', '/project/dir']),
        expect.any(Object)
      );
    });

    it('should include model argument when specified', async () => {
      const conn = new AgentConnection({
        lemonPath: '/test/lemon',
        model: 'openai:gpt-4',
      });

      const startPromise = conn.start();

      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'openai', id: 'gpt-4' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));

      await startPromise;

      expect(spawn).toHaveBeenCalledWith(
        'mix',
        expect.arrayContaining(['--model', 'openai:gpt-4']),
        expect.any(Object)
      );
    });

    it('should include base_url argument when specified', async () => {
      const conn = new AgentConnection({
        lemonPath: '/test/lemon',
        baseUrl: 'https://custom.api.com',
      });

      const startPromise = conn.start();

      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));

      await startPromise;

      expect(spawn).toHaveBeenCalledWith(
        'mix',
        expect.arrayContaining(['--base_url', 'https://custom.api.com']),
        expect.any(Object)
      );
    });

    it('should include system_prompt argument when specified', async () => {
      const conn = new AgentConnection({
        lemonPath: '/test/lemon',
        systemPrompt: 'You are a helpful assistant',
      });

      const startPromise = conn.start();

      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));

      await startPromise;

      expect(spawn).toHaveBeenCalledWith(
        'mix',
        expect.arrayContaining(['--system_prompt', 'You are a helpful assistant']),
        expect.any(Object)
      );
    });

    it('should include session-file argument when specified', async () => {
      const conn = new AgentConnection({
        lemonPath: '/test/lemon',
        sessionFile: '/path/to/session.json',
      });

      const startPromise = conn.start();

      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));

      await startPromise;

      expect(spawn).toHaveBeenCalledWith(
        'mix',
        expect.arrayContaining(['--session-file', '/path/to/session.json']),
        expect.any(Object)
      );
    });

    it('should include debug flag when enabled', async () => {
      const conn = new AgentConnection({
        lemonPath: '/test/lemon',
        debug: true,
      });

      const startPromise = conn.start();

      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: true,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));

      await startPromise;

      expect(spawn).toHaveBeenCalledWith(
        'mix',
        expect.arrayContaining(['--debug']),
        expect.any(Object)
      );
    });

    it('should include --no-ui flag when ui is disabled', async () => {
      const conn = new AgentConnection({
        lemonPath: '/test/lemon',
        ui: false,
      });

      const startPromise = conn.start();

      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: false,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));

      await startPromise;

      expect(spawn).toHaveBeenCalledWith(
        'mix',
        expect.arrayContaining(['--no-ui']),
        expect.any(Object)
      );
    });

    it('should throw error if agent already started', async () => {
      const startPromise = connection.start();

      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));

      await startPromise;

      await expect(connection.start()).rejects.toThrow('Agent already started');
    });

    it('should throw error if lemon path not found', async () => {
      (fs.existsSync as Mock).mockReturnValue(false);

      const conn = new AgentConnection();
      // Clear LEMON_PATH env var for this test
      const originalEnv = process.env.LEMON_PATH;
      delete process.env.LEMON_PATH;

      // Mock process.cwd to return something that doesn't contain 'lemon'
      const originalCwd = process.cwd;
      vi.spyOn(process, 'cwd').mockReturnValue('/some/other/path');

      await expect(conn.start()).rejects.toThrow(
        'Could not find lemon project'
      );

      process.env.LEMON_PATH = originalEnv;
      vi.spyOn(process, 'cwd').mockRestore();
    });

    it('should return ready message on successful start', async () => {
      const startPromise = connection.start();

      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));

      const result = await startPromise;

      expect(result).toEqual(readyMsg);
    });

    it('should set ready state after start', async () => {
      expect(connection.isReady()).toBe(false);

      const startPromise = connection.start();

      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));

      await startPromise;

      expect(connection.isReady()).toBe(true);
    });

    it('should emit ready event on start', async () => {
      const readyHandler = vi.fn();
      connection.on('ready', readyHandler);

      const startPromise = connection.start();

      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));

      await startPromise;

      expect(readyHandler).toHaveBeenCalledWith(readyMsg);
    });

    it('should store primary session ID from ready message', async () => {
      const startPromise = connection.start();

      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'primary-session-123',
        active_session_id: 'primary-session-123',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));

      await startPromise;

      expect(connection.getPrimarySessionId()).toBe('primary-session-123');
    });

    it('should store active session ID from ready message', async () => {
      const startPromise = connection.start();

      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'primary-session-123',
        active_session_id: 'active-session-456',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));

      await startPromise;

      expect(connection.getActiveSessionId()).toBe('active-session-456');
    });

    it('should reject start promise on process error', async () => {
      const conn = new AgentConnection({ lemonPath: '/test/lemon' });
      const errorHandler = vi.fn();
      conn.on('error', errorHandler);

      const startPromise = conn.start();

      // Emit error immediately
      const error = new Error('Spawn failed');
      mockProcess.emitter.emit('error', error);

      await expect(startPromise).rejects.toThrow('Spawn failed');
      expect(errorHandler).toHaveBeenCalledWith(error);
    });
  });

  describe('send()', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should write JSON line to stdin', () => {
      connection.send({ type: 'ping' });

      expect(mockProcess.stdin.write).toHaveBeenCalledWith('{"type":"ping"}\n');
    });

    it('should serialize complex commands correctly', () => {
      connection.send({
        type: 'prompt',
        text: 'Hello world',
        session_id: 'session-1',
      });

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        '{"type":"prompt","text":"Hello world","session_id":"session-1"}\n'
      );
    });

    it('should throw error if not connected', () => {
      const conn = new AgentConnection({ lemonPath: '/test/lemon' });

      expect(() => conn.send({ type: 'ping' })).toThrow('Agent not connected');
    });

    it('should throw error if stdin is not writable', async () => {
      // Make stdin not writable
      (mockProcess.stdin as any).writable = false;

      expect(() => connection.send({ type: 'ping' })).toThrow(
        'Agent not connected'
      );
    });
  });

  describe('prompt()', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should send prompt command', () => {
      connection.prompt('Hello, Claude!');

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        expect.stringContaining('"type":"prompt"')
      );
      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        expect.stringContaining('"text":"Hello, Claude!"')
      );
    });

    it('should include session_id when specified', () => {
      connection.prompt('Hello', 'custom-session');

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        expect.stringContaining('"session_id":"custom-session"')
      );
    });

    it('should handle empty text', () => {
      connection.prompt('');

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        expect.stringContaining('"text":""')
      );
    });

    it('should handle special characters in text', () => {
      connection.prompt('Hello\n"world"\twith\\special');

      expect(mockProcess.stdin.write).toHaveBeenCalled();
      const callArg = mockProcess.stdin.write.mock.calls[0][0] as string;
      expect(() => JSON.parse(callArg)).not.toThrow();
    });
  });

  describe('abort()', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should send abort command', () => {
      connection.abort();

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        expect.stringContaining('"type":"abort"')
      );
    });

    it('should include session_id when specified', () => {
      connection.abort('session-123');

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        expect.stringContaining('"session_id":"session-123"')
      );
    });
  });

  describe('reset()', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should send reset command', () => {
      connection.reset();

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        expect.stringContaining('"type":"reset"')
      );
    });

    it('should include session_id when specified', () => {
      connection.reset('session-456');

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        expect.stringContaining('"session_id":"session-456"')
      );
    });
  });

  describe('save()', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should send save command', () => {
      connection.save();

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        expect.stringContaining('"type":"save"')
      );
    });

    it('should include session_id when specified', () => {
      connection.save('session-789');

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        expect.stringContaining('"session_id":"session-789"')
      );
    });
  });

  describe('listSessions()', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should send list_sessions command', () => {
      connection.listSessions();

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        '{"type":"list_sessions"}\n'
      );
    });
  });

  describe('stats()', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should send stats command', () => {
      connection.stats();

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        expect.stringContaining('"type":"stats"')
      );
    });

    it('should include session_id when specified', () => {
      connection.stats('session-stats');

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        expect.stringContaining('"session_id":"session-stats"')
      );
    });
  });

  describe('ping()', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should send ping command', () => {
      connection.ping();

      expect(mockProcess.stdin.write).toHaveBeenCalledWith('{"type":"ping"}\n');
    });
  });

  describe('respondToUIRequest()', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should send ui_response with result', () => {
      connection.respondToUIRequest('req-1', { selected: 'option-a' });

      const callArg = mockProcess.stdin.write.mock.calls[0][0] as string;
      const parsed = JSON.parse(callArg);

      expect(parsed.type).toBe('ui_response');
      expect(parsed.id).toBe('req-1');
      expect(parsed.result).toEqual({ selected: 'option-a' });
      expect(parsed.error).toBeNull();
    });

    it('should send ui_response with error', () => {
      connection.respondToUIRequest('req-2', null, 'User cancelled');

      const callArg = mockProcess.stdin.write.mock.calls[0][0] as string;
      const parsed = JSON.parse(callArg);

      expect(parsed.type).toBe('ui_response');
      expect(parsed.id).toBe('req-2');
      expect(parsed.result).toBeNull();
      expect(parsed.error).toBe('User cancelled');
    });

    it('should handle complex result objects', () => {
      const complexResult = {
        selection: ['a', 'b', 'c'],
        metadata: { count: 3 },
      };
      connection.respondToUIRequest('req-3', complexResult);

      const callArg = mockProcess.stdin.write.mock.calls[0][0] as string;
      const parsed = JSON.parse(callArg);

      expect(parsed.result).toEqual(complexResult);
    });
  });

  describe('startSession()', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should send start_session command without options', () => {
      connection.startSession();

      const callArg = mockProcess.stdin.write.mock.calls[0][0] as string;
      const parsed = JSON.parse(callArg);

      expect(parsed.type).toBe('start_session');
    });

    it('should include all options when specified', () => {
      connection.startSession({
        cwd: '/new/cwd',
        model: 'openai:gpt-4',
        systemPrompt: 'Custom prompt',
        sessionFile: '/path/to/session.json',
        parentSession: 'parent-id',
      });

      const callArg = mockProcess.stdin.write.mock.calls[0][0] as string;
      const parsed = JSON.parse(callArg);

      expect(parsed.type).toBe('start_session');
      expect(parsed.cwd).toBe('/new/cwd');
      expect(parsed.model).toBe('openai:gpt-4');
      expect(parsed.system_prompt).toBe('Custom prompt');
      expect(parsed.session_file).toBe('/path/to/session.json');
      expect(parsed.parent_session).toBe('parent-id');
    });

    it('should handle partial options', () => {
      connection.startSession({
        cwd: '/only/cwd',
      });

      const callArg = mockProcess.stdin.write.mock.calls[0][0] as string;
      const parsed = JSON.parse(callArg);

      expect(parsed.cwd).toBe('/only/cwd');
      expect(parsed.model).toBeUndefined();
    });
  });

  describe('closeSession()', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should send close_session command with session_id', () => {
      connection.closeSession('session-to-close');

      const callArg = mockProcess.stdin.write.mock.calls[0][0] as string;
      const parsed = JSON.parse(callArg);

      expect(parsed.type).toBe('close_session');
      expect(parsed.session_id).toBe('session-to-close');
    });
  });

  describe('listRunningSessions()', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should send list_running_sessions command', () => {
      connection.listRunningSessions();

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        '{"type":"list_running_sessions"}\n'
      );
    });
  });

  describe('listModels()', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should send list_models command', () => {
      connection.listModels();

      expect(mockProcess.stdin.write).toHaveBeenCalledWith(
        '{"type":"list_models"}\n'
      );
    });
  });

  describe('setActiveSession()', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should send set_active_session command', () => {
      connection.setActiveSession('new-active-session');

      const callArg = mockProcess.stdin.write.mock.calls[0][0] as string;
      const parsed = JSON.parse(callArg);

      expect(parsed.type).toBe('set_active_session');
      expect(parsed.session_id).toBe('new-active-session');
    });
  });

  describe('getPrimarySessionId()', () => {
    it('should return null before start', () => {
      expect(connection.getPrimarySessionId()).toBeNull();
    });

    it('should return session ID after start', async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'my-primary-session',
        active_session_id: 'my-primary-session',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;

      expect(connection.getPrimarySessionId()).toBe('my-primary-session');
    });
  });

  describe('getActiveSessionId()', () => {
    it('should return null before start', () => {
      expect(connection.getActiveSessionId()).toBeNull();
    });

    it('should return session ID after start', async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'active-session-id',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;

      expect(connection.getActiveSessionId()).toBe('active-session-id');
    });

    it('should update on active_session message', async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;

      expect(connection.getActiveSessionId()).toBe('session-1');

      // Simulate active_session message
      const activeSessionMsg: ActiveSessionMessage = {
        type: 'active_session',
        session_id: 'new-active-session',
      };
      mockReadline.emitter.emit('line', JSON.stringify(activeSessionMsg));

      expect(connection.getActiveSessionId()).toBe('new-active-session');
    });
  });

  describe('stop()', () => {
    it('should do nothing if not started', () => {
      connection.stop();
      // Should not throw
    });

    it('should send quit command', async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;

      connection.stop();

      expect(mockProcess.stdin.write).toHaveBeenCalledWith('{"type":"quit"}\n');
    });

    it('should kill process after timeout', async () => {
      vi.useFakeTimers();

      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;

      connection.stop();

      expect(mockProcess.process.kill).not.toHaveBeenCalled();

      vi.advanceTimersByTime(1000);

      expect(mockProcess.process.kill).toHaveBeenCalledWith('SIGTERM');

      vi.useRealTimers();
    });

    it('should not kill already killed process', async () => {
      vi.useFakeTimers();

      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;

      // Mark as already killed
      (mockProcess.process as any).killed = true;

      connection.stop();
      vi.advanceTimersByTime(1000);

      expect(mockProcess.process.kill).not.toHaveBeenCalled();

      vi.useRealTimers();
    });
  });

  describe('isReady()', () => {
    it('should return false initially', () => {
      expect(connection.isReady()).toBe(false);
    });

    it('should return true after start', async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;

      expect(connection.isReady()).toBe(true);
    });

    it('should return false after process closes', async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;

      expect(connection.isReady()).toBe(true);

      mockProcess.emitter.emit('close', 0);

      expect(connection.isReady()).toBe(false);
    });
  });

  describe('handleLine() - message parsing', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should emit message events for valid JSON', () => {
      const messageHandler = vi.fn();
      connection.on('message', messageHandler);

      const msg = { type: 'pong' };
      mockReadline.emitter.emit('line', JSON.stringify(msg));

      expect(messageHandler).toHaveBeenCalledWith(msg);
    });

    it('should ignore empty lines', () => {
      const messageHandler = vi.fn();
      connection.on('message', messageHandler);

      // Clear previous calls from beforeEach (ready message was already emitted)
      messageHandler.mockClear();

      mockReadline.emitter.emit('line', '');
      mockReadline.emitter.emit('line', '   ');
      mockReadline.emitter.emit('line', '\t');

      // No new messages should have been emitted
      expect(messageHandler).toHaveBeenCalledTimes(0);
    });

    it('should ignore non-JSON lines in non-debug mode', () => {
      const messageHandler = vi.fn();
      connection.on('message', messageHandler);

      // Clear previous calls from beforeEach (ready message was already emitted)
      messageHandler.mockClear();

      mockReadline.emitter.emit('line', 'Compiling 1 file...');
      mockReadline.emitter.emit('line', 'warning: some warning');

      // No new messages should have been emitted
      expect(messageHandler).toHaveBeenCalledTimes(0);
    });

    it('should handle session_started message', () => {
      const messageHandler = vi.fn();
      connection.on('message', messageHandler);

      const msg: SessionStartedMessage = {
        type: 'session_started',
        session_id: 'new-session',
        cwd: '/new/cwd',
        model: { provider: 'openai', id: 'gpt-4' },
      };
      mockReadline.emitter.emit('line', JSON.stringify(msg));

      expect(messageHandler).toHaveBeenCalledWith(msg);
    });

    it('should handle session_closed message and clear active session if matching', async () => {
      // Set up with active session
      expect(connection.getActiveSessionId()).toBe('session-1');

      const msg: SessionClosedMessage = {
        type: 'session_closed',
        session_id: 'session-1',
        reason: 'normal',
      };
      mockReadline.emitter.emit('line', JSON.stringify(msg));

      expect(connection.getActiveSessionId()).toBeNull();
    });

    it('should not clear active session if different session closes', async () => {
      expect(connection.getActiveSessionId()).toBe('session-1');

      const msg: SessionClosedMessage = {
        type: 'session_closed',
        session_id: 'other-session',
        reason: 'normal',
      };
      mockReadline.emitter.emit('line', JSON.stringify(msg));

      expect(connection.getActiveSessionId()).toBe('session-1');
    });

    it('should handle active_session message and update tracking', () => {
      expect(connection.getActiveSessionId()).toBe('session-1');

      const msg: ActiveSessionMessage = {
        type: 'active_session',
        session_id: 'switched-session',
      };
      mockReadline.emitter.emit('line', JSON.stringify(msg));

      expect(connection.getActiveSessionId()).toBe('switched-session');
    });

    it('should handle active_session with null session_id', () => {
      const msg: ActiveSessionMessage = {
        type: 'active_session',
        session_id: null,
      };
      mockReadline.emitter.emit('line', JSON.stringify(msg));

      expect(connection.getActiveSessionId()).toBeNull();
    });
  });

  describe('event emission', () => {
    beforeEach(async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;
    });

    it('should emit error event on process error', () => {
      const errorHandler = vi.fn();
      connection.on('error', errorHandler);

      const error = new Error('Process crashed');
      mockProcess.emitter.emit('error', error);

      expect(errorHandler).toHaveBeenCalledWith(error);
    });

    it('should emit close event on process close', () => {
      const closeHandler = vi.fn();
      connection.on('close', closeHandler);

      mockProcess.emitter.emit('close', 0);

      expect(closeHandler).toHaveBeenCalledWith(0);
    });

    it('should emit close event with null on abnormal exit', () => {
      const closeHandler = vi.fn();
      connection.on('close', closeHandler);

      mockProcess.emitter.emit('close', null);

      expect(closeHandler).toHaveBeenCalledWith(null);
    });

    it('should emit message event for all message types', () => {
      const messageHandler = vi.fn();
      connection.on('message', messageHandler);

      // Clear previous calls from beforeEach (ready message was already emitted)
      messageHandler.mockClear();

      const messages: ServerMessage[] = [
        { type: 'pong' },
        { type: 'error', message: 'Something went wrong' },
        { type: 'debug', message: 'Debug info' },
        { type: 'save_result', ok: true, path: '/saved/path' },
        { type: 'sessions_list', sessions: [] },
      ];

      for (const msg of messages) {
        mockReadline.emitter.emit('line', JSON.stringify(msg));
      }

      expect(messageHandler).toHaveBeenCalledTimes(messages.length);
    });
  });

  describe('error handling', () => {
    it('should reject start on spawn error before ready', async () => {
      const conn = new AgentConnection({ lemonPath: '/test/lemon' });
      const errorHandler = vi.fn();
      conn.on('error', errorHandler);

      const startPromise = conn.start();

      const error = new Error('ENOENT: command not found');
      mockProcess.emitter.emit('error', error);

      await expect(startPromise).rejects.toThrow('ENOENT: command not found');
      expect(errorHandler).toHaveBeenCalledWith(error);
    });

    it('should emit error but not reject if error after ready', async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;

      const errorHandler = vi.fn();
      connection.on('error', errorHandler);

      const error = new Error('Runtime error');
      mockProcess.emitter.emit('error', error);

      expect(errorHandler).toHaveBeenCalledWith(error);
    });

    it('should handle send errors gracefully in stop', async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;

      // Make stdin throw
      mockProcess.stdin.write.mockImplementation(() => {
        throw new Error('Write failed');
      });

      // stop() should not throw
      expect(() => connection.stop()).not.toThrow();
    });
  });

  describe('debug mode', () => {
    it('should write stderr to process.stderr in debug mode', async () => {
      const debugConn = new AgentConnection({
        lemonPath: '/test/lemon',
        debug: true,
      });

      const stderrWriteSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);

      const startPromise = debugConn.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: true,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;

      // Simulate stderr data
      mockProcess.stderr.emit('data', Buffer.from('Debug output'));

      expect(stderrWriteSpy).toHaveBeenCalled();

      stderrWriteSpy.mockRestore();
    });

    it('should not write stderr in non-debug mode', async () => {
      const stderrWriteSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);

      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;

      // Simulate stderr data
      mockProcess.stderr.emit('data', Buffer.from('Debug output'));

      expect(stderrWriteSpy).not.toHaveBeenCalled();

      stderrWriteSpy.mockRestore();
    });
  });

  describe('restart exit code', () => {
    it('returns configured restart exit code', () => {
      const conn = new AgentConnection({
        lemonPath: '/test/lemon',
        agentRestartExitCode: 99,
      });
      expect(conn.getRestartExitCode()).toBe(99);
    });

    it('falls back to env restart exit code', () => {
      const previous = process.env.LEMON_AGENT_RESTART_EXIT_CODE;
      process.env.LEMON_AGENT_RESTART_EXIT_CODE = '88';
      const conn = new AgentConnection({ lemonPath: '/test/lemon' });
      expect(conn.getRestartExitCode()).toBe(88);
      if (previous === undefined) {
        delete process.env.LEMON_AGENT_RESTART_EXIT_CODE;
      } else {
        process.env.LEMON_AGENT_RESTART_EXIT_CODE = previous;
      }
    });
  });

  describe('websocket mode', () => {
    it('starts over websocket and sends connect frame', async () => {
      const conn = new AgentConnection({
        wsUrl: 'ws://control-plane.test/ws',
        wsToken: 'token-123',
        wsSessionKey: 'agent:custom:main',
      });
      const startPromise = conn.start();

      const ws = getLastWebSocket();
      openWebSocket(ws);

      const connectFrame = readFrameAt(ws, 0);
      expect(connectFrame.type).toBe('req');
      expect(connectFrame.method).toBe('connect');
      expect(connectFrame.params).toEqual(expect.objectContaining({
        role: 'operator',
        client: { id: 'lemon-tui' },
        auth: { token: 'token-123' },
      }));

      emitWebSocketMessage(ws, {
        type: 'hello-ok',
        protocol: 1,
        server: {},
        features: {},
        snapshot: {},
        policy: {},
      });

      const ready = await startPromise;
      expect(ready.primary_session_id).toBe('agent:custom:main');
      expect(conn.getPrimarySessionId()).toBe('agent:custom:main');
      expect(conn.isReady()).toBe(true);
    });

    it('maps sessions.list responses into sessions_list message', async () => {
      const conn = new AgentConnection({
        wsUrl: 'ws://control-plane.test/ws',
        wsSessionKey: 'agent:test:main',
      });
      const ws = await startWebSocketConnection(conn);
      const messageHandler = vi.fn();
      conn.on('message', messageHandler);

      conn.listSessions();
      const reqFrame = readLastFrame(ws);
      expect(reqFrame.method).toBe('sessions.list');

      emitWebSocketMessage(ws, {
        type: 'res',
        id: reqFrame.id,
        ok: true,
        payload: {
          sessions: [
            {
              sessionKey: 'agent:test:main',
              updatedAtMs: 1234,
              cwd: '/repo',
              model: 'openai:gpt-4o',
            },
          ],
        },
      });

      expect(messageHandler).toHaveBeenCalledWith({
        type: 'sessions_list',
        sessions: [
          {
            path: 'agent:test:main',
            id: 'agent:test:main',
            timestamp: 1234,
            cwd: '/repo',
            model: { provider: 'openai', id: 'gpt-4o' },
          },
        ],
      });
    });

    it('maps sessions.active.list responses into running_sessions message', async () => {
      const conn = new AgentConnection({
        wsUrl: 'ws://control-plane.test/ws',
        wsSessionKey: 'agent:test:main',
      });
      const ws = await startWebSocketConnection(conn);
      const messageHandler = vi.fn();
      conn.on('message', messageHandler);

      conn.listRunningSessions();
      const reqFrame = readLastFrame(ws);
      expect(reqFrame.method).toBe('sessions.active.list');

      emitWebSocketMessage(ws, {
        type: 'res',
        id: reqFrame.id,
        ok: true,
        payload: {
          sessions: [
            {
              sessionKey: 'agent:test:main',
              updatedAtMs: 4321,
              cwd: '/repo',
              model: 'openai:gpt-4o',
              active: true,
              runId: 'run-1',
            },
          ],
        },
      });

      expect(messageHandler).toHaveBeenCalledWith({
        type: 'running_sessions',
        sessions: [
          {
            session_id: 'agent:test:main',
            cwd: '/repo',
            is_streaming: true,
            model: { provider: 'openai', id: 'gpt-4o' },
          },
        ],
        error: null,
      });
    });

    it('maps models.list responses into models_list message', async () => {
      const conn = new AgentConnection({
        wsUrl: 'ws://control-plane.test/ws',
      });
      const ws = await startWebSocketConnection(conn);
      const messageHandler = vi.fn();
      conn.on('message', messageHandler);

      conn.listModels();
      const reqFrame = readLastFrame(ws);

      emitWebSocketMessage(ws, {
        type: 'res',
        id: reqFrame.id,
        ok: true,
        payload: {
          models: [
            { provider: 'openai', id: 'gpt-4o', name: 'GPT-4o' },
            { provider: 'openai', id: 'gpt-4o-mini' },
            { provider: 'anthropic', id: 'claude-sonnet-4' },
          ],
        },
      });

      expect(messageHandler).toHaveBeenCalledWith({
        type: 'models_list',
        providers: [
          {
            id: 'openai',
            models: [
              { id: 'gpt-4o', name: 'GPT-4o' },
              { id: 'gpt-4o-mini', name: undefined },
            ],
          },
          {
            id: 'anthropic',
            models: [{ id: 'claude-sonnet-4', name: undefined }],
          },
        ],
        error: null,
      });
    });

    it('creates session through control-plane roundtrip before emitting session_started', async () => {
      const conn = new AgentConnection({
        wsUrl: 'ws://control-plane.test/ws',
        wsSessionKey: 'agent:test:main',
      });
      const ws = await startWebSocketConnection(conn);
      const messageHandler = vi.fn();
      conn.on('message', messageHandler);

      conn.startSession({ cwd: '/tmp/project', model: 'openai:gpt-4o' });
      const reqFrame = readLastFrame(ws);
      expect(reqFrame.method).toBe('sessions.active');
      expect((reqFrame.params as Record<string, unknown>).sessionKey).toBeTypeOf('string');

      emitWebSocketMessage(ws, {
        type: 'res',
        id: reqFrame.id,
        ok: true,
        payload: {
          sessionKey: (reqFrame.params as Record<string, unknown>).sessionKey,
        },
      });

      expect(messageHandler).toHaveBeenCalledWith(expect.objectContaining({
        type: 'session_started',
        session_id: (reqFrame.params as Record<string, unknown>).sessionKey,
        cwd: '/tmp/project',
      }));
      expect(messageHandler).toHaveBeenCalledWith({
        type: 'active_session',
        session_id: (reqFrame.params as Record<string, unknown>).sessionKey,
      });
      expect(conn.getActiveSessionId()).toBe((reqFrame.params as Record<string, unknown>).sessionKey);
    });

    it('sets active session only after control-plane ack', async () => {
      const conn = new AgentConnection({
        wsUrl: 'ws://control-plane.test/ws',
        wsSessionKey: 'agent:test:main',
      });
      const ws = await startWebSocketConnection(conn);
      const messageHandler = vi.fn();
      conn.on('message', messageHandler);

      conn.setActiveSession('agent:test:other');
      const reqFrame = readLastFrame(ws);
      expect(reqFrame.method).toBe('sessions.active');
      expect(conn.getActiveSessionId()).toBe('agent:test:main');

      emitWebSocketMessage(ws, {
        type: 'res',
        id: reqFrame.id,
        ok: true,
        payload: {
          sessionKey: 'agent:test:other',
          runId: null,
        },
      });

      expect(messageHandler).toHaveBeenCalledWith({
        type: 'active_session',
        session_id: 'agent:test:other',
      });
      expect(conn.getActiveSessionId()).toBe('agent:test:other');
    });

    it('queues commands while disconnected and flushes after reconnect', async () => {
      vi.useFakeTimers();
      try {
        const conn = new AgentConnection({
          wsUrl: 'ws://control-plane.test/ws',
          wsSessionKey: 'agent:test:main',
        });

        const ws = await startWebSocketConnection(conn);
        ws.readyState = MockWebSocket.CLOSED;
        ws.emit('close', 1006);

        conn.prompt('resume work', 'agent:test:main');

        const reconnectWs = getLastWebSocket();
        openWebSocket(reconnectWs);
        emitWebSocketMessage(reconnectWs, {
          type: 'hello-ok',
          protocol: 1,
          server: {},
          features: {},
          snapshot: {},
          policy: {},
        });

        const queuedCommandFrame = readLastFrame(reconnectWs);
        expect(queuedCommandFrame.method).toBe('chat.send');
        expect(queuedCommandFrame.params).toEqual({
          sessionKey: 'agent:test:main',
          prompt: 'resume work',
          agentId: 'default',
        });
      } finally {
        vi.useRealTimers();
      }
    });

    it('maps chat delta and completion events to message stream updates', async () => {
      const conn = new AgentConnection({
        wsUrl: 'ws://control-plane.test/ws',
        wsSessionKey: 'agent:test:main',
      });
      const ws = await startWebSocketConnection(conn);
      const messageHandler = vi.fn();
      conn.on('message', messageHandler);

      emitWebSocketMessage(ws, {
        type: 'event',
        event: 'chat',
        payload: {
          type: 'delta',
          sessionKey: 'agent:test:main',
          runId: 'run-1',
          text: 'Hel',
        },
      });
      emitWebSocketMessage(ws, {
        type: 'event',
        event: 'chat',
        payload: {
          type: 'delta',
          sessionKey: 'agent:test:main',
          runId: 'run-1',
          text: 'lo',
        },
      });
      emitWebSocketMessage(ws, {
        type: 'event',
        event: 'agent',
        payload: {
          type: 'completed',
          sessionKey: 'agent:test:main',
          runId: 'run-1',
          answer: 'ignored because buffered text wins',
        },
      });

      expect(messageHandler).toHaveBeenCalledWith(expect.objectContaining({
        type: 'event',
        session_id: 'agent:test:main',
        event: expect.objectContaining({ type: 'agent_start' }),
      }));
      expect(messageHandler).toHaveBeenCalledWith(expect.objectContaining({
        type: 'event',
        session_id: 'agent:test:main',
        event: expect.objectContaining({
          type: 'message_start',
        }),
      }));
      expect(messageHandler).toHaveBeenCalledWith(expect.objectContaining({
        type: 'event',
        session_id: 'agent:test:main',
        event: expect.objectContaining({
          type: 'message_update',
        }),
      }));
      expect(messageHandler).toHaveBeenCalledWith(expect.objectContaining({
        type: 'event',
        session_id: 'agent:test:main',
        event: expect.objectContaining({
          type: 'message_end',
        }),
      }));
      expect(messageHandler).toHaveBeenCalledWith(expect.objectContaining({
        type: 'event',
        session_id: 'agent:test:main',
        event: expect.objectContaining({ type: 'agent_end' }),
      }));
    });

    it('uses last run id for abort requests after agent completion', async () => {
      const conn = new AgentConnection({
        wsUrl: 'ws://control-plane.test/ws',
        wsSessionKey: 'agent:test:main',
      });
      const ws = await startWebSocketConnection(conn);

      emitWebSocketMessage(ws, {
        type: 'event',
        event: 'agent',
        payload: {
          type: 'completed',
          sessionKey: 'agent:test:main',
          runId: 'run-42',
          answer: 'done',
        },
      });

      conn.abort('agent:test:main');
      const abortFrame = readLastFrame(ws);

      expect(abortFrame.method).toBe('chat.abort');
      expect(abortFrame.params).toEqual({
        sessionKey: 'agent:test:main',
        runId: 'run-42',
      });
    });

    it('maps non-ok responses into error messages', async () => {
      const conn = new AgentConnection({
        wsUrl: 'ws://control-plane.test/ws',
      });
      const ws = await startWebSocketConnection(conn);
      const messageHandler = vi.fn();
      conn.on('message', messageHandler);

      conn.ping();
      const reqFrame = readLastFrame(ws);

      emitWebSocketMessage(ws, {
        type: 'res',
        id: reqFrame.id,
        ok: false,
        error: { message: 'request failed' },
      });

      expect(messageHandler).toHaveBeenCalledWith({
        type: 'error',
        message: 'request failed',
        session_id: undefined,
      });
    });
  });

  describe('environment configuration', () => {
    it('should set MIX_ENV to dev', async () => {
      const startPromise = connection.start();
      const readyMsg: ReadyMessage = {
        type: 'ready',
        cwd: '/test',
        model: { provider: 'anthropic', id: 'claude-3' },
        debug: false,
        ui: true,
        primary_session_id: 'session-1',
        active_session_id: 'session-1',
      };
      mockReadline.emitter.emit('line', JSON.stringify(readyMsg));
      await startPromise;

      expect(spawn).toHaveBeenCalledWith(
        'mix',
        expect.any(Array),
        expect.objectContaining({
          env: expect.objectContaining({
            MIX_ENV: 'dev',
          }),
        })
      );
    });
  });
});
