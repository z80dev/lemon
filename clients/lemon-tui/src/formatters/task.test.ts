/**
 * Tests for task formatter.
 */

import { describe, expect, it } from 'vitest';
import { taskFormatter } from './task.js';

describe('taskFormatter.formatArgs', () => {
  it('shows action with prompt preview in summary', () => {
    const result = taskFormatter.formatArgs({
      action: 'run',
      prompt: 'Analyze the codebase and find all security vulnerabilities',
    });

    expect(result.summary).toContain('run:');
    expect(result.summary).toContain('Analyze the codebase');
  });

  it('shows just action when no prompt', () => {
    const result = taskFormatter.formatArgs({
      action: 'poll',
    });

    expect(result.summary).toBe('poll');
  });

  it('truncates long prompts in summary', () => {
    const longPrompt = 'This is a very long prompt that exceeds the maximum length for display in the summary line and should be truncated with an ellipsis';
    const result = taskFormatter.formatArgs({
      action: 'run',
      prompt: longPrompt,
    });

    expect(result.summary.length).toBeLessThanOrEqual(70);
    expect(result.summary).toContain('...');
  });

  it('uses description when prompt is not provided', () => {
    const result = taskFormatter.formatArgs({
      action: 'run',
      description: 'Run integration tests',
    });

    expect(result.summary).toContain('Run integration tests');
  });

  it('shows task_id in details when present', () => {
    const result = taskFormatter.formatArgs({
      action: 'poll',
      task_id: 'task-123-abc',
    });

    expect(result.details).toContain('action: poll');
    expect(result.details).toContain('task_id: task-123-abc');
  });

  it('shows full prompt in details', () => {
    const prompt = 'First line\nSecond line\nThird line';
    const result = taskFormatter.formatArgs({
      action: 'run',
      prompt,
    });

    expect(result.details).toContain('action: run');
    expect(result.details).toContain('First line');
    expect(result.details).toContain('Second line');
  });

  it('defaults action to run when not provided', () => {
    const result = taskFormatter.formatArgs({});

    expect(result.summary).toBe('run');
    expect(result.details).toContain('action: run');
  });

  it('handles join action', () => {
    const result = taskFormatter.formatArgs({
      action: 'join',
      task_id: 'task-456',
    });

    expect(result.summary).toBe('join');
    expect(result.details).toContain('action: join');
    expect(result.details).toContain('task_id: task-456');
  });

  it('collapses whitespace in prompt preview', () => {
    const result = taskFormatter.formatArgs({
      action: 'run',
      prompt: 'Multiple\n\n\nline   breaks   and    spaces',
    });

    expect(result.summary).toContain('Multiple line breaks and spaces');
  });

  it('truncates prompt lines in details', () => {
    const manyLines = Array.from({ length: 20 }, (_, i) => `Line ${i + 1}`).join('\n');
    const result = taskFormatter.formatArgs({
      action: 'run',
      prompt: manyLines,
    });

    // Details should be truncated
    expect(result.details.length).toBeLessThanOrEqual(15);
  });
});

describe('taskFormatter.formatResult', () => {
  it('shows engine and action title in summary', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude-3-opus',
        current_action: {
          title: 'Analyzing code',
        },
      },
    });

    expect(result.summary).toBe('claude-3-opus: Analyzing code');
  });

  it('shows engine info in details', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'gpt-4',
        current_action: { title: 'Processing' },
      },
    });

    expect(result.details).toContain('engine: gpt-4');
  });

  it('shows status when present', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude',
        status: 'running',
        current_action: { title: 'Working' },
      },
    });

    expect(result.details).toContain('status: running');
  });

  it('shows started phase indicator', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude',
        current_action: {
          title: 'Reading files',
          phase: 'started',
        },
      },
    });

    expect(result.details).toContain('\u25b6 Reading files...');
  });

  it('shows completed phase indicator', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude',
        current_action: {
          title: 'Analysis complete',
          phase: 'completed',
        },
      },
    });

    expect(result.details).toContain('\u2713 Analysis complete');
    // Should not have trailing "..." for completed
    expect(result.details).not.toContain('\u2713 Analysis complete...');
  });

  it('defaults to started indicator for unknown phase', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude',
        current_action: {
          title: 'Working',
          phase: 'unknown',
        },
      },
    });

    expect(result.details).toContain('\u25b6 Working...');
  });

  it('uses kind as fallback for title', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude',
        current_action: {
          kind: 'tool_use',
          phase: 'started',
        },
      },
    });

    expect(result.summary).toContain('tool_use');
    expect(result.details).toContain('\u25b6 tool_use...');
  });

  it('shows nested tool information', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude',
        current_action: {
          title: 'Executing tool',
          phase: 'started',
          tool: 'bash',
          tool_input: { command: 'npm test' },
        },
      },
    });

    expect(result.details.some((d) => d.includes('\u2514\u2500 bash: npm test'))).toBe(true);
  });

  it('truncates long tool input preview', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude',
        current_action: {
          title: 'Running',
          tool: 'bash',
          tool_input: {
            command: 'this is a very long command that should be truncated for display purposes',
          },
        },
      },
    });

    const toolLine = result.details.find((d) => d.includes('\u2514\u2500'));
    expect(toolLine).toBeDefined();
    expect(toolLine!.length).toBeLessThan(70);
  });

  it('handles result with no details', () => {
    const result = taskFormatter.formatResult({});

    expect(result.summary).toBe('completed');
    expect(result.details).toHaveLength(0);
  });

  it('handles result with null details', () => {
    const result = taskFormatter.formatResult({ details: null });

    expect(result.summary).toBe('completed');
  });

  it('defaults engine to unknown', () => {
    const result = taskFormatter.formatResult({
      details: {
        current_action: { title: 'Working' },
      },
    });

    expect(result.summary).toContain('unknown:');
    expect(result.details).toContain('engine: unknown');
  });

  it('defaults action title to idle', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude',
      },
    });

    expect(result.summary).toBe('claude: idle');
  });

  it('shows output when present', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude',
        current_action: { title: 'Done' },
        output: 'Task completed successfully\nAll tests passed',
      },
    });

    expect(result.details).toContain('Task completed successfully');
    expect(result.details).toContain('All tests passed');
  });

  it('parses details from content blocks', () => {
    const result = taskFormatter.formatResult({
      content: [
        {
          type: 'text',
          text: JSON.stringify({
            details: {
              engine: 'from-content',
              current_action: { title: 'Parsed' },
            },
          }),
        },
      ],
    });

    expect(result.summary).toBe('from-content: Parsed');
  });

  it('handles non-object tool_input', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude',
        current_action: {
          title: 'Running',
          tool: 'echo',
          tool_input: 'not an object',
        },
      },
    });

    // Should still show tool but without input preview
    expect(result.details.some((d) => d.includes('\u2514\u2500 echo'))).toBe(true);
  });

  it('handles tool without input', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude',
        current_action: {
          title: 'Running',
          tool: 'list_files',
        },
      },
    });

    expect(result.details.some((d) => d.includes('\u2514\u2500 list_files'))).toBe(true);
  });

  it('skips nested tool display when no tool specified', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude',
        current_action: {
          title: 'Thinking',
        },
      },
    });

    const hasToolLine = result.details.some((d) => d.includes('\u2514\u2500'));
    expect(hasToolLine).toBe(false);
  });
});

