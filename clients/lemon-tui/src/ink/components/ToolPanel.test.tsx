/**
 * Tests for the ToolPanel component.
 */

import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { ToolPanel } from './ToolPanel.js';

function startToolExecution(store: ReturnType<typeof createTestStore>, id: string, name: string, args: Record<string, unknown> = {}) {
  store.handleEvent({
    type: 'tool_execution_start',
    data: [id, name, args],
  }, 'session-1');
}

function endToolExecution(store: ReturnType<typeof createTestStore>, id: string, name: string, result: unknown, isError = false) {
  store.handleEvent({
    type: 'tool_execution_end',
    data: [id, name, result, isError],
  }, 'session-1');
}

describe('ToolPanel', () => {
  it('should render nothing when there are no tool executions', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { lastFrame } = renderWithContext(
      <ToolPanel collapsed={false} />,
      { store }
    );
    expect(lastFrame()).toBe('');
  });

  it('should render nothing when collapsed', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    startToolExecution(store, 'tool-1', 'bash', { command: 'ls' });

    const { lastFrame } = renderWithContext(
      <ToolPanel collapsed={true} />,
      { store }
    );
    expect(lastFrame()).toBe('');
  });

  it('should show running tool with spinner', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    startToolExecution(store, 'tool-1', 'bash', { command: 'ls -la' });

    const { lastFrame } = renderWithContext(
      <ToolPanel collapsed={false} />,
      { store }
    );
    const frame = lastFrame();
    expect(frame).toContain('tools');
    expect(frame).toContain('bash');
  });

  it('should show completed tool with checkmark', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    startToolExecution(store, 'tool-1', 'read', { file_path: '/test/file.ts' });
    endToolExecution(store, 'tool-1', 'read', 'file contents here');

    const { lastFrame } = renderWithContext(
      <ToolPanel collapsed={false} />,
      { store }
    );
    const frame = lastFrame();
    expect(frame).toContain('read');
    expect(frame).toContain('\u2713'); // checkmark
  });

  it('should show failed tool with error mark', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    startToolExecution(store, 'tool-1', 'bash', { command: 'invalid-cmd' });
    endToolExecution(store, 'tool-1', 'bash', 'command not found', true);

    const { lastFrame } = renderWithContext(
      <ToolPanel collapsed={false} />,
      { store }
    );
    const frame = lastFrame();
    expect(frame).toContain('bash');
    expect(frame).toContain('\u2717'); // X mark
  });

  it('should show at most 8 tools (newest first)', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    let now = 1000;
    vi.spyOn(Date, 'now').mockImplementation(() => now);
    for (let i = 0; i < 10; i++) {
      now += 1000;
      startToolExecution(store, `tool-${i}`, `tool${i}`, {});
    }
    vi.restoreAllMocks();

    const { lastFrame } = renderWithContext(
      <ToolPanel collapsed={false} />,
      { store }
    );
    const frame = lastFrame();
    // Should show tool9..tool2 (newest 8)
    expect(frame).toContain('tool9');
    expect(frame).toContain('tool8');
    expect(frame).toContain('tool3');
    expect(frame).toContain('tool2');
    // tool0 and tool1 should be cut off
    expect(frame).not.toContain('tool0');
    expect(frame).not.toContain('tool1');
  });

  it('should show task tool with engine info', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.handleEvent({
      type: 'tool_execution_start',
      data: ['task-1', 'task', { engine: 'bash' }],
    }, 'session-1');
    // Update with partial result that includes task details
    store.handleEvent({
      type: 'tool_execution_update',
      data: ['task-1', 'task', { engine: 'bash' }, {
        details: { engine: 'bash', current_action: { title: 'Running tests', kind: 'exec', phase: 'started' } },
      }],
    }, 'session-1');

    const { lastFrame } = renderWithContext(
      <ToolPanel collapsed={false} />,
      { store }
    );
    const frame = lastFrame();
    expect(frame).toContain('task');
    expect(frame).toContain('bash');
  });

  it('should show tool borders', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    startToolExecution(store, 'tool-1', 'grep', { pattern: 'foo' });

    const { lastFrame } = renderWithContext(
      <ToolPanel collapsed={false} />,
      { store }
    );
    const frame = lastFrame();
    expect(frame).toContain('\u250C'); // top-left corner
    expect(frame).toContain('\u2514'); // bottom-left corner
  });
});
