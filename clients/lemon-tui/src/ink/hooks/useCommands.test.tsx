/**
 * Tests for the useCommands hook.
 */

import React from 'react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderWithContext, createTestStore, createMockConnection, type MockConnection } from '../test-helpers.js';
import { Text, Box } from 'ink';
import { useCommands } from './useCommands.js';
import type { StateStore } from '../../state.js';

// Test component that exposes the hook's handleInput function via stdin
function CommandTester({ handlers }: { handlers: Parameters<typeof useCommands>[0] }) {
  const { handleInput } = useCommands(handlers);
  // Expose handleInput through a test interface - call it via global
  (globalThis as any).__testHandleInput = handleInput;
  return <Text>ready</Text>;
}

describe('useCommands', () => {
  let store: StateStore;
  let connection: MockConnection;
  let handlers: Parameters<typeof useCommands>[0];

  beforeEach(() => {
    store = createTestStore({ ready: true, cwd: '/test' });
    connection = createMockConnection();
    handlers = {
      onShowSettings: vi.fn(),
      onShowHelp: vi.fn(),
      onShowStats: vi.fn(),
      onShowSearch: vi.fn(),
      onShowNotifications: vi.fn(),
      onNewSession: vi.fn(),
      onShowRunning: vi.fn(),
      onStop: vi.fn(),
      onRestart: vi.fn(),
      onClearMessages: vi.fn(),
      onNotify: vi.fn(),
      onEditLastMessage: vi.fn(),
      onCopyLastCode: vi.fn(),
    };
  });

  function setup() {
    renderWithContext(
      <CommandTester handlers={handlers} />,
      { store, connection }
    );
    return (globalThis as any).__testHandleInput as (text: string) => void;
  }

  it('should handle /abort command', () => {
    const handleInput = setup();
    handleInput('/abort');
    expect(connection.abort).toHaveBeenCalled();
  });

  it('should handle /reset command', () => {
    const handleInput = setup();
    handleInput('/reset');
    expect(connection.reset).toHaveBeenCalled();
    expect(handlers.onClearMessages).toHaveBeenCalled();
  });

  it('should handle /save command', () => {
    const handleInput = setup();
    handleInput('/save');
    expect(connection.save).toHaveBeenCalled();
  });

  it('should handle /sessions command', () => {
    const handleInput = setup();
    handleInput('/sessions');
    expect(connection.listSessions).toHaveBeenCalled();
  });

  it('should handle /stats command', () => {
    const handleInput = setup();
    handleInput('/stats');
    expect(handlers.onShowStats).toHaveBeenCalled();
  });

  it('should handle /settings command', () => {
    const handleInput = setup();
    handleInput('/settings');
    expect(handlers.onShowSettings).toHaveBeenCalled();
  });

  it('should handle /help command', () => {
    const handleInput = setup();
    handleInput('/help');
    expect(handlers.onShowHelp).toHaveBeenCalled();
  });

  it('should handle /search command', () => {
    const handleInput = setup();
    handleInput('/search foo bar');
    expect(handlers.onShowSearch).toHaveBeenCalledWith('foo bar');
  });

  it('should handle /quit command', () => {
    const handleInput = setup();
    handleInput('/quit');
    expect(handlers.onStop).toHaveBeenCalled();
  });

  it('should handle /exit command', () => {
    const handleInput = setup();
    handleInput('/exit');
    expect(handlers.onStop).toHaveBeenCalled();
  });

  it('should handle /q command', () => {
    const handleInput = setup();
    handleInput('/q');
    expect(handlers.onStop).toHaveBeenCalled();
  });

  it('should handle /debug on', () => {
    const handleInput = setup();
    handleInput('/debug on');
    expect(store.getState().debug).toBe(true);
    expect(handlers.onNotify).toHaveBeenCalledWith('Debug mode enabled', 'info');
  });

  it('should handle /debug off', () => {
    const handleInput = setup();
    store.setDebug(true);
    handleInput('/debug off');
    expect(store.getState().debug).toBe(false);
  });

  it('should handle /debug toggle', () => {
    const handleInput = setup();
    handleInput('/debug');
    expect(store.getState().debug).toBe(true);
    handleInput('/debug');
    expect(store.getState().debug).toBe(false);
  });

  it('should handle /restart command', () => {
    const handleInput = setup();
    handleInput('/restart something changed');
    expect(handlers.onRestart).toHaveBeenCalledWith('something changed');
  });

  it('should handle /restart without args', () => {
    const handleInput = setup();
    handleInput('/restart');
    expect(handlers.onRestart).toHaveBeenCalledWith('User requested restart');
  });

  it('should handle /goal status command', () => {
    const handleInput = setup();
    handleInput('/goal');
    expect(connection.goalStatus).toHaveBeenCalledWith('session-1');
  });

  it('should handle /goal set command', () => {
    const handleInput = setup();
    handleInput('/goal set ship hermes parity');
    expect(connection.goalSet).toHaveBeenCalledWith('ship hermes parity', 'session-1', {});
  });

  it('should handle /goal set budget option', () => {
    const handleInput = setup();
    handleInput('/goal set --max-continuations 3 ship hermes parity');
    expect(connection.goalSet).toHaveBeenCalledWith('ship hermes parity', 'session-1', {
      maxContinuations: 3,
    });
  });

  it('should validate /goal set objective', () => {
    const handleInput = setup();
    handleInput('/goal set');
    expect(store.getState().error).toBe('Usage: /goal set [--max-continuations N] <objective>');
  });

  it('should handle /goal pause and resume commands', () => {
    const handleInput = setup();
    handleInput('/goal pause');
    handleInput('/goal resume');
    expect(connection.goalPause).toHaveBeenCalledWith('session-1');
    expect(connection.goalResume).toHaveBeenCalledWith('session-1');
  });

  it('should handle /goal continue command', () => {
    const handleInput = setup();
    handleInput('/goal continue --max-continuations 4 --model worker-model');
    expect(connection.goalContinue).toHaveBeenCalledWith('session-1', {
      maxContinuations: 4,
      model: 'worker-model',
    });
  });

  it('should handle /goal loop once command', () => {
    const handleInput = setup();
    handleInput('/goal loop once --judge-model judge-model --judge-failure-policy continueOnce');
    expect(connection.goalLoopOnce).toHaveBeenCalledWith('session-1', {
      judgeModel: 'judge-model',
      judgeFailurePolicy: 'continueOnce',
    });
  });

  it('should handle goal loop control commands', () => {
    const handleInput = setup();
    handleInput('/goal loop start --auto --max-ticks 5 --max-continuations 3 --interval-ms 50 --wait-timeout-ms 1000 --judge-model judge-model --judge-failure-policy needsInput');
    handleInput('/goal loop status');
    handleInput('/goal loop stop');
    expect(connection.goalLoopStart).toHaveBeenCalledWith('session-1', {
      maxTicks: 5,
      maxContinuations: 3,
      intervalMs: 50,
      waitTimeoutMs: 1000,
      judgeModel: 'judge-model',
      judgeFailurePolicy: 'needsInput',
      auto: true,
    });
    expect(connection.goalLoopStatus).toHaveBeenCalledWith('session-1');
    expect(connection.goalLoopStop).toHaveBeenCalledWith('session-1');
  });

  it('should reject invalid goal option values', () => {
    const handleInput = setup();
    handleInput('/goal loop start --max-ticks 0');
    expect(store.getState().error).toBe('--max-ticks must be a positive integer.');
  });

  it('should handle /goal clear command', () => {
    const handleInput = setup();
    handleInput('/goal clear');
    expect(connection.goalClear).toHaveBeenCalledWith('session-1');
  });

  it('should handle kanban board commands', () => {
    const handleInput = setup();
    handleInput('/kanban boards --owner codex --limit 5');
    handleInput('/kanban create --workspace /tmp/lemon Hermes parity');
    handleInput('/kanban show board_1 --limit 10');
    handleInput('/kanban archive board_1');

    expect(connection.kanbanBoardList).toHaveBeenCalledWith({
      owner: 'codex',
      limit: 5,
    });
    expect(connection.kanbanBoardCreate).toHaveBeenCalledWith('Hermes parity', {
      workspace: '/tmp/lemon',
    });
    expect(connection.kanbanBoardGet).toHaveBeenCalledWith('board_1', {
      limit: 10,
    });
    expect(connection.kanbanBoardArchive).toHaveBeenCalledWith('board_1');
  });

  it('should handle kanban task commands', () => {
    const handleInput = setup();
    handleInput('/kanban task create board_1 --priority high --assignee sonnet Build tool');
    handleInput('/kanban task update task_1 --status doing --worker-profile senior');
    handleInput('/kanban comment task_1 --author codex Needs proof');

    expect(connection.kanbanTaskCreate).toHaveBeenCalledWith('board_1', 'Build tool', {
      priority: 'high',
      assignee: 'sonnet',
    });
    expect(connection.kanbanTaskUpdate).toHaveBeenCalledWith('task_1', {
      status: 'doing',
      workerProfile: 'senior',
    });
    expect(connection.kanbanTaskComment).toHaveBeenCalledWith('task_1', 'Needs proof', {
      author: 'codex',
    });
  });

  it('should handle kanban dispatcher commands', () => {
    const handleInput = setup();
    handleInput('/kanban dispatch start board_1 --max-concurrency 2 --lease-ms 1000 --worker-id worker-a --worker-profile junior');
    handleInput('/kanban dispatch status board_1');
    handleInput('/kanban dispatch stop board_1');

    expect(connection.kanbanDispatcherStart).toHaveBeenCalledWith('board_1', {
      maxConcurrency: 2,
      leaseMs: 1000,
      workerId: 'worker-a',
      workerProfile: 'junior',
    });
    expect(connection.kanbanDispatcherStatus).toHaveBeenCalledWith('board_1');
    expect(connection.kanbanDispatcherStop).toHaveBeenCalledWith('board_1');
  });

  it('should validate kanban commands', () => {
    const handleInput = setup();
    handleInput('/kanban task create board_1');
    expect(store.getState().error).toBe('Usage: /kanban task create <board-id> <title>');

    handleInput('/kanban boards --limit nope');
    expect(store.getState().error).toBe('--limit must be a positive integer.');
  });

  it('should handle checkpoint rollback commands', () => {
    const handleInput = setup();
    handleInput('/checkpoint diff chk_1 /tmp/a.txt');
    handleInput('/checkpoint restore chk_1 /tmp/a.txt /tmp/b.txt');

    expect(connection.checkpointDiff).toHaveBeenCalledWith('chk_1', ['/tmp/a.txt']);
    expect(connection.checkpointRestore).toHaveBeenCalledWith('chk_1', [
      '/tmp/a.txt',
      '/tmp/b.txt',
    ]);
  });

  it('should validate checkpoint commands', () => {
    const handleInput = setup();
    handleInput('/checkpoint restore');
    expect(store.getState().error).toBe(
      'Usage: /checkpoint [diff|restore] <checkpoint-id> [path ...]'
    );
  });

  it('should handle cron abort commands', () => {
    const handleInput = setup();
    handleInput('/cron abort cron_run_1');
    expect(connection.cronAbort).toHaveBeenCalledWith('cron_run_1');
  });

  it('should validate cron commands', () => {
    const handleInput = setup();
    handleInput('/cron abort');
    expect(store.getState().error).toBe('Usage: /cron abort <run-id>');

    handleInput('/cron');
    expect(store.getState().error).toBe('Usage: /cron abort <run-id>');
  });

  it('should handle approval resolve commands', () => {
    const handleInput = setup();
    handleInput('/approval');
    handleInput('/approval list');
    handleInput('/approval once approval_1');
    handleInput('/approval session approval_2');
    handleInput('/approval agent approval_3');
    handleInput('/approval global approval_4');
    handleInput('/approval deny approval_5');

    expect(connection.approvalList).toHaveBeenCalledTimes(2);
    expect(connection.approvalResolve).toHaveBeenNthCalledWith(1, 'approval_1', 'approve_once');
    expect(connection.approvalResolve).toHaveBeenNthCalledWith(2, 'approval_2', 'approve_session');
    expect(connection.approvalResolve).toHaveBeenNthCalledWith(3, 'approval_3', 'approve_agent');
    expect(connection.approvalResolve).toHaveBeenNthCalledWith(4, 'approval_4', 'approve_global');
    expect(connection.approvalResolve).toHaveBeenNthCalledWith(5, 'approval_5', 'deny');
  });

  it('should validate approval commands', () => {
    const handleInput = setup();
    const usage = 'Usage: /approval [list|approve|once|session|agent|global|deny <approval-id>]';

    handleInput('/approval once');
    expect(store.getState().error).toBe(usage);

    handleInput('/approval later approval_1');
    expect(store.getState().error).toBe(usage);
  });

  it('should handle /running command', () => {
    const handleInput = setup();
    handleInput('/running');
    expect(handlers.onShowRunning).toHaveBeenCalled();
  });

  it('should handle /new-session command', () => {
    const handleInput = setup();
    handleInput('/new-session');
    expect(handlers.onNewSession).toHaveBeenCalled();
  });

  it('should handle /new-session with --cwd and --model', () => {
    const handleInput = setup();
    handleInput('/new-session --cwd /tmp --model anthropic:claude-3');
    expect(handlers.onNewSession).toHaveBeenCalledWith({
      cwd: '/tmp',
      model: 'anthropic:claude-3',
    });
  });

  it('should handle /switch with session id', () => {
    const handleInput = setup();
    handleInput('/switch session-abc');
    expect(connection.setActiveSession).toHaveBeenCalledWith('session-abc');
  });

  it('should handle /switch without args', () => {
    const handleInput = setup();
    handleInput('/switch');
    expect(connection.listRunningSessions).toHaveBeenCalled();
  });

  it('should handle /close-session', () => {
    const handleInput = setup();
    handleInput('/close-session session-xyz');
    expect(connection.closeSession).toHaveBeenCalledWith('session-xyz');
  });

  it('should handle /close-session without args (closes active)', () => {
    const handleInput = setup();
    handleInput('/close-session');
    expect(connection.closeSession).toHaveBeenCalledWith('session-1');
  });

  it('should handle /edit command', () => {
    const handleInput = setup();
    handleInput('/edit');
    expect(handlers.onEditLastMessage).toHaveBeenCalled();
  });

  it('should handle /copy command', () => {
    const handleInput = setup();
    handleInput('/copy');
    expect(handlers.onCopyLastCode).toHaveBeenCalled();
  });

  it('should set error for unknown commands', () => {
    const handleInput = setup();
    handleInput('/unknowncmd');
    expect(store.getState().error).toContain('Unknown command: /unknowncmd');
  });

  it('should send non-slash input as prompt', () => {
    const handleInput = setup();
    handleInput('Hello, how are you?');
    expect(connection.prompt).toHaveBeenCalledWith('Hello, how are you?', 'session-1');
  });

  it('should open new session for prompt when no active session', () => {
    const handleInput = setup();
    store.setActiveSessionId(null);
    handleInput('Hello!');
    expect(handlers.onNewSession).toHaveBeenCalled();
    expect(connection.prompt).not.toHaveBeenCalled();
  });

  it('should ignore empty input', () => {
    const handleInput = setup();
    handleInput('');
    expect(connection.prompt).not.toHaveBeenCalled();
  });

  it('should ignore whitespace-only input', () => {
    const handleInput = setup();
    handleInput('   ');
    expect(connection.prompt).not.toHaveBeenCalled();
  });

  it('should trim whitespace from input', () => {
    const handleInput = setup();
    handleInput('  hello  ');
    expect(connection.prompt).toHaveBeenCalledWith('hello', 'session-1');
  });
});
