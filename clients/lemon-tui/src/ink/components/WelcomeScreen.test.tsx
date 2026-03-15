/**
 * Tests for the WelcomeScreen component.
 */

import React from 'react';
import { describe, it, expect } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { WelcomeScreen } from './WelcomeScreen.js';

describe('WelcomeScreen', () => {
  it('should show welcome message', () => {
    const store = createTestStore();
    const { lastFrame } = renderWithContext(<WelcomeScreen />, { store });
    expect(lastFrame()).toContain('Welcome to Lemon!');
  });

  it('should show lemon ASCII art', () => {
    const store = createTestStore();
    const { lastFrame } = renderWithContext(<WelcomeScreen />, { store });
    const frame = lastFrame();
    // Check for some distinctive lemon art characters
    expect(frame).toContain('\u2584'); // block character
  });

  it('should show cwd', () => {
    const home = process.env.HOME || '';
    const store = createTestStore({ cwd: `${home}/myproject` });
    const { lastFrame } = renderWithContext(<WelcomeScreen />, { store });
    expect(lastFrame()).toContain('~/myproject');
  });

  it('should show connecting when not ready', () => {
    const store = createTestStore();
    const { lastFrame } = renderWithContext(<WelcomeScreen />, { store });
    expect(lastFrame()).toContain('connecting...');
  });

  it('should show model when ready', () => {
    const store = createTestStore({
      ready: true,
      model: { provider: 'openai', id: 'gpt-4' },
      cwd: '/test',
    });
    const { lastFrame } = renderWithContext(<WelcomeScreen />, { store });
    expect(lastFrame()).toContain('openai:gpt-4');
  });

  it('should show session count when sessions exist', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { lastFrame } = renderWithContext(<WelcomeScreen />, { store });
    // With ready state, there's 1 session
    expect(lastFrame()).toContain('1');
    expect(lastFrame()).toContain('active');
  });

  it('should show help hint', () => {
    const store = createTestStore();
    const { lastFrame } = renderWithContext(<WelcomeScreen />, { store });
    expect(lastFrame()).toContain('/help');
  });

  it('should show keyboard shortcuts', () => {
    const store = createTestStore();
    const { lastFrame } = renderWithContext(<WelcomeScreen />, { store });
    const frame = lastFrame();
    expect(frame).toContain('Ctrl+N');
    expect(frame).toContain('Ctrl+Tab');
    expect(frame).toContain('Ctrl+O');
    expect(frame).toContain('/settings');
  });
});
