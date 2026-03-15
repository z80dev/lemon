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
