/**
 * Tests for the AssistantMessage component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { render } from 'ink-testing-library';
import { ThemeProvider } from '../context/ThemeContext.js';
import { AssistantMessage } from './AssistantMessage.js';

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider initialTheme="lemon">{ui}</ThemeProvider>);
}

function makeAssistantMessage(overrides: Partial<{
  id: string;
  type: 'assistant';
  textContent: string;
  thinkingContent: string;
  toolCalls: Array<{ id: string; name: string; arguments: Record<string, unknown> }>;
  provider: string;
  model: string;
  usage: { inputTokens: number; outputTokens: number };
  stopReason: string | null;
  error: string | null;
  timestamp: number;
  isStreaming: boolean;
}> = {}) {
  return {
    id: 'msg-1',
    type: 'assistant' as const,
    textContent: '',
    thinkingContent: '',
    toolCalls: [],
    provider: 'anthropic',
    model: 'claude-3',
    usage: { inputTokens: 0, outputTokens: 0 },
    stopReason: null,
    error: null,
    timestamp: Date.now(),
    isStreaming: false,
    ...overrides,
  };
}

describe('AssistantMessage', () => {
  it('should render "Assistant:" label', () => {
    const message = makeAssistantMessage();
    const { lastFrame } = renderWithTheme(<AssistantMessage message={message} />);
    expect(lastFrame()).toContain('Assistant:');
  });

  it('should render text content', () => {
    const message = makeAssistantMessage({ textContent: 'Here is the answer' });
    const { lastFrame } = renderWithTheme(<AssistantMessage message={message} />);
    expect(lastFrame()).toContain('Here is the answer');
  });

  it('should render thinking content with [thinking] indicator', () => {
    const message = makeAssistantMessage({ thinkingContent: 'Let me consider this' });
    const { lastFrame } = renderWithTheme(<AssistantMessage message={message} />);
    expect(lastFrame()).toContain('[thinking]');
    expect(lastFrame()).toContain('Let me consider this');
  });

  it('should truncate thinking content to 200 chars', () => {
    const longThinking = 'X'.repeat(300);
    const message = makeAssistantMessage({ thinkingContent: longThinking });
    const { lastFrame } = renderWithTheme(<AssistantMessage message={message} />);
    const frame = lastFrame()!;
    // ink-testing-library wraps lines, so join all lines to check content
    const joined = frame.replace(/\n/g, '');
    // Should not contain the full 300-char string
    expect(joined).not.toContain(longThinking);
    // Should contain the truncated portion (first 200 chars)
    expect(joined).toContain('X'.repeat(200));
  });

  it('should render tool calls with -> prefix and tool name', () => {
    const message = makeAssistantMessage({
      toolCalls: [
        { id: 'tc-1', name: 'read_file', arguments: { path: '/test.txt' } },
      ],
    });
    const { lastFrame } = renderWithTheme(<AssistantMessage message={message} />);
    const frame = lastFrame();
    expect(frame).toContain('->');
    expect(frame).toContain('read_file');
  });

  it('should show "..." when streaming', () => {
    const message = makeAssistantMessage({ isStreaming: true, textContent: 'partial' });
    const { lastFrame } = renderWithTheme(<AssistantMessage message={message} />);
    expect(lastFrame()).toContain('...');
  });

  it('should not show "..." when not streaming', () => {
    const message = makeAssistantMessage({ isStreaming: false, textContent: 'complete' });
    const { lastFrame } = renderWithTheme(<AssistantMessage message={message} />);
    // The text content may contain "..." in theory, but the streaming indicator should not be present.
    // We check that "complete" is rendered, and "..." is not appended.
    const frame = lastFrame();
    expect(frame).toContain('complete');
    expect(frame).not.toContain('...');
  });

  it('should show [truncated] for stopReason "length"', () => {
    const message = makeAssistantMessage({ stopReason: 'length', textContent: 'Some text' });
    const { lastFrame } = renderWithTheme(<AssistantMessage message={message} />);
    expect(lastFrame()).toContain('[truncated]');
  });

  it('should show [error] for stopReason "error"', () => {
    const message = makeAssistantMessage({ stopReason: 'error', textContent: 'Some text' });
    const { lastFrame } = renderWithTheme(<AssistantMessage message={message} />);
    expect(lastFrame()).toContain('[error]');
  });

  it('should show [aborted] for stopReason "aborted"', () => {
    const message = makeAssistantMessage({ stopReason: 'aborted', textContent: 'Some text' });
    const { lastFrame } = renderWithTheme(<AssistantMessage message={message} />);
    expect(lastFrame()).toContain('[aborted]');
  });

  it('should not show stop reason when streaming', () => {
    const message = makeAssistantMessage({
      isStreaming: true,
      stopReason: 'length',
      textContent: 'Some text',
    });
    const { lastFrame } = renderWithTheme(<AssistantMessage message={message} />);
    expect(lastFrame()).not.toContain('[truncated]');
  });
});
