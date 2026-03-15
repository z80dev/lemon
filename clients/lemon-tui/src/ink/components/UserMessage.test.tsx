/**
 * Tests for the UserMessage component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { render } from 'ink-testing-library';
import { ThemeProvider } from '../context/ThemeContext.js';
import { UserMessage } from './UserMessage.js';

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider initialTheme="lemon">{ui}</ThemeProvider>);
}

function makeUserMessage(overrides: Partial<{
  id: string;
  type: 'user';
  content: string;
  timestamp: number;
}> = {}) {
  return {
    id: 'msg-1',
    type: 'user' as const,
    content: 'Hello world',
    timestamp: Date.now(),
    ...overrides,
  };
}

describe('UserMessage', () => {
  it('should render "You:" label', () => {
    const message = makeUserMessage();
    const { lastFrame } = renderWithTheme(<UserMessage message={message} />);
    expect(lastFrame()).toContain('You:');
  });

  it('should render message content', () => {
    const message = makeUserMessage({ content: 'Please help me with this code' });
    const { lastFrame } = renderWithTheme(<UserMessage message={message} />);
    expect(lastFrame()).toContain('Please help me with this code');
  });

  it('should render long content', () => {
    const longContent = 'A'.repeat(500);
    const message = makeUserMessage({ content: longContent });
    const { lastFrame } = renderWithTheme(<UserMessage message={message} />);
    const frame = lastFrame();
    // ink-testing-library wraps lines, so join all lines to check full content
    const joined = frame.replace(/\n/g, '');
    expect(joined).toContain(longContent);
  });
});
