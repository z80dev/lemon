/**
 * Tests for the StatusBar component.
 */

import React from 'react';
import { describe, it, expect } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { StatusBar } from './StatusBar.js';

describe('StatusBar', () => {
  it('should render nothing when there is nothing to show', () => {
    const store = createTestStore();
    const { lastFrame } = renderWithContext(<StatusBar />, { store });
    // When not busy and no usage, should render null (empty)
    expect(lastFrame()).toBe('');
  });

  it('should show busy indicator when busy', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    // Simulate busy state via a message_start event
    store.handleEvent({ type: 'agent_start' }, 'session-1');
    const { lastFrame } = renderWithContext(<StatusBar />, { store });
    expect(lastFrame()).toContain('●');
  });

  it('should show agent working message', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.setAgentWorkingMessage('Thinking hard...');
    const { lastFrame } = renderWithContext(<StatusBar />, { store });
    expect(lastFrame()).toContain('Thinking hard...');
  });

  it('should show tool working message when no agent message', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.setToolWorkingMessage('Running bash...');
    const { lastFrame } = renderWithContext(<StatusBar />, { store });
    expect(lastFrame()).toContain('Running bash...');
  });

  it('should prefer agent working message over tool working message', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.setToolWorkingMessage('Running bash...');
    store.setAgentWorkingMessage('Thinking...');
    const { lastFrame } = renderWithContext(<StatusBar />, { store });
    expect(lastFrame()).toContain('Thinking...');
    expect(lastFrame()).not.toContain('Running bash...');
  });

  it('should show status entries that are not modeline keys', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.setStatus('custom-key', 'custom-value');
    const { lastFrame } = renderWithContext(<StatusBar />, { store });
    expect(lastFrame()).toContain('custom-key: custom-value');
  });

  it('should not show modeline-prefixed status entries', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.setStatus('modeline:git', 'main +1');
    // Need something else shown to not be empty
    store.setAgentWorkingMessage('Working');
    const { lastFrame } = renderWithContext(<StatusBar />, { store });
    expect(lastFrame()).not.toContain('modeline:git');
    expect(lastFrame()).not.toContain('main +1');
  });

  it('should show token counts when there is usage', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    // Simulate a completed assistant message with usage
    const event = {
      type: 'message_start',
      data: [{
        __struct__: 'Elixir.Ai.Types.AssistantMessage',
        role: 'assistant',
        content: [{ __struct__: 'Elixir.Ai.Types.TextContent', type: 'text', text: 'Hello' }],
        provider: 'anthropic',
        model: 'claude-3',
        api: 'messages',
        usage: { input: 100, output: 50, cache_read: 0, cache_write: 0, cost: { total: 0.5 } },
        stop_reason: null,
        error_message: null,
        timestamp: Date.now(),
      }],
    };
    store.handleEvent(event, 'session-1');
    const endEvent = {
      type: 'message_end',
      data: [{
        __struct__: 'Elixir.Ai.Types.AssistantMessage',
        role: 'assistant',
        content: [{ __struct__: 'Elixir.Ai.Types.TextContent', type: 'text', text: 'Hello' }],
        provider: 'anthropic',
        model: 'claude-3',
        api: 'messages',
        usage: { input: 100, output: 50, cache_read: 0, cache_write: 0, cost: { total: 0.5 } },
        stop_reason: 'stop',
        error_message: null,
        timestamp: Date.now(),
      }],
    };
    store.handleEvent(endEvent, 'session-1');

    const { lastFrame } = renderWithContext(<StatusBar />, { store });
    const frame = lastFrame();
    expect(frame).toContain('100');
    expect(frame).toContain('50');
  });

  it('should show model name when ready', () => {
    const store = createTestStore({ ready: true, cwd: '/test', model: { provider: 'anthropic', id: 'claude-3-opus' } });
    const { lastFrame } = renderWithContext(<StatusBar />, { store });
    expect(lastFrame()).toContain('claude-3-opus');
  });

  it('should show session count when multiple sessions', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.handleSessionStarted('session-2', '/test2', { provider: 'anthropic', id: 'claude-3' });
    const { lastFrame } = renderWithContext(<StatusBar />, { store });
    const frame = lastFrame();
    expect(frame).toContain('(2)');
  });

  it('should format large token counts with k suffix', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    // Manually set cumulative usage by processing messages
    // We'll trigger it by sending messages with large usage
    const event = {
      type: 'message_end',
      data: [{
        __struct__: 'Elixir.Ai.Types.AssistantMessage',
        role: 'assistant',
        content: [{ __struct__: 'Elixir.Ai.Types.TextContent', type: 'text', text: 'Hi' }],
        provider: 'anthropic',
        model: 'claude-3',
        api: 'messages',
        usage: { input: 15000, output: 3000, cache_read: 0, cache_write: 0, cost: { total: 1.5 } },
        stop_reason: 'stop',
        error_message: null,
        timestamp: Date.now(),
      }],
    };
    store.handleEvent(event, 'session-1');

    const { lastFrame } = renderWithContext(<StatusBar />, { store });
    const frame = lastFrame();
    expect(frame).toContain('15.0k');
    expect(frame).toContain('3.0k');
    expect(frame).toContain('$1.50');
  });
});
