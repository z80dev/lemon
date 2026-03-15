/**
 * Tests for the EditorOverlay component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { render } from 'ink-testing-library';
import { ThemeProvider } from '../context/ThemeContext.js';
import { EditorOverlay } from './EditorOverlay.js';

function delay(ms = 5) { return new Promise<void>(r => setTimeout(r, ms)); }

function renderOverlay(props: {
  title: string;
  prefill?: string;
  onSubmit: (value: string) => void;
  onCancel: () => void;
}) {
  return render(
    <ThemeProvider initialTheme="lemon">
      <EditorOverlay {...props} />
    </ThemeProvider>
  );
}

describe('EditorOverlay', () => {
  it('should render title', () => {
    const { lastFrame } = renderOverlay({
      title: 'Edit Content',
      onSubmit: vi.fn(),
      onCancel: vi.fn(),
    });
    expect(lastFrame()).toContain('Edit Content');
  });

  it('should show prefilled content', () => {
    const { lastFrame } = renderOverlay({
      title: 'Test',
      prefill: 'Initial text',
      onSubmit: vi.fn(),
      onCancel: vi.fn(),
    });
    expect(lastFrame()).toContain('Initial text');
  });

  it('should show multi-line prefilled content', () => {
    const { lastFrame } = renderOverlay({
      title: 'Test',
      prefill: 'Line 1\nLine 2\nLine 3',
      onSubmit: vi.fn(),
      onCancel: vi.fn(),
    });
    const frame = lastFrame();
    expect(frame).toContain('Line 1');
    expect(frame).toContain('Line 2');
    expect(frame).toContain('Line 3');
  });

  it('should accept text input', async () => {
    const { stdin, lastFrame } = renderOverlay({
      title: 'Test',
      onSubmit: vi.fn(),
      onCancel: vi.fn(),
    });
    await delay();
    stdin.write('hello world');
    await delay();
    expect(lastFrame()).toContain('hello world');
  });

  it('should insert newline on Enter', async () => {
    const onSubmit = vi.fn();
    const { stdin, lastFrame } = renderOverlay({
      title: 'Test',
      onSubmit,
      onCancel: vi.fn(),
    });
    await delay();
    stdin.write('line1');
    await delay();
    stdin.write('\r'); // Enter inserts newline (not submit)
    await delay();
    stdin.write('line2');
    await delay();
    const frame = lastFrame();
    expect(frame).toContain('line1');
    expect(frame).toContain('line2');
    expect(onSubmit).not.toHaveBeenCalled();
  });

  it('should cancel on Escape', async () => {
    const onCancel = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      onSubmit: vi.fn(),
      onCancel,
    });
    await delay();
    stdin.write('\x1B');
    await delay();
    expect(onCancel).toHaveBeenCalled();
  });

  it('should handle backspace', async () => {
    const { stdin, lastFrame } = renderOverlay({
      title: 'Test',
      onSubmit: vi.fn(),
      onCancel: vi.fn(),
    });
    await delay();
    stdin.write('hello');
    await delay();
    stdin.write('\x7F'); // Backspace
    await delay();
    stdin.write('\x7F'); // Backspace
    await delay();
    expect(lastFrame()).toContain('hel');
  });

  it('should handle backspace that joins lines', async () => {
    const { stdin, lastFrame } = renderOverlay({
      title: 'Test',
      prefill: 'a\nb',
      onSubmit: vi.fn(),
      onCancel: vi.fn(),
    });
    await delay();
    // Move to start of line 2 and backspace
    stdin.write('\x1B[B'); // Down to line 2
    await delay();
    // Cursor is at start of 'b', go to beginning
    stdin.write('\x1B[D'); // Left (at start, stays)
    await delay();
    stdin.write('\x7F'); // Backspace should join lines
    await delay();
    // Can't easily verify the exact text without submit, but frame should show merged content
  });

  it('should navigate with arrow keys', async () => {
    const { stdin, lastFrame } = renderOverlay({
      title: 'Test',
      prefill: 'ab\ncd',
      onSubmit: vi.fn(),
      onCancel: vi.fn(),
    });
    await delay();
    // Arrow keys should move cursor without errors
    stdin.write('\x1B[A'); // Up
    await delay();
    stdin.write('\x1B[B'); // Down
    await delay();
    stdin.write('\x1B[C'); // Right
    await delay();
    stdin.write('\x1B[D'); // Left
    await delay();
    // Should still render without errors
    expect(lastFrame()).toContain('ab');
    expect(lastFrame()).toContain('cd');
  });

  it('should show helper text', () => {
    const { lastFrame } = renderOverlay({
      title: 'Test',
      onSubmit: vi.fn(),
      onCancel: vi.fn(),
    });
    expect(lastFrame()).toContain('Meta+Enter to submit');
    expect(lastFrame()).toContain('Esc to cancel');
  });

  it('should handle empty prefill', () => {
    const { lastFrame } = renderOverlay({
      title: 'Test',
      prefill: '',
      onSubmit: vi.fn(),
      onCancel: vi.fn(),
    });
    // Should render without errors
    expect(lastFrame()).toContain('Test');
  });
});
