/**
 * Tests for the Modeline component.
 */

import React from 'react';
import { describe, it, expect } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { Modeline } from './Modeline.js';

describe('Modeline', () => {
  it('should show cwd when no modeline entries exist', () => {
    const home = process.env.HOME || '';
    const store = createTestStore({ ready: true, cwd: `${home}/projects/app` });
    const { lastFrame } = renderWithContext(<Modeline />, { store });
    expect(lastFrame()).toContain('~/projects/app');
  });

  it('should show git status from modeline entries', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.setStatus('modeline:git', 'main +2 *');
    const { lastFrame } = renderWithContext(<Modeline />, { store });
    expect(lastFrame()).toContain('git: main +2 *');
  });

  it('should show keybinding hints when busy', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.handleEvent({ type: 'agent_start' }, 'session-1');
    const { lastFrame } = renderWithContext(<Modeline />, { store });
    const frame = lastFrame();
    expect(frame).toContain('abort');
    expect(frame).toContain('Ctrl+O');
  });

  it('should show keybinding hints when idle with session', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { lastFrame } = renderWithContext(<Modeline />, { store });
    const frame = lastFrame();
    expect(frame).toContain('Ctrl+O');
    expect(frame).toContain('/help');
  });

  it('should show new session hint when no active session', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.setActiveSessionId(null);
    const { lastFrame } = renderWithContext(<Modeline />, { store });
    expect(lastFrame()).toContain('Ctrl+N');
  });

  it('should show session tabs when multiple sessions exist', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    // Add a second session
    store.handleSessionStarted('session-2', '/test2', { provider: 'anthropic', id: 'claude-4' });
    const { lastFrame } = renderWithContext(<Modeline />, { store });
    const frame = lastFrame();
    // Session IDs are truncated to 6 chars (session-1 → sessio)
    expect(frame).toContain('sessio');
  });

  it('should show modeline key without prefix label when key is just "modeline"', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.setStatus('modeline', 'custom info');
    const { lastFrame } = renderWithContext(<Modeline />, { store });
    expect(lastFrame()).toContain('custom info');
  });

  it('should format modeline entries with labels', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.setStatus('modeline.branch', 'main');
    const { lastFrame } = renderWithContext(<Modeline />, { store });
    expect(lastFrame()).toContain('branch: main');
  });
});
