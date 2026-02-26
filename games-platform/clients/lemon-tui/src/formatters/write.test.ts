/**
 * Tests for the write tool formatter.
 *
 * Tests formatting of file write operations including path display,
 * content preview, line counts, and created/updated status.
 */

import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';
import { homedir } from 'node:os';

// Mock os module to control home directory for path formatting
vi.mock('node:os', () => ({
  homedir: vi.fn(() => '/Users/testuser'),
}));

describe('writeFormatter', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.resetModules();
  });

  describe('formatArgs', () => {
    it('shows shortened path in summary', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatArgs({
        path: '/Users/testuser/projects/myapp/src/components/Button.tsx',
        content: 'export const Button = () => <button>Click</button>;',
      });

      expect(result.summary).toBe('~/projects/myapp/src/components/Button.tsx');
    });

    it('shows content preview from first non-empty line', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatArgs({
        path: '/Users/testuser/src/index.ts',
        content: '\n\n// Main entry point\nexport * from "./app";',
      });

      expect(result.details).toContain('Preview: // Main entry point');
    });

    it('truncates long first lines in preview', async () => {
      const { writeFormatter } = await import('./write.js');

      const longLine = 'const veryLongVariableName = someFunctionWithManyParameters(arg1, arg2, arg3, arg4, arg5);';
      const result = writeFormatter.formatArgs({
        path: '/Users/testuser/src/long.ts',
        content: longLine,
      });

      // Preview should be truncated to ~60 chars with ...
      const previewLine = result.details.find((d) => d.startsWith('Preview:'));
      expect(previewLine).toBeDefined();
      expect(previewLine!.length).toBeLessThanOrEqual(70); // "Preview: " + 60 chars max
      expect(previewLine).toContain('...');
    });

    it('shows line count for single line', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatArgs({
        path: '/Users/testuser/src/one.ts',
        content: 'export const x = 1;',
      });

      expect(result.details).toContain('1 line');
    });

    it('shows line count for multiple lines', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatArgs({
        path: '/Users/testuser/src/multi.ts',
        content: 'line1\nline2\nline3\nline4\nline5',
      });

      expect(result.details).toContain('5 lines');
    });

    it('handles content ending with newline', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatArgs({
        path: '/Users/testuser/src/trailing.ts',
        content: 'line1\nline2\nline3\n',
      });

      // Should be 3 lines, not 4 (trailing newline doesn't add a line)
      expect(result.details).toContain('3 lines');
    });

    it('handles empty content', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatArgs({
        path: '/Users/testuser/src/empty.ts',
        content: '',
      });

      expect(result.details).toContain('0 lines');
      // No preview line for empty content
      expect(result.details.find((d) => d.startsWith('Preview:'))).toBeUndefined();
    });

    it('handles missing path gracefully', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatArgs({
        content: 'some content',
      });

      expect(result.summary).toBe('');
    });

    it('handles missing content gracefully', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatArgs({
        path: '/Users/testuser/src/file.ts',
      });

      expect(result.details).toContain('0 lines');
    });

    it('includes path in details', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatArgs({
        path: '/Users/testuser/projects/app/src/index.ts',
        content: 'export {};',
      });

      expect(result.details).toContain('~/projects/app/src/index.ts');
    });

    it('handles Windows-style line endings', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatArgs({
        path: '/Users/testuser/src/windows.ts',
        content: 'line1\r\nline2\r\nline3',
      });

      expect(result.details).toContain('3 lines');
    });
  });

  describe('formatResult', () => {
    it('shows created status with checkmark for new files', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatResult(
        {
          content: [{ type: 'text', text: 'File written successfully' }],
          details: { bytes_written: 1024, created: true },
        },
        {
          path: '/Users/testuser/src/new-file.ts',
          content: 'export const newFeature = () => {};\n',
        }
      );

      expect(result.summary).toContain('\u2713 Created');
      expect(result.summary).toContain('~/src/new-file.ts');
      expect(result.summary).toContain('1 line');
    });

    it('shows updated status with checkmark for existing files', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatResult(
        {
          content: [{ type: 'text', text: 'File written successfully' }],
          details: { bytes_written: 2048, created: false },
        },
        {
          path: '/Users/testuser/src/existing.ts',
          content: 'line1\nline2\nline3\nline4\nline5\n',
        }
      );

      expect(result.summary).toContain('\u2713 Updated');
      expect(result.summary).toContain('5 lines');
    });

    it('shows bytes written in details', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatResult(
        {
          details: { bytes_written: 4096, created: true },
        },
        {
          path: '/Users/testuser/src/file.ts',
          content: 'a'.repeat(100) + '\n'.repeat(50),
        }
      );

      expect(result.details.some((d) => d.includes('4'))).toBe(true); // 4 KB or 4096 B
    });

    it('includes path in details', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatResult(
        {
          details: { bytes_written: 512, created: false },
        },
        {
          path: '/Users/testuser/projects/myapp/src/utils/helpers.ts',
          content: 'export const helper = () => {};',
        }
      );

      expect(result.details).toContain('~/projects/myapp/src/utils/helpers.ts');
    });

    it('handles missing result details', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatResult(
        {},
        {
          path: '/Users/testuser/src/file.ts',
          content: 'content',
        }
      );

      // Should still format, treating as update with 0 bytes
      expect(result.summary).toContain('\u2713 Updated');
    });

    it('handles null result', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatResult(null, {
        path: '/Users/testuser/src/file.ts',
        content: 'content',
      });

      expect(result.summary).toContain('\u2713 Updated');
    });

    it('handles missing args', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatResult({
        details: { bytes_written: 100, created: true },
      });

      expect(result.summary).toContain('\u2713 Created');
      expect(result.summary).toContain('0 lines');
    });

    it('formats bytes correctly for small files', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatResult(
        {
          details: { bytes_written: 256, created: true },
        },
        {
          path: '/Users/testuser/src/small.ts',
          content: 'x',
        }
      );

      expect(result.details.some((d) => d.includes('256 B'))).toBe(true);
    });

    it('formats bytes correctly for large files', async () => {
      const { writeFormatter } = await import('./write.js');

      const result = writeFormatter.formatResult(
        {
          details: { bytes_written: 1536, created: true },
        },
        {
          path: '/Users/testuser/src/large.ts',
          content: 'x'.repeat(1000),
        }
      );

      expect(result.details.some((d) => d.includes('KB'))).toBe(true);
    });

    it('shows correct plural for line count', async () => {
      const { writeFormatter } = await import('./write.js');

      const singleLine = writeFormatter.formatResult(
        { details: { bytes_written: 10, created: true } },
        { path: '/Users/testuser/a.ts', content: 'x' }
      );
      expect(singleLine.summary).toContain('1 line)');

      const multiLine = writeFormatter.formatResult(
        { details: { bytes_written: 10, created: true } },
        { path: '/Users/testuser/a.ts', content: 'x\ny' }
      );
      expect(multiLine.summary).toContain('2 lines)');
    });
  });

  describe('tools property', () => {
    it('handles write tool', async () => {
      const { writeFormatter } = await import('./write.js');

      expect(writeFormatter.tools).toContain('write');
    });
  });
});
