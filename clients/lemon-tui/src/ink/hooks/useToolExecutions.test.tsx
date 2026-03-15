/**
 * Tests for useToolExecutions and useActiveToolExecutions hooks.
 */

import React from 'react';
import { describe, it, expect } from 'vitest';
import { Text } from 'ink';
import { renderWithContext, createTestStore } from '../test-helpers.js';
import { useToolExecutions, useActiveToolExecutions } from './useToolExecutions.js';

function ToolExecutionsDisplay() {
  const toolExecutions = useToolExecutions();
  return <Text>size:{toolExecutions.size}</Text>;
}

function ActiveToolsDisplay() {
  const activeTools = useActiveToolExecutions();
  return (
    <Text>
      active:{activeTools.length}|names:{activeTools.map((t) => t.name).join(',')}
    </Text>
  );
}

describe('useToolExecutions', () => {
  it('returns empty map initially', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    const { lastFrame } = renderWithContext(<ToolExecutionsDisplay />, { store });

    expect(lastFrame()).toContain('size:0');
  });

  it('returns tools after tool_execution_start event', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.handleEvent(
      { type: 'tool_execution_start', data: ['tool-1', 'read_file', { path: '/tmp/a.txt' }] },
      'session-1'
    );
    const { lastFrame } = renderWithContext(<ToolExecutionsDisplay />, { store });

    expect(lastFrame()).toContain('size:1');
  });
});

describe('useActiveToolExecutions', () => {
  it('returns only running tools (no endTime)', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.handleEvent(
      { type: 'tool_execution_start', data: ['tool-1', 'read_file', { path: '/a.txt' }] },
      'session-1'
    );
    store.handleEvent(
      { type: 'tool_execution_start', data: ['tool-2', 'write_file', { path: '/b.txt' }] },
      'session-1'
    );
    const { lastFrame } = renderWithContext(<ActiveToolsDisplay />, { store });

    expect(lastFrame()).toContain('active:2');
    expect(lastFrame()).toContain('read_file');
    expect(lastFrame()).toContain('write_file');
  });

  it('excludes completed tools', () => {
    const store = createTestStore({ ready: true, cwd: '/test' });
    store.handleEvent(
      { type: 'tool_execution_start', data: ['tool-1', 'read_file', { path: '/a.txt' }] },
      'session-1'
    );
    store.handleEvent(
      { type: 'tool_execution_start', data: ['tool-2', 'write_file', { path: '/b.txt' }] },
      'session-1'
    );
    // Complete tool-1
    store.handleEvent(
      { type: 'tool_execution_end', data: ['tool-1', 'read_file', 'file contents', false] },
      'session-1'
    );
    const { lastFrame } = renderWithContext(<ActiveToolsDisplay />, { store });

    expect(lastFrame()).toContain('active:1');
    expect(lastFrame()).toContain('write_file');
    expect(lastFrame()).not.toContain('read_file');
  });
});
