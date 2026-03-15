/**
 * Tests for the MessageList component.
 */

import React from 'react';
import { describe, it, expect } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { MessageList } from './MessageList.js';

function addUserMessage(store: ReturnType<typeof createTestStore>, content: string) {
  store.handleEvent({
    type: 'message_start',
    data: [{
      __struct__: 'Elixir.Ai.Types.UserMessage',
      role: 'user',
      content,
      timestamp: Date.now(),
    }],
  }, 'session-1');
  store.handleEvent({
    type: 'message_end',
    data: [{
      __struct__: 'Elixir.Ai.Types.UserMessage',
      role: 'user',
      content,
      timestamp: Date.now(),
    }],
  }, 'session-1');
}

function addAssistantMessage(store: ReturnType<typeof createTestStore>, text: string, opts?: { streaming?: boolean; stopReason?: string }) {
  const msg = {
    __struct__: 'Elixir.Ai.Types.AssistantMessage' as const,
    role: 'assistant' as const,
    content: [{ __struct__: 'Elixir.Ai.Types.TextContent' as const, type: 'text' as const, text }],
    provider: 'anthropic',
    model: 'claude-3',
    api: 'messages',
    usage: { input: 10, output: 5 },
    stop_reason: (opts?.stopReason || 'stop') as 'stop',
    error_message: null,
    timestamp: Date.now(),
  };

  store.handleEvent({ type: 'message_start', data: [msg] }, 'session-1');
  if (!opts?.streaming) {
    store.handleEvent({ type: 'message_end', data: [msg] }, 'session-1');
  }
}

function addToolResultMessage(store: ReturnType<typeof createTestStore>, toolName: string, content: string, opts?: { isError?: boolean }) {
  store.handleEvent({
    type: 'message_start',
    data: [{
      __struct__: 'Elixir.Ai.Types.ToolResultMessage',
      role: 'tool_result',
      tool_call_id: `tc-${Date.now()}`,
      tool_name: toolName,
      content: [{ __struct__: 'Elixir.Ai.Types.TextContent', type: 'text', text: content }],
      is_error: opts?.isError || false,
      timestamp: Date.now(),
    }],
  }, 'session-1');
  store.handleEvent({
    type: 'message_end',
    data: [{
      __struct__: 'Elixir.Ai.Types.ToolResultMessage',
      role: 'tool_result',
      tool_call_id: `tc-${Date.now()}`,
      tool_name: toolName,
      content: [{ __struct__: 'Elixir.Ai.Types.TextContent', type: 'text', text: content }],
      is_error: opts?.isError || false,
      timestamp: Date.now(),
    }],
  }, 'session-1');
}

describe('MessageList', () => {
  it('should render nothing when there are no messages', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { lastFrame } = renderWithContext(
      <MessageList showToolResults={true} />,
      { store }
    );
    expect(lastFrame()).toBe('');
  });

  it('should render user messages', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    addUserMessage(store, 'Hello, world!');

    const { lastFrame } = renderWithContext(
      <MessageList showToolResults={true} />,
      { store }
    );
    const frame = lastFrame();
    expect(frame).toContain('You:');
    expect(frame).toContain('Hello, world!');
  });

  it('should render assistant messages', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    addAssistantMessage(store, 'Hi there!');

    const { lastFrame } = renderWithContext(
      <MessageList showToolResults={true} />,
      { store }
    );
    const frame = lastFrame();
    expect(frame).toContain('Assistant:');
    expect(frame).toContain('Hi there!');
  });

  it('should render tool result messages', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    addToolResultMessage(store, 'bash', 'command output here');

    const { lastFrame } = renderWithContext(
      <MessageList showToolResults={true} />,
      { store }
    );
    expect(lastFrame()).toContain('[bash]');
    expect(lastFrame()).toContain('command output here');
  });

  it('should show separators between user and assistant turns', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    addUserMessage(store, 'Question');
    addAssistantMessage(store, 'Answer');

    const { lastFrame } = renderWithContext(
      <MessageList showToolResults={true} />,
      { store }
    );
    const frame = lastFrame();
    expect(frame).toContain('\u2500'); // separator line character
    expect(frame).toContain('You:');
    expect(frame).toContain('Assistant:');
  });

  it('should hide tool results when showToolResults is false', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    addToolResultMessage(store, 'read', 'file content here');

    const { lastFrame } = renderWithContext(
      <MessageList showToolResults={false} />,
      { store }
    );
    expect(lastFrame()).not.toContain('[read]');
    expect(lastFrame()).not.toContain('file content here');
  });

  it('should show tool results when showToolResults is true', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    addToolResultMessage(store, 'read', 'file content here');

    const { lastFrame } = renderWithContext(
      <MessageList showToolResults={true} />,
      { store }
    );
    expect(lastFrame()).toContain('[read]');
  });

  it('should truncate long tool result content', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const longContent = 'x'.repeat(1200);
    addToolResultMessage(store, 'bash', longContent);

    const { lastFrame } = renderWithContext(
      <MessageList showToolResults={true} />,
      { store }
    );
    const frame = lastFrame();
    expect(frame).toContain('truncated');
    // Should not contain the full 1200 chars
    expect(frame.length).toBeLessThan(longContent.length);
  });

  it('should show multiple messages in order', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    addUserMessage(store, 'First question');
    addAssistantMessage(store, 'First answer');
    addUserMessage(store, 'Second question');
    addAssistantMessage(store, 'Second answer');

    const { lastFrame } = renderWithContext(
      <MessageList showToolResults={true} />,
      { store }
    );
    const frame = lastFrame();
    expect(frame).toContain('First question');
    expect(frame).toContain('First answer');
    expect(frame).toContain('Second question');
    expect(frame).toContain('Second answer');
  });

  it('should mark error tool results with error indicator', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    addToolResultMessage(store, 'bash', 'command failed', { isError: true });

    const { lastFrame } = renderWithContext(
      <MessageList showToolResults={true} />,
      { store }
    );
    expect(lastFrame()).toContain('[bash]');
    expect(lastFrame()).toContain('command failed');
  });

  it('should show stop reason for truncated assistant messages', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    addAssistantMessage(store, 'Partial response...', { stopReason: 'length' });

    const { lastFrame } = renderWithContext(
      <MessageList showToolResults={true} />,
      { store }
    );
    expect(lastFrame()).toContain('[truncated]');
  });

  it('should show stop reason for aborted messages', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    addAssistantMessage(store, 'Interrupted', { stopReason: 'aborted' });

    const { lastFrame } = renderWithContext(
      <MessageList showToolResults={true} />,
      { store }
    );
    expect(lastFrame()).toContain('[aborted]');
  });
});
