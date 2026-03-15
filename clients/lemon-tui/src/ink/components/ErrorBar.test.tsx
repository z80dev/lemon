/**
 * Tests for the ErrorBar component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { ErrorBar } from './ErrorBar.js';

function delay(ms = 5) { return new Promise<void>(r => setTimeout(r, ms)); }

describe('ErrorBar', () => {
  it('should render nothing when there is no error', () => {
    const store = createTestStore();
    const { lastFrame } = renderWithContext(<ErrorBar />, { store });
    expect(lastFrame()).toBe('');
  });

  it('should show error message when error is set', () => {
    const store = createTestStore();
    store.setError('Something went wrong');
    const { lastFrame } = renderWithContext(<ErrorBar />, { store });
    expect(lastFrame()).toContain('Something went wrong');
    expect(lastFrame()).toContain('\u2717'); // cross mark
  });

  it('should show dismiss hint', () => {
    const store = createTestStore();
    store.setError('Error occurred');
    const { lastFrame } = renderWithContext(<ErrorBar />, { store });
    expect(lastFrame()).toContain('press any key to dismiss');
  });

  it('should dismiss on keypress', async () => {
    const store = createTestStore();
    store.setError('Dismissable error');
    const { lastFrame, stdin } = renderWithContext(<ErrorBar />, { store });
    expect(lastFrame()).toContain('Dismissable error');

    await delay();
    stdin.write('x');
    await delay(20);
    expect(lastFrame()).toBe('');
  });

  it('should show new error when error changes', async () => {
    const store = createTestStore();
    store.setError('First error');
    const { lastFrame } = renderWithContext(<ErrorBar />, { store });
    expect(lastFrame()).toContain('First error');

    store.setError('Second error');
    await delay(10);
    expect(lastFrame()).toContain('Second error');
  });

  it('should auto-dismiss after long timeout', async () => {
    vi.useFakeTimers();
    try {
      const store = createTestStore();
      store.setError('Auto-dismiss error');
      const { lastFrame } = renderWithContext(<ErrorBar />, { store });
      expect(lastFrame()).toContain('Auto-dismiss error');

      // Advance past the 15s timeout
      await vi.advanceTimersByTimeAsync(16000);
      expect(lastFrame()).toBe('');
    } finally {
      vi.useRealTimers();
    }
  });
});
