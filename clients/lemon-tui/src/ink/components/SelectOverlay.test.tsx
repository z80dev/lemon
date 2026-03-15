/**
 * Tests for the SelectOverlay component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { render } from 'ink-testing-library';
import { ThemeProvider } from '../context/ThemeContext.js';
import { SelectOverlay } from './SelectOverlay.js';

function delay(ms = 5) { return new Promise<void>(r => setTimeout(r, ms)); }

function renderOverlay(props: {
  title: string;
  options: Array<{ label: string; value: string; description?: string }>;
  onSelect: (value: string) => void;
  onCancel: () => void;
}) {
  return render(
    <ThemeProvider initialTheme="lemon">
      <SelectOverlay {...props} />
    </ThemeProvider>
  );
}

const testOptions = [
  { label: 'Option A', value: 'a', description: 'First option' },
  { label: 'Option B', value: 'b', description: 'Second option' },
  { label: 'Option C', value: 'c' },
];

describe('SelectOverlay', () => {
  it('should render title and options', () => {
    const onSelect = vi.fn();
    const onCancel = vi.fn();
    const { lastFrame } = renderOverlay({
      title: 'Choose an option',
      options: testOptions,
      onSelect,
      onCancel,
    });
    const frame = lastFrame();
    expect(frame).toContain('Choose an option');
    expect(frame).toContain('Option A');
    expect(frame).toContain('Option B');
    expect(frame).toContain('Option C');
  });

  it('should show descriptions', () => {
    const { lastFrame } = renderOverlay({
      title: 'Test',
      options: testOptions,
      onSelect: vi.fn(),
      onCancel: vi.fn(),
    });
    expect(lastFrame()).toContain('First option');
    expect(lastFrame()).toContain('Second option');
  });

  it('should highlight the first option by default', () => {
    const { lastFrame } = renderOverlay({
      title: 'Test',
      options: testOptions,
      onSelect: vi.fn(),
      onCancel: vi.fn(),
    });
    expect(lastFrame()).toContain('> ');
  });

  it('should select on Enter key', async () => {
    const onSelect = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      options: testOptions,
      onSelect,
      onCancel: vi.fn(),
    });

    await delay();
    stdin.write('\r'); // Enter
    await delay();
    expect(onSelect).toHaveBeenCalledWith('a');
  });

  it('should navigate down with arrow key', async () => {
    const onSelect = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      options: testOptions,
      onSelect,
      onCancel: vi.fn(),
    });

    // Press down arrow then Enter
    await delay();
    stdin.write('\x1B[B'); // Down arrow
    await delay(20);
    stdin.write('\r'); // Enter
    await delay();
    expect(onSelect).toHaveBeenCalledWith('b');
  });

  it('should navigate up with arrow key', async () => {
    const onSelect = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      options: testOptions,
      onSelect,
      onCancel: vi.fn(),
    });

    // Down twice, up once, should be on 'b'
    await delay();
    stdin.write('\x1B[B'); // Down
    await delay();
    stdin.write('\x1B[B'); // Down
    await delay();
    stdin.write('\x1B[A'); // Up
    await delay(20);
    stdin.write('\r');
    await delay();
    expect(onSelect).toHaveBeenCalledWith('b');
  });

  it('should cancel on Escape', async () => {
    const onCancel = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      options: testOptions,
      onSelect: vi.fn(),
      onCancel,
    });

    await delay();
    stdin.write('\x1B'); // Escape
    await delay();
    expect(onCancel).toHaveBeenCalled();
  });

  it('should filter options when typing', async () => {
    const { stdin, lastFrame } = renderOverlay({
      title: 'Test',
      options: testOptions,
      onSelect: vi.fn(),
      onCancel: vi.fn(),
    });

    await delay();
    stdin.write('B');
    await delay();
    const frame = lastFrame();
    expect(frame).toContain('Filter: B');
    expect(frame).toContain('Option B');
    // Option A and C should be filtered out
    expect(frame).not.toContain('Option A');
    expect(frame).not.toContain('Option C');
  });

  it('should show no matches message', async () => {
    const { stdin, lastFrame } = renderOverlay({
      title: 'Test',
      options: testOptions,
      onSelect: vi.fn(),
      onCancel: vi.fn(),
    });

    await delay();
    stdin.write('xyz');
    await delay();
    expect(lastFrame()).toContain('No matches');
  });

  it('should clear filter with backspace', async () => {
    const { stdin, lastFrame } = renderOverlay({
      title: 'Test',
      options: testOptions,
      onSelect: vi.fn(),
      onCancel: vi.fn(),
    });

    await delay();
    stdin.write('B');
    await delay();
    expect(lastFrame()).toContain('Filter: B');
    stdin.write('\x7F'); // Backspace
    await delay();
    const frame = lastFrame();
    expect(frame).toContain('Option A');
    expect(frame).toContain('Option B');
    expect(frame).toContain('Option C');
  });

  it('should not go below the last option', async () => {
    const onSelect = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      options: testOptions,
      onSelect,
      onCancel: vi.fn(),
    });

    // Press down 10 times — should stay on last item
    await delay();
    for (let i = 0; i < 10; i++) {
      stdin.write('\x1B[B');
      await delay();
    }
    stdin.write('\r');
    await delay();
    expect(onSelect).toHaveBeenCalledWith('c');
  });

  it('should not go above the first option', async () => {
    const onSelect = vi.fn();
    const { stdin } = renderOverlay({
      title: 'Test',
      options: testOptions,
      onSelect,
      onCancel: vi.fn(),
    });

    // Press up — should stay on first item
    await delay();
    stdin.write('\x1B[A');
    await delay();
    stdin.write('\r');
    await delay();
    expect(onSelect).toHaveBeenCalledWith('a');
  });

  it('should show helper text', () => {
    const { lastFrame } = renderOverlay({
      title: 'Test',
      options: testOptions,
      onSelect: vi.fn(),
      onCancel: vi.fn(),
    });
    expect(lastFrame()).toContain('Enter to select');
    expect(lastFrame()).toContain('Esc to cancel');
  });

  it('should truncate to 12 items max', () => {
    const manyOptions = Array.from({ length: 20 }, (_, i) => ({
      label: `Item ${i}`,
      value: `${i}`,
    }));
    const { lastFrame } = renderOverlay({
      title: 'Test',
      options: manyOptions,
      onSelect: vi.fn(),
      onCancel: vi.fn(),
    });
    const frame = lastFrame();
    expect(frame).toContain('...8 more');
  });
});
