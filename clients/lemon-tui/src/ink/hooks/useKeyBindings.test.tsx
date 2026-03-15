/**
 * Tests for useKeyBindings hook.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { Text } from 'ink';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { useKeyBindings } from './useKeyBindings.js';

function delay(ms = 5) {
  return new Promise<void>((r) => setTimeout(r, ms));
}

function KeyBindingTester(props: Parameters<typeof useKeyBindings>[0]) {
  useKeyBindings(props);
  return <Text>ready</Text>;
}

describe('useKeyBindings', () => {
  function setup(overrides?: Partial<Parameters<typeof useKeyBindings>[0]>) {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const options = {
      onNewSession: vi.fn(),
      onCycleSession: vi.fn(),
      onToggleToolPanel: vi.fn(),
      onQuit: vi.fn(),
      overlayActive: false,
      editorFocused: false,
      ...overrides,
    };
    const result = renderWithContext(<KeyBindingTester {...options} />, { store });
    return { ...result, options };
  }

  it('Ctrl+N triggers onNewSession', async () => {
    const { stdin, options } = setup();
    await delay();
    stdin.write('\x0E');
    await delay();

    expect(options.onNewSession).toHaveBeenCalled();
  });

  it('Ctrl+O triggers onToggleToolPanel', async () => {
    const { stdin, options } = setup();
    await delay();
    stdin.write('\x0F');
    await delay();

    expect(options.onToggleToolPanel).toHaveBeenCalled();
  });

  it('does not trigger when overlayActive is true', async () => {
    const { stdin, options } = setup({ overlayActive: true });
    await delay();
    stdin.write('\x0E');
    await delay();
    stdin.write('\x0F');
    await delay();

    expect(options.onNewSession).not.toHaveBeenCalled();
    expect(options.onToggleToolPanel).not.toHaveBeenCalled();
  });
});
