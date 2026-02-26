/**
 * Tests for process formatter.
 */

import { describe, expect, it } from 'vitest';
import { processFormatter } from './process.js';

describe('processFormatter.formatArgs', () => {
  it('shows action name in summary', () => {
    const result = processFormatter.formatArgs({
      action: 'list',
    });

    expect(result.summary).toBe('list');
  });

  it('shows action with process_id when present', () => {
    const result = processFormatter.formatArgs({
      action: 'poll',
      process_id: 'proc-123',
    });

    expect(result.summary).toBe('poll: proc-123');
  });

  it('shows action in details', () => {
    const result = processFormatter.formatArgs({
      action: 'log',
    });

    expect(result.details).toContain('action: log');
  });

  it('shows process_id in details when present', () => {
    const result = processFormatter.formatArgs({
      action: 'kill',
      process_id: 'proc-456',
    });

    expect(result.details).toContain('action: kill');
    expect(result.details).toContain('process_id: proc-456');
  });

  it('shows input in details for write action', () => {
    const result = processFormatter.formatArgs({
      action: 'write',
      process_id: 'proc-789',
      input: 'echo hello',
    });

    expect(result.details).toContain('action: write');
    expect(result.details).toContain('process_id: proc-789');
    expect(result.details).toContain('input: echo hello');
  });

  it('truncates long input', () => {
    const longInput = 'This is a very long input string that exceeds the maximum display length and should be truncated with ellipsis';
    const result = processFormatter.formatArgs({
      action: 'write',
      process_id: 'proc-001',
      input: longInput,
    });

    const inputLine = result.details.find((d) => d.startsWith('input:'));
    expect(inputLine).toBeDefined();
    expect(inputLine!.length).toBeLessThan(longInput.length + 10);
  });

  it('defaults action to list when not provided', () => {
    const result = processFormatter.formatArgs({});

    expect(result.summary).toBe('list');
    expect(result.details).toContain('action: list');
  });

  it('handles clear action', () => {
    const result = processFormatter.formatArgs({
      action: 'clear',
    });

    expect(result.summary).toBe('clear');
  });
});

describe('processFormatter.formatResult - list action', () => {
  it('shows process count in summary', () => {
    const result = processFormatter.formatResult(
      {
        processes: [
          { id: 'proc-1', status: 'running', command: 'npm test' },
          { id: 'proc-2', status: 'exited', command: 'npm build' },
        ],
      },
      { action: 'list' }
    );

    expect(result.summary).toBe('2 processes');
  });

  it('handles singular process correctly', () => {
    const result = processFormatter.formatResult(
      {
        processes: [{ id: 'proc-1', status: 'running', command: 'npm start' }],
      },
      { action: 'list' }
    );

    expect(result.summary).toBe('1 process');
  });

  it('shows table header and rows', () => {
    const result = processFormatter.formatResult(
      {
        processes: [
          { id: 'proc-1', status: 'running', command: 'npm test' },
          { id: 'proc-2', status: 'exited', command: 'npm build' },
        ],
      },
      { action: 'list' }
    );

    expect(result.details).toContain('ID       STATUS   COMMAND');
    expect(result.details.some((d) => d.includes('proc-1') && d.includes('running') && d.includes('npm test'))).toBe(true);
    expect(result.details.some((d) => d.includes('proc-2') && d.includes('exited') && d.includes('npm build'))).toBe(true);
  });

  it('handles empty process list', () => {
    const result = processFormatter.formatResult(
      { processes: [] },
      { action: 'list' }
    );

    expect(result.summary).toBe('0 processes');
    expect(result.details).toHaveLength(0);
  });

  it('handles processes without commands', () => {
    const result = processFormatter.formatResult(
      {
        processes: [
          { id: 'proc-1', status: 'running' },
        ],
      },
      { action: 'list' }
    );

    expect(result.details.some((d) => d.includes('proc-1') && d.includes('running'))).toBe(true);
  });

  it('truncates long commands', () => {
    const longCommand = 'npm run very-long-script-name-that-exceeds-the-display-width --with-many-options --and-flags';
    const result = processFormatter.formatResult(
      {
        processes: [
          { id: 'proc-1', status: 'running', command: longCommand },
        ],
      },
      { action: 'list' }
    );

    const processLine = result.details.find((d) => d.includes('proc-1'));
    expect(processLine).toBeDefined();
    expect(processLine!.length).toBeLessThan(longCommand.length + 30);
  });

  it('filters invalid process entries', () => {
    const result = processFormatter.formatResult(
      {
        processes: [
          { id: 'valid', status: 'running' },
          { id: null, status: 'running' }, // Invalid
          { status: 'running' }, // Missing id
          { id: 'also-valid', status: 'exited' },
        ],
      },
      { action: 'list' }
    );

    // Only valid processes should be counted
    expect(result.summary).toBe('2 processes');
  });

  it('handles various process statuses', () => {
    const result = processFormatter.formatResult(
      {
        processes: [
          { id: 'p1', status: 'running', command: 'server' },
          { id: 'p2', status: 'exited', command: 'build' },
          { id: 'p3', status: 'killed', command: 'test' },
        ],
      },
      { action: 'list' }
    );

    expect(result.details.some((d) => d.includes('running'))).toBe(true);
    expect(result.details.some((d) => d.includes('exited'))).toBe(true);
    expect(result.details.some((d) => d.includes('killed'))).toBe(true);
  });
});

