/**
 * Tests for the ToolExecutionBar component.
 */

import React from 'react';
import { describe, it, expect } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { ToolExecutionBar } from './ToolExecutionBar.js';

function startTool(store: ReturnType<typeof createTestStore>, id: string, name: string) {
  store.handleEvent({ type: 'tool_execution_start', data: [id, name, {}] }, 'session-1');
}

function endTool(store: ReturnType<typeof createTestStore>, id: string, name: string) {
  store.handleEvent({ type: 'tool_execution_end', data: [id, name, 'done', false] }, 'session-1');
}

describe('ToolExecutionBar', () => {
  it('should render nothing when no active tools', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { lastFrame } = renderWithContext(<ToolExecutionBar />, { store });
    expect(lastFrame()).toBe('');
  });

  it('should render nothing when all tools are completed', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    startTool(store, 't1', 'bash');
    endTool(store, 't1', 'bash');
    const { lastFrame } = renderWithContext(<ToolExecutionBar />, { store });
    expect(lastFrame()).toBe('');
  });

  it('should show active tool name', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    startTool(store, 't1', 'bash');
    const { lastFrame } = renderWithContext(<ToolExecutionBar />, { store });
    expect(lastFrame()).toContain('bash');
  });

  it('should show multiple active tools', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    startTool(store, 't1', 'bash');
    startTool(store, 't2', 'read');
    const { lastFrame } = renderWithContext(<ToolExecutionBar />, { store });
    const frame = lastFrame();
    expect(frame).toContain('bash');
    expect(frame).toContain('read');
  });

  it('should show elapsed time for active tools', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    startTool(store, 't1', 'grep');
    const { lastFrame } = renderWithContext(<ToolExecutionBar />, { store });
    const frame = lastFrame();
    // Should show some duration like "0.0s" or similar
    expect(frame).toContain('s');
  });

  it('should show spinner character', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    startTool(store, 't1', 'bash');
    const { lastFrame } = renderWithContext(<ToolExecutionBar />, { store });
    const frame = lastFrame();
    // Should contain one of the braille spinner frames
    const spinnerFrames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    const hasSpinner = spinnerFrames.some((f) => frame!.includes(f));
    expect(hasSpinner).toBe(true);
  });
});
