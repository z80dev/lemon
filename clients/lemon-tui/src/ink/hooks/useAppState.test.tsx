/**
 * Tests for useAppState and useAppSelector hooks.
 */

import React from 'react';
import { describe, it, expect } from 'vitest';
import { Text } from 'ink';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { useAppState, useAppSelector } from './useAppState.js';

function StateDisplay() {
  const state = useAppState();
  return <Text>ready:{String(state.ready)}|cwd:{state.cwd}</Text>;
}

function SelectorDisplay({ selector }: { selector: (s: any) => any }) {
  const value = useAppSelector(selector);
  return <Text>value:{String(value)}</Text>;
}

describe('useAppState', () => {
  it('returns full state with default values', () => {
    const store = createTestStore({ cwd: '/test' });
    const { lastFrame } = renderWithContext(<StateDisplay />, { store });

    expect(lastFrame()).toContain('ready:false');
    expect(lastFrame()).toContain('cwd:/test');
  });

  it('returns ready state after setReady', () => {
    const store = createTestStore({ ready: true, cwd: '/workspace' });
    const { lastFrame } = renderWithContext(<StateDisplay />, { store });

    expect(lastFrame()).toContain('ready:true');
    expect(lastFrame()).toContain('cwd:/workspace');
  });
});

describe('useAppSelector', () => {
  it('returns selected value for cwd', () => {
    const store = createTestStore({ ready: true, cwd: '/my/project' });
    const { lastFrame } = renderWithContext(
      <SelectorDisplay selector={(s) => s.cwd} />,
      { store }
    );

    expect(lastFrame()).toContain('value:/my/project');
  });

  it('returns busy state', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { lastFrame } = renderWithContext(
      <SelectorDisplay selector={(s) => s.busy} />,
      { store }
    );

    expect(lastFrame()).toContain('value:false');
  });

  it('returns error state', () => {
    const store = createTestStore({ cwd: '/test' });
    store.setError('something went wrong');
    const { lastFrame } = renderWithContext(
      <SelectorDisplay selector={(s) => s.error} />,
      { store }
    );

    expect(lastFrame()).toContain('value:something went wrong');
  });
});