describe('processFormatter.formatResult - poll/log action', () => {
  it('shows process_id and line count in summary', () => {
    const result = processFormatter.formatResult(
      {
        process_id: 'proc-123',
        output: [
          { stream: 'stdout', text: 'Line 1' },
          { stream: 'stdout', text: 'Line 2' },
          { stream: 'stderr', text: 'Error line' },
        ],
        line_count: 3,
      },
      { action: 'poll', process_id: 'proc-123' }
    );

    expect(result.summary).toBe('proc-123: 3 lines');
  });

  it('handles singular line correctly', () => {
    const result = processFormatter.formatResult(
      {
        process_id: 'proc-456',
        output: [{ stream: 'stdout', text: 'Single line' }],
        line_count: 1,
      },
      { action: 'poll', process_id: 'proc-456' }
    );

    expect(result.summary).toBe('proc-456: 1 line');
  });

  it('shows output lines with stream tags', () => {
    const result = processFormatter.formatResult(
      {
        output: [
          { stream: 'stdout', text: 'Output message' },
          { stream: 'stderr', text: 'Error message' },
        ],
      },
      { action: 'poll', process_id: 'proc-789' }
    );

    expect(result.details).toContain('[stdout] Output message');
    expect(result.details).toContain('[stderr] Error message');
  });

  it('handles log action same as poll', () => {
    const result = processFormatter.formatResult(
      {
        process_id: 'proc-abc',
        output: [
          { stream: 'stdout', text: 'Log entry 1' },
          { stream: 'stdout', text: 'Log entry 2' },
        ],
      },
      { action: 'log', process_id: 'proc-abc' }
    );

    expect(result.summary).toBe('proc-abc: 2 lines');
    expect(result.details).toContain('[stdout] Log entry 1');
    expect(result.details).toContain('[stdout] Log entry 2');
  });

  it('gets process_id from result when not in args', () => {
    const result = processFormatter.formatResult(
      {
        process_id: 'from-result',
        output: [{ stream: 'stdout', text: 'test' }],
        line_count: 1,
      },
      { action: 'poll' }
    );

    expect(result.summary).toBe('from-result: 1 line');
  });

  it('handles lines array format', () => {
    const result = processFormatter.formatResult(
      {
        lines: [
          { stream: 'stdout', text: 'Line from lines array' },
        ],
      },
      { action: 'poll', process_id: 'proc-xyz' }
    );

    expect(result.details).toContain('[stdout] Line from lines array');
  });

  it('handles string lines in lines array', () => {
    const result = processFormatter.formatResult(
      {
        lines: ['Plain string line 1', 'Plain string line 2'],
      },
      { action: 'poll', process_id: 'proc-str' }
    );

    expect(result.details).toContain('[stdout] Plain string line 1');
    expect(result.details).toContain('[stdout] Plain string line 2');
  });

  it('handles string output format', () => {
    const result = processFormatter.formatResult(
      {
        output: 'Single line output\nSecond line\nThird line',
      },
      { action: 'log', process_id: 'proc-out' }
    );

    expect(result.details).toContain('[stdout] Single line output');
    expect(result.details).toContain('[stdout] Second line');
  });

  it('uses line_count from result when available', () => {
    const result = processFormatter.formatResult(
      {
        output: [{ stream: 'stdout', text: 'Visible line' }],
        line_count: 100, // More than visible
      },
      { action: 'poll', process_id: 'proc-count' }
    );

    expect(result.summary).toBe('proc-count: 100 lines');
  });

  it('falls back to parsed line count', () => {
    const result = processFormatter.formatResult(
      {
        output: [
          { stream: 'stdout', text: 'Line 1' },
          { stream: 'stdout', text: 'Line 2' },
        ],
      },
      { action: 'poll', process_id: 'proc-no-count' }
    );

    expect(result.summary).toBe('proc-no-count: 2 lines');
  });

  it('handles missing process_id', () => {
    const result = processFormatter.formatResult(
      {
        output: [{ stream: 'stdout', text: 'Anonymous output' }],
        line_count: 1,
      },
      { action: 'poll' }
    );

    expect(result.summary).toBe('1 line');
  });

  it('truncates many output lines', () => {
    const manyLines = Array.from({ length: 25 }, (_, i) => ({
      stream: 'stdout' as const,
      text: `Line ${i + 1}`,
    }));

    const result = processFormatter.formatResult(
      { output: manyLines },
      { action: 'poll', process_id: 'proc-many' }
    );

    expect(result.details.length).toBeLessThanOrEqual(16); // 15 + "more" indicator
  });
});

