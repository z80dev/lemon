/**
 * Tests for the ConfirmOverlay component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { render } from 'ink-testing-library';
import { ThemeProvider } from '../context/ThemeContext.js';
import { ConfirmOverlay } from './ConfirmOverlay.js';

function delay(ms = 5) { return new Promise<void>(r => setTimeout(r, ms)); }

function renderOverlay(props: {
  title: string;
  message: string;
  onConfirm: (confirmed: boolean) => void;
}) {
  return render(
    <ThemeProvider initialTheme="lemon">
      <ConfirmOverlay {...props} />
    </ThemeProvider>
  );
}

describe('ConfirmOverlay', () => {
  it('should render title and message', () => {
    const { lastFrame } = renderOverlay({
      title: 'Confirm Delete',
      message: 'Are you sure you want to delete this?',
      onConfirm: vi.fn(),
    });
    const frame = lastFrame();
    expect(frame).toContain('Confirm Delete');
    expect(frame).toContain('Are you sure you want to delete this?');
  });

  it('should show Yes and No options', () => {
    const { lastFrame } = renderOverlay({
      title: 'Test',
      message: 'Continue?',
      onConfirm: vi.fn(),
    });
    const frame = lastFrame();
    expect(frame).toContain('Yes');
    expect(frame).toContain('No');
  });

  it('should confirm with Enter (defaults to Yes)', async () => {
    const onConfirm = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      message: 'Continue?',
      onConfirm,
    });
    await delay();
    stdin.write('\r');
    await delay();
    expect(onConfirm).toHaveBeenCalledWith(true);
  });

  it('should cancel with Escape', async () => {
    const onConfirm = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      message: 'Continue?',
      onConfirm,
    });
    await delay();
    stdin.write('\x1B');
    await delay();
    expect(onConfirm).toHaveBeenCalledWith(false);
  });

  it('should confirm with y key', async () => {
    const onConfirm = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      message: 'Continue?',
      onConfirm,
    });
    await delay();
    stdin.write('y');
    await delay();
    expect(onConfirm).toHaveBeenCalledWith(true);
  });

  it('should confirm with Y key', async () => {
    const onConfirm = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      message: 'Continue?',
      onConfirm,
    });
    await delay();
    stdin.write('Y');
    await delay();
    expect(onConfirm).toHaveBeenCalledWith(true);
  });

  it('should deny with n key', async () => {
    const onConfirm = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      message: 'Continue?',
      onConfirm,
    });
    await delay();
    stdin.write('n');
    await delay();
    expect(onConfirm).toHaveBeenCalledWith(false);
  });

  it('should deny with N key', async () => {
    const onConfirm = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      message: 'Continue?',
      onConfirm,
    });
    await delay();
    stdin.write('N');
    await delay();
    expect(onConfirm).toHaveBeenCalledWith(false);
  });

  it('should toggle selection with right arrow then Enter for No', async () => {
    const onConfirm = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      message: 'Continue?',
      onConfirm,
    });
    await delay();
    stdin.write('\x1B[C'); // Right arrow
    await delay(20);
    stdin.write('\r'); // Enter
    await delay();
    expect(onConfirm).toHaveBeenCalledWith(false);
  });

  it('should toggle back with left arrow', async () => {
    const onConfirm = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      message: 'Continue?',
      onConfirm,
    });
    await delay();
    stdin.write('\x1B[C'); // Right arrow (No)
    await delay();
    stdin.write('\x1B[D'); // Left arrow (Yes)
    await delay();
    stdin.write('\r');
    await delay();
    expect(onConfirm).toHaveBeenCalledWith(true);
  });
});
