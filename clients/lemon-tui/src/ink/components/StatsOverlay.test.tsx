/**
 * Tests for the StatsOverlay component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { StatsOverlay } from './StatsOverlay.js';

describe('StatsOverlay', () => {
  it('should render stats title', () => {
    const store = createTestStore({ ready: true });
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(<StatsOverlay onClose={onClose} />, { store });
    expect(lastFrame()).toContain('Session Statistics');
  });

  it('should show model info', () => {
    const store = createTestStore({ ready: true, model: { provider: 'anthropic', id: 'claude-3' } });
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(<StatsOverlay onClose={onClose} />, { store });
    expect(lastFrame()).toContain('claude-3');
  });

  it('should show message counts', () => {
    const store = createTestStore({ ready: true });
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(<StatsOverlay onClose={onClose} />, { store });
    expect(lastFrame()).toContain('Messages');
    expect(lastFrame()).toContain('Total');
    expect(lastFrame()).toContain('User');
    expect(lastFrame()).toContain('Assistant');
  });

  it('should show token usage section', () => {
    const store = createTestStore({ ready: true });
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(<StatsOverlay onClose={onClose} />, { store });
    expect(lastFrame()).toContain('Token Usage');
    expect(lastFrame()).toContain('Input');
    expect(lastFrame()).toContain('Output');
    expect(lastFrame()).toContain('Cache Read');
    expect(lastFrame()).toContain('Cache Write');
    expect(lastFrame()).toContain('Total Cost');
  });

  it('should show escape hint', () => {
    const store = createTestStore({ ready: true });
    const onClose = vi.fn();
    const { lastFrame } = renderWithContext(<StatsOverlay onClose={onClose} />, { store });
    expect(lastFrame()).toContain('Escape');
  });
});
