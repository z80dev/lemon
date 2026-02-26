/**
 * Tests for the bash formatter.
 */

import { describe, it, expect } from 'vitest';
import { bashFormatter } from './bash.js';

describe('bashFormatter', () => {
  describe('tools property', () => {
    it('should contain bash', () => {
      expect(bashFormatter.tools).toContain('bash');
    });

    it('should contain exec', () => {
      expect(bashFormatter.tools).toContain('exec');
    });

    it('should only contain bash and exec', () => {
      expect(bashFormatter.tools).toHaveLength(2);
    });
  });

  describe('formatArgs', () => {
    it('should show simple command in summary', () => {
      const result = bashFormatter.formatArgs({ command: 'ls -la' });

      expect(result.summary).toBe('ls -la');
      expect(result.details).toContain('ls -la');
    });

    it('should truncate long commands in summary', () => {
      const longCommand =
        'npm install --save-dev typescript eslint prettier jest vitest @types/node @types/react some-very-long-package-name another-package';
      const result = bashFormatter.formatArgs({ command: longCommand });

      // Summary should be truncated to 80 chars with "..."
      expect(result.summary.length).toBeLessThanOrEqual(80);
      expect(result.summary).toMatch(/\.\.\.$/);
      // Details should contain full command
      expect(result.details[0]).toBe(longCommand);
    });

    it('should show timeout in details when provided', () => {
      const result = bashFormatter.formatArgs({
        command: 'sleep 30',
        timeout: 60000,
      });

      expect(result.summary).toBe('sleep 30');
      expect(result.details).toContain('timeout: 60000ms');
    });

    it('should show cwd in details when provided', () => {
      const result = bashFormatter.formatArgs({
        command: 'npm install',
        cwd: '/home/user/project',
      });

      expect(result.summary).toBe('npm install');
      expect(result.details).toContain('cwd: /home/user/project');
    });

    it('should show both timeout and cwd when provided', () => {
      const result = bashFormatter.formatArgs({
        command: 'npm test',
        timeout: 120000,
        cwd: '/home/user/project',
      });

      expect(result.details).toContain('npm test');
      expect(result.details).toContain('timeout: 120000ms');
      expect(result.details).toContain('cwd: /home/user/project');
    });

    it('should handle empty command gracefully', () => {
      const result = bashFormatter.formatArgs({ command: '' });

      expect(result.summary).toBe('');
      expect(result.details).toContain('');
    });

    it('should handle missing command gracefully', () => {
      const result = bashFormatter.formatArgs({});

      expect(result.summary).toBe('');
    });

    it('should handle command with newlines', () => {
      const result = bashFormatter.formatArgs({
        command: 'echo "line1"\necho "line2"',
      });

      expect(result.summary).toContain('echo "line1"');
      expect(result.details[0]).toBe('echo "line1"\necho "line2"');
    });

    it('should handle command with special characters', () => {
      const result = bashFormatter.formatArgs({
        command: 'git log --oneline | head -10 && echo "done"',
      });

      expect(result.summary).toBe('git log --oneline | head -10 && echo "done"');
    });
  });

  describe('formatResult - success cases', () => {
    it('should show [0] badge and Success status for exit code 0', () => {
      const result = bashFormatter.formatResult({
        details: { exit_code: 0, stdout: 'output' },
      });

      expect(result.summary).toMatch(/^\[0\]/);
      expect(result.details[0]).toBe('[0] Success');
      expect(result.isError).toBe(false);
    });

    it('should treat string result as stdout', () => {
      const result = bashFormatter.formatResult('file1.txt\nfile2.txt\nfile3.txt');

      expect(result.summary).toMatch(/^\[0\]/);
      expect(result.summary).toContain('file1.txt');
      expect(result.isError).toBe(false);
    });

    it('should extract text from content blocks', () => {
      const result = bashFormatter.formatResult({
        content: [{ type: 'text', text: 'Hello from content block' }],
      });

      expect(result.summary).toContain('Hello from content block');
      expect(result.isError).toBe(false);
    });

    it('should show stdout from details.stdout', () => {
      const result = bashFormatter.formatResult({
        details: {
          exit_code: 0,
          stdout: 'Line 1\nLine 2\nLine 3',
        },
      });

      expect(result.details).toContain('Line 1');
      expect(result.details).toContain('Line 2');
      expect(result.details).toContain('Line 3');
    });

    it('should properly format multiple lines', () => {
      const stdout = 'README.md\npackage.json\nsrc/\ntest/\nnode_modules/';
      const result = bashFormatter.formatResult({
        details: { exit_code: 0, stdout },
      });

      // First line is status, then output lines
      expect(result.details[0]).toBe('[0] Success');
      expect(result.details.slice(1)).toContain('README.md');
      expect(result.details.slice(1)).toContain('package.json');
    });

    it('should show first non-empty line in summary', () => {
      const result = bashFormatter.formatResult({
        details: {
          exit_code: 0,
          stdout: '\n\nActual output here\nMore output',
        },
      });

      expect(result.summary).toContain('Actual output here');
    });
  });

  describe('formatResult - error cases', () => {
    it('should show non-zero exit code badge and Failed status', () => {
      const result = bashFormatter.formatResult({
        details: {
          exit_code: 1,
          stderr: 'Command failed',
        },
      });

      expect(result.summary).toMatch(/^\[1\]/);
      expect(result.details[0]).toBe('[1] Failed');
      expect(result.isError).toBe(true);
    });

    it('should handle various non-zero exit codes', () => {
      const codes = [1, 2, 127, 255];
      for (const code of codes) {
        const result = bashFormatter.formatResult({
          details: { exit_code: code, stderr: 'error' },
        });

        expect(result.summary).toMatch(new RegExp(`^\\[${code}\\]`));
        expect(result.isError).toBe(true);
      }
    });

    it('should show stderr section when present', () => {
      const result = bashFormatter.formatResult({
        details: {
          exit_code: 1,
          stdout: '',
          stderr: 'Error: file not found\nNo such file or directory',
        },
      });

      expect(result.details).toContain('stderr:');
      expect(result.details).toContain('Error: file not found');
      expect(result.details).toContain('No such file or directory');
    });

    it('should show both stdout and stderr when both present', () => {
      const result = bashFormatter.formatResult({
        details: {
          exit_code: 1,
          stdout: 'Some output',
          stderr: 'Some error',
        },
      });

      expect(result.details).toContain('Some output');
      expect(result.details).toContain('stderr:');
      expect(result.details).toContain('Some error');
    });

    it('should detect error in content blocks', () => {
      // Even with content blocks, exit code 0 should be default
      const result = bashFormatter.formatResult({
        content: [{ type: 'text', text: 'Error: something went wrong' }],
      });

      // Without explicit exit_code in details, defaults to 0
      expect(result.isError).toBe(false);
    });

    it('should use stderr in summary when stdout is empty', () => {
      const result = bashFormatter.formatResult({
        details: {
          exit_code: 1,
          stdout: '',
          stderr: 'bash: command: not found',
        },
      });

      expect(result.summary).toContain('bash: command: not found');
    });
  });

  describe('formatResult - edge cases', () => {
    it('should handle empty result', () => {
      const result = bashFormatter.formatResult({
        details: { exit_code: 0, stdout: '', stderr: '' },
      });

      expect(result.summary).toBe('[0]');
      expect(result.details[0]).toBe('[0] Success');
      expect(result.isError).toBe(false);
    });

    it('should handle null result', () => {
      const result = bashFormatter.formatResult(null);

      expect(result.summary).toBe('[0]');
      expect(result.isError).toBe(false);
    });

    it('should handle undefined result', () => {
      const result = bashFormatter.formatResult(undefined);

      expect(result.summary).toBe('[0]');
      expect(result.isError).toBe(false);
    });

    it('should truncate very long output', () => {
      const lines = Array.from({ length: 50 }, (_, i) => `Line ${i + 1}`);
      const result = bashFormatter.formatResult({
        details: {
          exit_code: 0,
          stdout: lines.join('\n'),
        },
      });

      // Should have status line + limited output lines + "more" indicator
      expect(result.details.length).toBeLessThan(lines.length + 2);
      expect(result.details[result.details.length - 1]).toMatch(/\.\.\. \(\d+ more\)/);
    });

    it('should handle output with Windows line endings', () => {
      const result = bashFormatter.formatResult({
        details: {
          exit_code: 0,
          stdout: 'Line 1\r\nLine 2\r\nLine 3',
        },
      });

      expect(result.details).toContain('Line 1');
      expect(result.details).toContain('Line 2');
      expect(result.details).toContain('Line 3');
    });

    it('should truncate long first line in summary', () => {
      const longLine =
        'This is a very long line that exceeds the maximum summary length and should be truncated with ellipsis for better display in the UI';
      const result = bashFormatter.formatResult({
        details: {
          exit_code: 0,
          stdout: longLine,
        },
      });

      // Summary is badge + space + truncated line (70 chars)
      expect(result.summary.length).toBeLessThanOrEqual(80);
    });

    it('should handle result with only details.exit_code', () => {
      const result = bashFormatter.formatResult({
        details: { exit_code: 0 },
      });

      expect(result.summary).toBe('[0]');
      expect(result.isError).toBe(false);
    });

    it('should filter empty lines from output', () => {
      const result = bashFormatter.formatResult({
        details: {
          exit_code: 0,
          stdout: 'line1\n\n\nline2\n\n',
        },
      });

      // Empty lines should be filtered
      const outputLines = result.details.slice(1); // Skip status line
      expect(outputLines).not.toContain('');
      expect(outputLines).toContain('line1');
      expect(outputLines).toContain('line2');
    });
  });

  describe('formatResult - realistic scenarios', () => {
    it('should format git status output', () => {
      const gitStatusOutput = `On branch main
Your branch is up to date with 'origin/main'.

Changes not staged for commit:
  modified:   src/index.ts
  modified:   package.json

Untracked files:
  src/new-file.ts`;

      const result = bashFormatter.formatResult({
        details: {
          exit_code: 0,
          stdout: gitStatusOutput,
        },
      });

      expect(result.summary).toContain('On branch main');
      expect(result.isError).toBe(false);
    });

    it('should format npm install failure', () => {
      const result = bashFormatter.formatResult({
        details: {
          exit_code: 1,
          stdout: 'npm WARN deprecated package@1.0.0',
          stderr:
            'npm ERR! code ERESOLVE\nnpm ERR! ERESOLVE unable to resolve dependency tree',
        },
      });

      expect(result.isError).toBe(true);
      expect(result.details).toContain('stderr:');
      expect(result.details.join('\n')).toContain('ERESOLVE');
    });

    it('should format command not found error', () => {
      const result = bashFormatter.formatResult({
        details: {
          exit_code: 127,
          stderr: 'bash: nonexistent-command: command not found',
        },
      });

      expect(result.summary).toMatch(/^\[127\]/);
      expect(result.isError).toBe(true);
      expect(result.details).toContain('bash: nonexistent-command: command not found');
    });

    it('should format test runner output', () => {
      const testOutput = `PASS  src/app.test.ts
  App Component
    ✓ renders without crashing (5ms)
    ✓ displays welcome message (3ms)

Test Suites: 1 passed, 1 total
Tests:       2 passed, 2 total
Time:        1.234s`;

      const result = bashFormatter.formatResult({
        details: {
          exit_code: 0,
          stdout: testOutput,
        },
      });

      expect(result.isError).toBe(false);
      expect(result.summary).toContain('PASS');
    });

    it('should format ls command output', () => {
      const result = bashFormatter.formatResult({
        details: {
          exit_code: 0,
          stdout: 'total 32\ndrwxr-xr-x  5 user  staff   160 Jan  1 12:00 src\n-rw-r--r--  1 user  staff  1234 Jan  1 12:00 package.json',
        },
      });

      expect(result.isError).toBe(false);
      expect(result.summary).toContain('total 32');
    });
  });
});