describe('taskFormatter.formatPartial', () => {
  it('uses same logic as formatResult', () => {
    const partialResult = taskFormatter.formatPartial!({
      details: {
        engine: 'claude',
        current_action: {
          title: 'Processing',
          phase: 'started',
        },
      },
    });

    const fullResult = taskFormatter.formatResult({
      details: {
        engine: 'claude',
        current_action: {
          title: 'Processing',
          phase: 'started',
        },
      },
    });

    expect(partialResult.summary).toBe(fullResult.summary);
    expect(partialResult.details).toEqual(fullResult.details);
  });

  it('handles streaming updates', () => {
    const result = taskFormatter.formatPartial!({
      details: {
        engine: 'claude',
        current_action: {
          title: 'Writing code',
          phase: 'started',
          tool: 'write',
          tool_input: { path: '/src/index.ts' },
        },
      },
    });

    expect(result.summary).toBe('claude: Writing code');
    expect(result.details.some((d) => d.includes('\u25b6 Writing code...'))).toBe(true);
    expect(result.details.some((d) => d.includes('\u2514\u2500 write: /src/index.ts'))).toBe(true);
  });
});

describe('taskFormatter metadata', () => {
  it('includes task in tools array', () => {
    expect(taskFormatter.tools).toContain('task');
  });

  it('has formatPartial method', () => {
    expect(taskFormatter.formatPartial).toBeDefined();
    expect(typeof taskFormatter.formatPartial).toBe('function');
  });
});

describe('realistic scenarios', () => {
  it('formats a code analysis task start', () => {
    const argsResult = taskFormatter.formatArgs({
      action: 'run',
      prompt: 'Analyze the authentication module for security vulnerabilities and suggest improvements',
    });

    expect(argsResult.summary).toContain('run:');
    expect(argsResult.summary).toContain('Analyze the authentication');
  });

  it('formats an in-progress task with tool execution', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude-3-opus',
        status: 'running',
        current_action: {
          title: 'Reading source files',
          kind: 'tool_use',
          phase: 'started',
          tool: 'read_file',
          tool_input: { path: '/src/auth/login.ts' },
        },
      },
    });

    expect(result.summary).toBe('claude-3-opus: Reading source files');
    expect(result.details.some((d) => d.includes('engine: claude-3-opus'))).toBe(true);
    expect(result.details.some((d) => d.includes('status: running'))).toBe(true);
    expect(result.details.some((d) => d.includes('\u25b6 Reading source files...'))).toBe(true);
    expect(result.details.some((d) => d.includes('\u2514\u2500 read_file: /src/auth/login.ts'))).toBe(true);
  });

  it('formats a completed task', () => {
    const result = taskFormatter.formatResult({
      details: {
        engine: 'claude-3-opus',
        status: 'completed',
        current_action: {
          title: 'Analysis complete',
          phase: 'completed',
        },
        output: 'Found 3 potential security issues:\n1. SQL injection vulnerability\n2. Missing input validation\n3. Hardcoded credentials',
      },
    });

    expect(result.summary).toBe('claude-3-opus: Analysis complete');
    expect(result.details).toContain('\u2713 Analysis complete');
    expect(result.details).toContain('Found 3 potential security issues:');
  });

  it('formats a poll action for an existing task', () => {
    const argsResult = taskFormatter.formatArgs({
      action: 'poll',
      task_id: 'task-a1b2c3',
    });

    expect(argsResult.summary).toBe('poll');
    expect(argsResult.details).toContain('action: poll');
    expect(argsResult.details).toContain('task_id: task-a1b2c3');
  });

  it('formats a join action waiting for task completion', () => {
    const argsResult = taskFormatter.formatArgs({
      action: 'join',
      task_id: 'task-xyz789',
    });

    expect(argsResult.summary).toBe('join');
    expect(argsResult.details).toContain('action: join');
    expect(argsResult.details).toContain('task_id: task-xyz789');
  });
});
