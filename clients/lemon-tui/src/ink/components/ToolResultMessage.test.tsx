/**
 * Tests for the ToolResultMessage component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { render } from 'ink-testing-library';
import { ThemeProvider } from '../context/ThemeContext.js';
import { ToolResultMessage } from './ToolResultMessage.js';

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider initialTheme="lemon">{ui}</ThemeProvider>);
}

function makeToolResultMessage(overrides: Partial<{
  id: string;
  type: 'tool_result';
  toolCallId: string;
  toolName: string;
  content: string;
  images: Array<{ type: string; data: string }>;
  trust: 'trusted' | 'untrusted';
  trustMetadata: unknown;
  isTrusted: boolean;
  isError: boolean;
  timestamp: number;
}> = {}) {
  return {
    id: 'msg-1',
    type: 'tool_result' as const,
    toolCallId: 'tc-1',
    toolName: 'read_file',
    content: 'file contents here',
    images: [],
    trust: 'trusted' as const,
    trustMetadata: null,
    isTrusted: true,
    isError: false,
    timestamp: Date.now(),
    ...overrides,
  };
}

describe('ToolResultMessage', () => {
  it('should render tool name in brackets', () => {
    const message = makeToolResultMessage({ toolName: 'read_file' });
    const { lastFrame } = renderWithTheme(<ToolResultMessage message={message} />);
    expect(lastFrame()).toContain('[read_file]');
  });

  it('should render content', () => {
    const message = makeToolResultMessage({ content: 'some output data' });
    const { lastFrame } = renderWithTheme(<ToolResultMessage message={message} />);
    expect(lastFrame()).toContain('some output data');
  });

  it('should show [untrusted] indicator for untrusted results', () => {
    const message = makeToolResultMessage({ trust: 'untrusted', isTrusted: false });
    const { lastFrame } = renderWithTheme(<ToolResultMessage message={message} />);
    expect(lastFrame()).toContain('[untrusted]');
  });

  it('should truncate content over 1000 chars', () => {
    const longContent = 'Z'.repeat(1200);
    const message = makeToolResultMessage({ content: longContent });
    const { lastFrame } = renderWithTheme(<ToolResultMessage message={message} />);
    const frame = lastFrame();
    const joined = frame.replace(/\n/g, '');
    // Should not contain the full 1200-char string
    expect(joined).not.toContain(longContent);
    // Should contain the truncated portion (first 1000 chars)
    expect(joined).toContain('Z'.repeat(1000));
    // Should show truncation indicator
    expect(joined).toContain('truncated');
  });

  it('should pretty-print JSON content', () => {
    const json = '{"name":"Alice","age":30}';
    const message = makeToolResultMessage({ content: json });
    const { lastFrame } = renderWithTheme(<ToolResultMessage message={message} />);
    const frame = lastFrame();
    expect(frame).toContain('Alice');
    expect(frame).toContain('30');
  });

  it('should color diff output', () => {
    const diff = '--- a/file.ts\n+++ b/file.ts\n@@ -1,3 +1,3 @@\n-old line\n+new line\n context';
    const message = makeToolResultMessage({ content: diff });
    const { lastFrame } = renderWithTheme(<ToolResultMessage message={message} />);
    const frame = lastFrame();
    expect(frame).toContain('+new line');
    expect(frame).toContain('-old line');
    expect(frame).toContain('@@');
  });

  it('should format errors with cross mark', () => {
    const message = makeToolResultMessage({ content: 'something went wrong', isError: true });
    const { lastFrame } = renderWithTheme(<ToolResultMessage message={message} />);
    const frame = lastFrame();
    expect(frame).toContain('\u2717');
    expect(frame).toContain('something went wrong');
  });

  it('should show image count for single image', () => {
    const message = makeToolResultMessage({
      images: [{ type: 'image/png', data: 'base64data' }],
    });
    const { lastFrame } = renderWithTheme(<ToolResultMessage message={message} />);
    const frame = lastFrame();
    expect(frame).toContain('1 image');
    // Should not say "images" (plural)
    expect(frame).not.toContain('1 images');
  });

  it('should show image count for multiple images (plural)', () => {
    const message = makeToolResultMessage({
      images: [
        { type: 'image/png', data: 'base64data1' },
        { type: 'image/png', data: 'base64data2' },
        { type: 'image/png', data: 'base64data3' },
      ],
    });
    const { lastFrame } = renderWithTheme(<ToolResultMessage message={message} />);
    expect(lastFrame()).toContain('3 images');
  });

  it('should not show image indicator when no images', () => {
    const message = makeToolResultMessage({ images: [] });
    const { lastFrame } = renderWithTheme(<ToolResultMessage message={message} />);
    const frame = lastFrame();
    expect(frame).not.toContain('image');
  });
});
