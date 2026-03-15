/**
 * Tests for the Header component.
 */

import React from 'react';
import { describe, it, expect, beforeEach } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';

import { Header } from './Header.js';

describe('Header', () => {
  it('should show "connecting..." when not ready', () => {
    const store = createTestStore();
    const { lastFrame } = renderWithContext(<Header />, { store });
    const frame = lastFrame();
    expect(frame).toContain('Lemon');
    expect(frame).toContain('connecting...');
  });

  it('should show model info when ready', () => {
    const store = createTestStore({
      ready: true,
      model: { provider: 'anthropic', id: 'claude-3' },
      cwd: '/test/dir',
    });
    const { lastFrame } = renderWithContext(<Header />, { store });
    const frame = lastFrame();
    expect(frame).toContain('Lemon');
    expect(frame).toContain('anthropic:claude-3');
  });

  it('should show shortened cwd with ~ for HOME', () => {
    const home = process.env.HOME || '';
    const store = createTestStore({
      ready: true,
      cwd: `${home}/projects/myapp`,
    });
    const { lastFrame } = renderWithContext(<Header />, { store });
    expect(lastFrame()).toContain('~/projects/myapp');
  });

  it('should show full path when not under HOME', () => {
    const store = createTestStore({
      ready: true,
      cwd: '/tmp/test-project',
    });
    const { lastFrame } = renderWithContext(<Header />, { store });
    expect(lastFrame()).toContain('/tmp/test-project');
  });
});