describe('processFormatter.formatResult - other actions', () => {
  it('shows status confirmation for write action', () => {
    const result = processFormatter.formatResult(
      {
        process_id: 'proc-write',
        status: 'written',
      },
      { action: 'write', process_id: 'proc-write' }
    );

    expect(result.summary).toBe('proc-write: written');
    expect(result.details).toHaveLength(0);
  });

  it('shows status confirmation for kill action', () => {
    const result = processFormatter.formatResult(
      {
        process_id: 'proc-kill',
        status: 'killed',
      },
      { action: 'kill', process_id: 'proc-kill' }
    );

    expect(result.summary).toBe('proc-kill: killed');
  });

  it('shows status confirmation for clear action', () => {
    const result = processFormatter.formatResult(
      {
        status: 'cleared',
      },
      { action: 'clear' }
    );

    expect(result.summary).toBe('cleared');
  });

  it('defaults status to completed', () => {
    const result = processFormatter.formatResult(
      {},
      { action: 'kill', process_id: 'proc-default' }
    );

    expect(result.summary).toBe('proc-default: completed');
  });

  it('gets process_id from result for other actions', () => {
    const result = processFormatter.formatResult(
      {
        process_id: 'from-result-id',
        status: 'success',
      },
      { action: 'write' }
    );

    expect(result.summary).toBe('from-result-id: success');
  });
});

describe('processFormatter edge cases', () => {
  it('handles null result', () => {
    const result = processFormatter.formatResult(null, { action: 'list' });

    expect(result.summary).toBe('0 processes');
  });

  it('handles non-object result', () => {
    const result = processFormatter.formatResult('not an object', { action: 'list' });

    expect(result.summary).toBe('0 processes');
  });

  it('handles missing args', () => {
    const result = processFormatter.formatResult({
      processes: [{ id: 'p1', status: 'running' }],
    });

    // Should default to list action
    expect(result.summary).toBe('1 process');
  });

  it('handles undefined action in args', () => {
    const result = processFormatter.formatResult(
      { processes: [] },
      { action: undefined as unknown as string }
    );

    expect(result.summary).toBe('0 processes');
  });
});

