/**
 * Tests for the Loader component.
 */

import React from 'react';
import { describe, it, expect } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { Loader } from './Loader.js';

describe('Loader', () => {
  it('should render nothing when not busy', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { lastFrame } = renderWithContext(<Loader />, { store });
    expect(lastFrame()).toBe('');
  });

  it('should render spinner message when busy', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.handleEvent({ type: 'agent_start' }, 'session-1');
    const { lastFrame } = renderWithContext(<Loader />, { store });
    const frame = lastFrame();
    // Should contain a spinner frame and some message text
    expect(frame).not.toBe('');
    expect(frame).toContain('Processing...');
  });

  it('should show agentWorkingMessage when set', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.handleEvent({ type: 'agent_start' }, 'session-1');
    store.setAgentWorkingMessage('Thinking...');
    const { lastFrame } = renderWithContext(<Loader />, { store });
    expect(lastFrame()).toContain('Thinking...');
  });

  it('should show default Processing message when no specific message is set', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.handleEvent({ type: 'agent_start' }, 'session-1');
    const { lastFrame } = renderWithContext(<Loader />, { store });
    expect(lastFrame()).toContain('Processing...');
  });
});
