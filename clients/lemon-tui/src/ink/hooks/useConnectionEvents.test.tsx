/**
 * Tests for the useConnectionEvents hook.
 */

import React from 'react';
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Text } from 'ink';
import { renderWithContext, createTestStore, createMockConnection, type MockConnection } from '../test-helpers.js';
import { useConnectionEvents, type ConnectionEventHandlers } from './useConnectionEvents.js';
import { useStore, useConnection } from '../context/AppContext.js';
import type { StateStore } from '../../state.js';

const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

function EventWirer({ handlers }: { handlers: ConnectionEventHandlers }) {
  const store = useStore();
  const connection = useConnection();
  useConnectionEvents(connection, store, handlers);
  return <Text>wired</Text>;
}

describe('useConnectionEvents', () => {
  let store: StateStore;
  let connection: MockConnection;
  let handlers: ConnectionEventHandlers;

  beforeEach(() => {
    store = createTestStore({ cwd: '/test' });
    connection = createMockConnection();
    handlers = {
      onUIRequest: vi.fn(),
      onUINotify: vi.fn(),
      onSessionsList: vi.fn(),
      onSaveResult: vi.fn(),
      onSessionStarted: vi.fn(),
      onSessionClosed: vi.fn(),
      onRunningSessions: vi.fn(),
      onModelsList: vi.fn(),
      onActiveSession: vi.fn(),
      onSetEditorText: vi.fn(),
      onClose: vi.fn(),
      onReady: vi.fn(),
    };
  });

  async function setup() {
    const result = renderWithContext(
      <EventWirer handlers={handlers} />,
      { store, connection }
    );
    await delay(0);
    return result;
  }

  it('handles ready event', async () => {
    await setup();
    connection.emit('ready', {
      cwd: '/test',
      model: { provider: 'anthropic', id: 'claude-3' },
      ui: true,
      debug: false,
      primary_session_id: 's1',
      active_session_id: 's1',
    });
    await delay(0);

    expect(store.getState().ready).toBe(true);
    expect(handlers.onReady).toHaveBeenCalled();
    expect(connection.listRunningSessions).toHaveBeenCalled();
  });

  it('handles error message', async () => {
    await setup();
    connection.emit('message', {
      type: 'error',
      message: 'Something broke',
      session_id: null,
    });
    await delay(0);

    expect(store.getState().error).toBe('Something broke');
  });

  it('handles error message with session_id prefix', async () => {
    await setup();
    connection.emit('message', {
      type: 'error',
      message: 'Something broke',
      session_id: 'sess-42',
    });
    await delay(0);

    expect(store.getState().error).toBe('[sess-42] Something broke');
  });

  it('handles ui_request message', async () => {
    await setup();
    const msg = { type: 'ui_request', id: 'req-1', method: 'confirm', params: { message: 'ok?' } };
    connection.emit('message', msg);
    await delay(0);

    expect(handlers.onUIRequest).toHaveBeenCalledWith(msg);
  });

  it('handles ui_notify message', async () => {
    await setup();
    const params = { message: 'Hello!', notify_type: 'info' };
    connection.emit('message', { type: 'ui_notify', params });
    await delay(0);

    expect(handlers.onUINotify).toHaveBeenCalledWith(params);
  });

  it('handles ui_status message', async () => {
    await setup();
    connection.emit('message', {
      type: 'ui_status',
      params: { key: 'model', text: 'claude-3' },
    });
    await delay(0);

    expect(store.getState().status.get('model')).toBe('claude-3');
  });

  it('handles ui_working message', async () => {
    await setup();
    connection.emit('message', {
      type: 'ui_working',
      params: { message: 'Thinking hard...' },
    });
    await delay(0);

    expect(store.getState().agentWorkingMessage).toBe('Thinking hard...');
  });

  it('handles ui_widget message', async () => {
    await setup();
    connection.emit('message', {
      type: 'ui_widget',
      params: { key: 'my-widget', content: 'widget content', opts: { border: true } },
    });
    await delay(0);

    const widget = store.getState().widgets.get('my-widget');
    expect(widget).toBeDefined();
    expect(widget!.content).toEqual(['widget content']);
  });

  it('handles save_result message', async () => {
    await setup();
    const msg = { type: 'save_result', ok: true, path: '/tmp/save.json' };
    connection.emit('message', msg);
    await delay(0);

    expect(handlers.onSaveResult).toHaveBeenCalledWith(msg);
  });

  it('handles session_started message', async () => {
    await setup();
    const msg = {
      type: 'session_started',
      session_id: 's2',
      cwd: '/new',
      model: { provider: 'anthropic', id: 'claude-3' },
    };
    connection.emit('message', msg);
    await delay(0);

    expect(handlers.onSessionStarted).toHaveBeenCalledWith(msg);
  });

  it('handles session_closed message', async () => {
    await setup();
    const msg = { type: 'session_closed', session_id: 's1', reason: 'user' };
    connection.emit('message', msg);
    await delay(0);

    expect(handlers.onSessionClosed).toHaveBeenCalledWith(msg);
  });

  it('handles running_sessions message', async () => {
    await setup();
    const msg = { type: 'running_sessions', sessions: [], error: null };
    connection.emit('message', msg);
    await delay(0);

    expect(handlers.onRunningSessions).toHaveBeenCalledWith(msg);
  });

  it('handles active_session message', async () => {
    await setup();
    const msg = { type: 'active_session', session_id: 's3' };
    connection.emit('message', msg);
    await delay(0);

    expect(handlers.onActiveSession).toHaveBeenCalledWith(msg);
  });

  it('handles ui_set_editor_text message', async () => {
    await setup();
    connection.emit('message', {
      type: 'ui_set_editor_text',
      params: { text: 'some editor text' },
    });
    await delay(0);

    expect(handlers.onSetEditorText).toHaveBeenCalledWith('some editor text');
  });

  it('handles connection error event', async () => {
    await setup();
    connection.emit('error', new Error('connection lost'));
    await delay(0);

    expect(store.getState().error).toBe('connection lost');
  });

  it('handles connection close event', async () => {
    await setup();
    connection.emit('close', 1);
    await delay(0);

    expect(handlers.onClose).toHaveBeenCalledWith(1);
  });

  it('handles connection close event with null code', async () => {
    await setup();
    connection.emit('close', null);
    await delay(0);

    expect(handlers.onClose).toHaveBeenCalledWith(0);
  });

  it('handles debug message when debug is enabled', async () => {
    store.setDebug(true);
    await setup();
    connection.emit('message', { type: 'debug', message: 'debug info here' });
    await delay(0);

    expect(handlers.onUINotify).toHaveBeenCalledWith({
      message: '[debug] debug info here',
      notify_type: 'info',
    });
  });

  it('ignores debug message when debug is disabled', async () => {
    await setup();
    connection.emit('message', { type: 'debug', message: 'debug info here' });
    await delay(0);

    expect(handlers.onUINotify).not.toHaveBeenCalled();
  });

  it('cleans up listeners on unmount', async () => {
    const { unmount } = await setup();

    // Verify listeners were registered
    expect(connection.listenerCount('ready')).toBeGreaterThan(0);
    expect(connection.listenerCount('message')).toBeGreaterThan(0);
    expect(connection.listenerCount('error')).toBeGreaterThan(0);
    expect(connection.listenerCount('close')).toBeGreaterThan(0);

    unmount();
    await delay(0);

    // Verify all listeners were removed
    expect(connection.listenerCount('ready')).toBe(0);
    expect(connection.listenerCount('message')).toBe(0);
    expect(connection.listenerCount('error')).toBe(0);
    expect(connection.listenerCount('close')).toBe(0);

    // Emit non-error events after unmount — handlers should not be called
    connection.emit('ready', {
      cwd: '/test',
      model: { provider: 'anthropic', id: 'claude-3' },
      ui: true,
      debug: false,
      primary_session_id: 's1',
      active_session_id: 's1',
    });
    connection.emit('message', { type: 'error', message: 'after unmount', session_id: null });
    connection.emit('close', 0);
    await delay(0);

    expect(handlers.onReady).not.toHaveBeenCalled();
    expect(handlers.onClose).not.toHaveBeenCalled();
    expect(store.getState().error).toBeNull();
  });
});
