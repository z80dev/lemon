/**
 * Tests for the SettingsOverlay component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { SettingsOverlay } from './SettingsOverlay.js';

vi.mock('../../config.js', () => ({
  saveTUIConfigKey: vi.fn(),
}));

function delay(ms = 5) { return new Promise<void>(r => setTimeout(r, ms)); }

function renderSettings(onClose = vi.fn()) {
  const store = createTestStore({ ready: true, cwd: '/test' });
  return {
    ...renderWithContext(
      <SettingsOverlay onClose={onClose} />,
      { store, theme: 'lemon' }
    ),
    onClose,
    store,
  };
}

describe('SettingsOverlay', () => {
  it('should render Settings title', () => {
    const { lastFrame } = renderSettings();
    expect(lastFrame()).toContain('Settings');
  });

  it('should show current theme name', () => {
    const { lastFrame } = renderSettings();
    expect(lastFrame()).toContain('lemon');
  });

  it('should show Theme label', () => {
    const { lastFrame } = renderSettings();
    expect(lastFrame()).toContain('Theme');
  });

  it('should close on Escape', async () => {
    const onClose = vi.fn();
    const { stdin } = renderSettings(onClose);

    await delay();
    stdin.write('\x1B'); // Escape
    await delay();
    expect(onClose).toHaveBeenCalled();
  });

  it('should show helper text', () => {
    const { lastFrame } = renderSettings();
    expect(lastFrame()).toContain('Esc to close');
  });

  it('should cycle theme on right arrow', async () => {
    const { stdin, lastFrame } = renderSettings();

    await delay();
    stdin.write('\x1B[C'); // Right arrow
    await delay(20);
    const frame = lastFrame();
    // After pressing right arrow, theme should change from 'lemon' to the next theme ('lime')
    expect(frame).toContain('lime');
  });
});
