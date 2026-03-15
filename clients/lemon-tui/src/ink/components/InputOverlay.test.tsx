/**
 * Tests for the InputOverlay component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { render } from 'ink-testing-library';
import { ThemeProvider } from '../context/ThemeContext.js';
import { InputOverlay } from './InputOverlay.js';

function delay(ms = 5) { return new Promise<void>(r => setTimeout(r, ms)); }

function renderOverlay(props: {
  title: string;
  placeholder?: string;
  onSubmit: (value: string) => void;
  onCancel: () => void;
}) {
  return render(
    <ThemeProvider initialTheme="lemon">
      <InputOverlay {...props} />
    </ThemeProvider>
  );
}

describe('InputOverlay', () => {
  it('should render title', () => {
    const { lastFrame } = renderOverlay({
      title: 'Enter value',
      onSubmit: vi.fn(),
      onCancel: vi.fn(),
    });
    expect(lastFrame()).toContain('Enter value');
  });

  it('should show placeholder when no input', () => {
    const { lastFrame } = renderOverlay({
      title: 'Test',
      placeholder: 'Type here...',
      onSubmit: vi.fn(),
      onCancel: vi.fn(),
    });
    expect(lastFrame()).toContain('Type here...');
  });

  it('should accept text input', async () => {
    const { stdin, lastFrame } = renderOverlay({
      title: 'Test',
      onSubmit: vi.fn(),
      onCancel: vi.fn(),
    });
    await delay();
    stdin.write('hello');
    await delay();
    expect(lastFrame()).toContain('hello');
  });

  it('should submit on Enter', async () => {
    const onSubmit = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      onSubmit,
      onCancel: vi.fn(),
    });
    await delay();
    stdin.write('my value');
    await delay();
    stdin.write('\r');
    await delay();
    expect(onSubmit).toHaveBeenCalledWith('my value');
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
    const onSubmit = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      onSubmit,
      onCancel: vi.fn(),
    });
    await delay();
    stdin.write('hello');
    await delay();
    stdin.write('\x7F'); // Backspace (mapped to key.delete by Ink)
    await delay(20);
    stdin.write('\x7F');
    await delay(20);
    stdin.write('\r');
    await delay();
    expect(onSubmit).toHaveBeenCalledWith('hel');
  });

  it('should handle left/right arrow movement', async () => {
    const onSubmit = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      onSubmit,
      onCancel: vi.fn(),
    });
    await delay();
    stdin.write('abc');
    await delay();
    stdin.write('\x1B[D'); // Left
    await delay();
    stdin.write('\x1B[D'); // Left
    await delay();
    stdin.write('X');
    await delay();
    stdin.write('\r');
    await delay();
    expect(onSubmit).toHaveBeenCalledWith('aXbc');
  });

  it('should not move cursor past boundaries', async () => {
    const onSubmit = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      onSubmit,
      onCancel: vi.fn(),
    });
    await delay();
    stdin.write('ab');
    await delay();
    // Try to go right past end
    stdin.write('\x1B[C');
    await delay();
    stdin.write('\x1B[C');
    await delay();
    stdin.write('\x1B[C');
    await delay();
    // Try to go left past start
    stdin.write('\x1B[D');
    await delay();
    stdin.write('\x1B[D');
    await delay();
    stdin.write('\x1B[D');
    await delay();
    stdin.write('\x1B[D');
    await delay();
    stdin.write('X');
    await delay();
    stdin.write('\r');
    await delay();
    expect(onSubmit).toHaveBeenCalledWith('Xab');
  });

  it('should show helper text', () => {
    const { lastFrame } = renderOverlay({
      title: 'Test',
      onSubmit: vi.fn(),
      onCancel: vi.fn(),
    });
    expect(lastFrame()).toContain('Enter to submit');
    expect(lastFrame()).toContain('Esc to cancel');
  });

  it('should submit empty string when Enter is pressed with no input', async () => {
    const onSubmit = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      onSubmit,
      onCancel: vi.fn(),
    });
    await delay();
    stdin.write('\r');
    await delay();
    expect(onSubmit).toHaveBeenCalledWith('');
  });
});
