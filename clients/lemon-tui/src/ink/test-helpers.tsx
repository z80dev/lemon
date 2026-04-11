/**
 * Test helpers for Ink component tests.
 * Provides wrapper components with required context providers.
 */

import React from 'react';
import { render } from 'ink-testing-library';
import { vi } from 'vitest';
import { AppProvider } from './context/AppContext.js';
import { ThemeProvider } from './context/ThemeContext.js';
import { StateStore } from '../state.js';
import { EventEmitter } from 'node:events';

/**
 * Creates a minimal mock of AgentConnection for testing.
 */
export function createMockConnection() {
  const emitter = new EventEmitter();
  return Object.assign(emitter, {
    start: vi.fn().mockResolvedValue(undefined),
    stop: vi.fn(),
    restart: vi.fn().mockResolvedValue(undefined),
    prompt: vi.fn(),
    abort: vi.fn(),
    reset: vi.fn(),
    save: vi.fn(),
    stats: vi.fn(),
    listSessions: vi.fn(),
    listRunningSessions: vi.fn(),
    listModels: vi.fn(),
    startSession: vi.fn(),
    closeSession: vi.fn(),
    setActiveSession: vi.fn(),
    respondToUIRequest: vi.fn(),
    getRestartExitCode: vi.fn().mockReturnValue(75),
  });
}

export type MockConnection = ReturnType<typeof createMockConnection>;
type TestRenderStream = {
  frames: string[];
  write: (frame: string) => void;
  lastFrame: () => string | undefined;
};

type TestRenderStdin = {
  isTTY: boolean;
  write: (data: string) => void;
  setEncoding: () => void;
  setRawMode: () => void;
  resume: () => void;
  pause: () => void;
  ref: () => void;
  unref: () => void;
  read: () => string | null;
};

export type RenderWithContextResult = {
  rerender: (tree: React.ReactElement) => void;
  unmount: () => void;
  cleanup: () => void;
  stdout: TestRenderStream;
  stderr: TestRenderStream;
  stdin: TestRenderStdin;
  frames: string[];
  lastFrame: () => string | undefined;
  store: StateStore;
  connection: MockConnection;
};

/**
 * Creates a StateStore with optional initial ready state.
 */
export function createTestStore(opts?: {
  cwd?: string;
  ready?: boolean;
  model?: { provider: string; id: string };
}) {
  const store = new StateStore({ cwd: opts?.cwd });
  if (opts?.ready) {
    store.setReady(
      opts.cwd || '/test',
      opts.model || { provider: 'anthropic', id: 'claude-3' },
      true,
      false,
      'session-1',
      'session-1'
    );
  }
  return store;
}

/**
 * Renders an Ink component wrapped in the required context providers.
 */
export function renderWithContext(
  ui: React.ReactElement,
  opts?: {
    store?: StateStore;
    connection?: MockConnection;
    theme?: string;
  }
): RenderWithContextResult {
  const store = opts?.store || createTestStore();
  const connection = opts?.connection || createMockConnection();
  const theme = opts?.theme || 'lemon';

  const connAsAny = connection as any;

  const result = render(
    <AppProvider store={store} connection={connAsAny}>
      <ThemeProvider initialTheme={theme}>
        {ui}
      </ThemeProvider>
    </AppProvider>
  );

  return { ...result, store, connection };
}