describe('processFormatter metadata', () => {
  it('includes process in tools array', () => {
    expect(processFormatter.tools).toContain('process');
  });
});

describe('realistic scenarios', () => {
  it('formats process list showing multiple background jobs', () => {
    const result = processFormatter.formatResult(
      {
        processes: [
          { id: 'web-server', status: 'running', command: 'npm run dev' },
          { id: 'db-service', status: 'running', command: 'docker compose up db' },
          { id: 'build-job', status: 'exited', command: 'npm run build' },
          { id: 'test-run', status: 'killed', command: 'npm test -- --watch' },
        ],
      },
      { action: 'list' }
    );

    expect(result.summary).toBe('4 processes');
    expect(result.details).toContain('ID       STATUS   COMMAND');
    expect(result.details.some((d) => d.includes('web-server') && d.includes('running'))).toBe(true);
    expect(result.details.some((d) => d.includes('build-job') && d.includes('exited'))).toBe(true);
  });

  it('formats polling output from a running test process', () => {
    const result = processFormatter.formatResult(
      {
        process_id: 'test-runner',
        output: [
          { stream: 'stdout', text: 'PASS src/utils.test.ts' },
          { stream: 'stdout', text: 'PASS src/index.test.ts' },
          { stream: 'stderr', text: 'WARN: Deprecated API usage' },
          { stream: 'stdout', text: '' },
          { stream: 'stdout', text: 'Test Suites: 2 passed, 2 total' },
          { stream: 'stdout', text: 'Tests:       10 passed, 10 total' },
        ],
        line_count: 6,
      },
      { action: 'poll', process_id: 'test-runner' }
    );

    expect(result.summary).toBe('test-runner: 6 lines');
    expect(result.details).toContain('[stdout] PASS src/utils.test.ts');
    expect(result.details).toContain('[stderr] WARN: Deprecated API usage');
    expect(result.details).toContain('[stdout] Test Suites: 2 passed, 2 total');
  });

  it('formats process kill confirmation', () => {
    const argsResult = processFormatter.formatArgs({
      action: 'kill',
      process_id: 'runaway-process',
    });

    expect(argsResult.summary).toBe('kill: runaway-process');

    const killResult = processFormatter.formatResult(
      {
        process_id: 'runaway-process',
        status: 'killed',
      },
      { action: 'kill', process_id: 'runaway-process' }
    );

    expect(killResult.summary).toBe('runaway-process: killed');
  });

  it('formats writing input to an interactive process', () => {
    const argsResult = processFormatter.formatArgs({
      action: 'write',
      process_id: 'repl-session',
      input: 'console.log("Hello, World!")',
    });

    expect(argsResult.summary).toBe('write: repl-session');
    expect(argsResult.details).toContain('input: console.log("Hello, World!")');

    const writeResult = processFormatter.formatResult(
      {
        process_id: 'repl-session',
        status: 'written',
      },
      { action: 'write', process_id: 'repl-session' }
    );

    expect(writeResult.summary).toBe('repl-session: written');
  });

  it('formats log retrieval from a completed build', () => {
    const result = processFormatter.formatResult(
      {
        process_id: 'build-123',
        output: [
          { stream: 'stdout', text: '> Building production bundle...' },
          { stream: 'stdout', text: '> Compiling TypeScript...' },
          { stream: 'stdout', text: '> Bundling with esbuild...' },
          { stream: 'stderr', text: 'Warning: Large bundle size detected' },
          { stream: 'stdout', text: '> Build completed in 4.2s' },
        ],
        line_count: 5,
      },
      { action: 'log', process_id: 'build-123' }
    );

    expect(result.summary).toBe('build-123: 5 lines');
    expect(result.details).toContain('[stdout] > Building production bundle...');
    expect(result.details).toContain('[stderr] Warning: Large bundle size detected');
    expect(result.details).toContain('[stdout] > Build completed in 4.2s');
  });
});
