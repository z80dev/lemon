/**
 * Tests for the ToolHint component.
 */

import React from 'react';
import { describe, it, expect } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { ToolHint } from './ToolHint.js';

describe('ToolHint', () => {
  it('should render nothing when no tool executions exist', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { lastFrame } = renderWithContext(<ToolHint collapsed={false} />, { store });
    expect(lastFrame()).toBe('');
  });

  it('should show "hide" hint when not collapsed and tools exist', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.handleEvent({ type: 'tool_execution_start', data: ['t1', 'bash', {}] }, 'session-1');
    const { lastFrame } = renderWithContext(<ToolHint collapsed={false} />, { store });
    expect(lastFrame()).toContain('Ctrl+O to hide tool output');
  });

  it('should show "show" hint when collapsed and tools exist', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.handleEvent({ type: 'tool_execution_start', data: ['t1', 'bash', {}] }, 'session-1');
    const { lastFrame } = renderWithContext(<ToolHint collapsed={true} />, { store });
    expect(lastFrame()).toContain('Ctrl+O to show tool output');
  });
});
