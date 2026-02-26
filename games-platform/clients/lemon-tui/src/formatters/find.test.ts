/**
 * Tests for the find, glob, and ls tool formatters.
 *
 * Tests formatting of file search and directory listing operations
 * including patterns, filters, result counts, and file type indicators.
 */

import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest';

// Mock os module to control home directory for path formatting
vi.mock('node:os', () => ({
  homedir: vi.fn(() => '/Users/testuser'),
}));

describe('findFormatter', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.resetModules();
  });

  describe('formatArgs', () => {
    it('shows pattern with path in summary', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatArgs({
        pattern: '*.ts',
        path: '/Users/testuser/projects/myapp/src',
      });

      expect(result.summary).toBe('*.ts in ~/projects/myapp/src');
    });

    it('shows pattern only when no path provided', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatArgs({
        pattern: '*.tsx',
      });

      expect(result.summary).toBe('*.tsx');
    });

    it('shows type filter for files', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatArgs({
        pattern: '*',
        type: 'f',
      });

      expect(result.details).toContain('type: files');
    });

    it('shows type filter for directories', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatArgs({
        pattern: '*',
        type: 'd',
      });

      expect(result.details).toContain('type: directories');
    });

    it('shows max_depth in details', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatArgs({
        pattern: '*.js',
        max_depth: 3,
      });

      expect(result.details).toContain('max_depth: 3');
    });

    it('shows max_results in details', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatArgs({
        pattern: '*.json',
        max_results: 100,
      });

      expect(result.details).toContain('max_results: 100');
    });

    it('includes pattern in details', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatArgs({
        pattern: '**/*.test.ts',
      });

      expect(result.details).toContain('pattern: **/*.test.ts');
    });

    it('includes path in details when provided', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatArgs({
        pattern: '*',
        path: '/Users/testuser/code',
      });

      expect(result.details).toContain('path: ~/code');
    });

    it('handles missing pattern', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatArgs({});

      expect(result.summary).toBe('*');
      expect(result.details).toContain('pattern: *');
    });

    it('shows all filters together', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatArgs({
        pattern: '*.md',
        path: '/Users/testuser/docs',
        type: 'f',
        max_depth: 5,
        max_results: 50,
      });

      expect(result.summary).toBe('*.md in ~/docs');
      expect(result.details).toContain('pattern: *.md');
      expect(result.details).toContain('path: ~/docs');
      expect(result.details).toContain('type: files');
      expect(result.details).toContain('max_depth: 5');
      expect(result.details).toContain('max_results: 50');
    });
  });

  describe('formatResult', () => {
    it('shows "N files found" summary', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatResult({
        content: [
          {
            type: 'text',
            text: 'src/index.ts\nsrc/app.ts\nsrc/utils.ts',
          },
        ],
      });

      expect(result.summary).toBe('3 files found');
    });

    it('shows singular "file" for single result', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatResult({
        content: [{ type: 'text', text: 'package.json' }],
      });

      expect(result.summary).toBe('1 file found');
    });

    it('shows file list in details', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatResult({
        content: [
          {
            type: 'text',
            text: 'src/components/Button.tsx\nsrc/components/Input.tsx\nsrc/hooks/useForm.ts',
          },
        ],
      });

      expect(result.details).toContain('src/components/Button.tsx');
      expect(result.details).toContain('src/components/Input.tsx');
      expect(result.details).toContain('src/hooks/useForm.ts');
    });

    it('shows "No matches" when no files found', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatResult({
        content: [{ type: 'text', text: '' }],
      });

      expect(result.summary).toBe('No matches');
      expect(result.details).toHaveLength(0);
    });

    it('truncates long file lists', async () => {
      const { findFormatter } = await import('./find.js');

      const files = Array.from({ length: 20 }, (_, i) => `src/file${i}.ts`).join('\n');
      const result = findFormatter.formatResult({
        content: [{ type: 'text', text: files }],
      });

      // Should truncate to 10 files plus "... (N more)"
      expect(result.details.length).toBeLessThanOrEqual(11);
      expect(result.details.some((d) => d.includes('more'))).toBe(true);
    });

    it('handles directory entries with / suffix', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatResult({
        content: [
          {
            type: 'text',
            text: 'src/\nlib/\ntest/',
          },
        ],
      });

      expect(result.details).toContain('src/');
      expect(result.details).toContain('lib/');
      expect(result.details).toContain('test/');
    });

    it('handles mixed files and directories', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatResult({
        content: [
          {
            type: 'text',
            text: 'src/\nREADME.md\nlib/\npackage.json',
          },
        ],
      });

      expect(result.summary).toBe('4 files found');
      expect(result.details).toContain('src/');
      expect(result.details).toContain('README.md');
    });

    it('handles null result', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatResult(null);

      expect(result.summary).toBe('No matches');
    });

    it('handles string result directly', async () => {
      const { findFormatter } = await import('./find.js');

      const result = findFormatter.formatResult('file1.ts\nfile2.ts');

      expect(result.summary).toBe('2 files found');
    });
  });

  describe('tools property', () => {
    it('handles find tool', async () => {
      const { findFormatter } = await import('./find.js');

      expect(findFormatter.tools).toContain('find');
    });
  });
});

describe('globFormatter', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.resetModules();
  });

  describe('formatArgs', () => {
    it('shows pattern with path in summary', async () => {
      const { globFormatter } = await import('./find.js');

      const result = globFormatter.formatArgs({
        pattern: '**/*.tsx',
        path: '/Users/testuser/projects/app',
      });

      expect(result.summary).toBe('**/*.tsx in ~/projects/app');
    });

    it('shows pattern only when no path provided', async () => {
      const { globFormatter } = await import('./find.js');

      const result = globFormatter.formatArgs({
        pattern: 'src/**/*.ts',
      });

      expect(result.summary).toBe('src/**/*.ts');
    });

    it('includes pattern in details', async () => {
      const { globFormatter } = await import('./find.js');

      const result = globFormatter.formatArgs({
        pattern: '*.{js,ts,jsx,tsx}',
      });

      expect(result.details).toContain('pattern: *.{js,ts,jsx,tsx}');
    });

    it('includes path in details when provided', async () => {
      const { globFormatter } = await import('./find.js');

      const result = globFormatter.formatArgs({
        pattern: '**/*',
        path: '/Users/testuser/src',
      });

      expect(result.details).toContain('path: ~/src');
    });

    it('shows max_results in details', async () => {
      const { globFormatter } = await import('./find.js');

      const result = globFormatter.formatArgs({
        pattern: '*.md',
        max_results: 25,
      });

      expect(result.details).toContain('max_results: 25');
    });

    it('handles missing pattern', async () => {
      const { globFormatter } = await import('./find.js');

      const result = globFormatter.formatArgs({});

      expect(result.summary).toBe('*');
    });
  });

  describe('formatResult', () => {
    it('shows "N files found" summary', async () => {
      const { globFormatter } = await import('./find.js');

      const result = globFormatter.formatResult({
        content: [
          {
            type: 'text',
            text: 'src/index.ts\nsrc/app.ts',
          },
        ],
      });

      expect(result.summary).toBe('2 files found');
    });

    it('shows file list in details', async () => {
      const { globFormatter } = await import('./find.js');

      const result = globFormatter.formatResult({
        content: [
          {
            type: 'text',
            text: 'package.json\ntsconfig.json\n.eslintrc.json',
          },
        ],
      });

      expect(result.details).toContain('package.json');
      expect(result.details).toContain('tsconfig.json');
      expect(result.details).toContain('.eslintrc.json');
    });

    it('shows "No matches" when empty', async () => {
      const { globFormatter } = await import('./find.js');

      const result = globFormatter.formatResult({
        content: [{ type: 'text', text: '' }],
      });

      expect(result.summary).toBe('No matches');
    });

    it('truncates long lists similar to find', async () => {
      const { globFormatter } = await import('./find.js');

      const files = Array.from({ length: 15 }, (_, i) => `component${i}.tsx`).join('\n');
      const result = globFormatter.formatResult({
        content: [{ type: 'text', text: files }],
      });

      expect(result.details.length).toBeLessThanOrEqual(11);
      expect(result.details.some((d) => d.includes('more'))).toBe(true);
    });
  });

  describe('tools property', () => {
    it('handles glob tool', async () => {
      const { globFormatter } = await import('./find.js');

      expect(globFormatter.tools).toContain('glob');
    });
  });
});

describe('lsFormatter', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.resetModules();
  });

  describe('formatArgs', () => {
    it('shows path with flags in summary', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatArgs({
        path: '/Users/testuser/projects',
        all: true,
        long: true,
      });

      expect(result.summary).toBe('~/projects -al');
    });

    it('shows path without flags when none set', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatArgs({
        path: '/Users/testuser/src',
      });

      expect(result.summary).toBe('~/src');
    });

    it('shows -a flag for all', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatArgs({
        path: '/Users/testuser/dir',
        all: true,
      });

      expect(result.summary).toContain('-a');
    });

    it('shows -l flag for long', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatArgs({
        path: '/Users/testuser/dir',
        long: true,
      });

      expect(result.summary).toContain('-l');
    });

    it('shows -R flag for recursive', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatArgs({
        path: '/Users/testuser/dir',
        recursive: true,
      });

      expect(result.summary).toContain('-R');
    });

    it('combines multiple flags', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatArgs({
        path: '/Users/testuser/dir',
        all: true,
        long: true,
        recursive: true,
      });

      expect(result.summary).toContain('-alR');
    });

    it('defaults to . when no path provided', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatArgs({});

      expect(result.summary).toBe('.');
      expect(result.details).toContain('path: .');
    });

    it('shows max_depth in details', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatArgs({
        path: '/Users/testuser/dir',
        max_depth: 2,
      });

      expect(result.details).toContain('max_depth: 2');
    });

    it('shows max_entries in details', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatArgs({
        path: '/Users/testuser/dir',
        max_entries: 50,
      });

      expect(result.details).toContain('max_entries: 50');
    });

    it('includes flags in details', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatArgs({
        path: '/Users/testuser/dir',
        all: true,
        long: true,
      });

      expect(result.details).toContain('flags: -al');
    });
  });

  describe('formatResult', () => {
    it('shows "path (N entries)" summary', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatResult(
        {
          content: [
            {
              type: 'text',
              text: 'file1.ts\nfile2.ts\ndir/\nREADME.md',
            },
          ],
        },
        { path: '/Users/testuser/myproject' }
      );

      expect(result.summary).toBe('~/myproject (4 entries)');
    });

    it('shows singular "entry" for single item', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatResult(
        {
          content: [{ type: 'text', text: 'only-file.txt' }],
        },
        { path: '/Users/testuser/single' }
      );

      expect(result.summary).toBe('~/single (1 entry)');
    });

    it('shows directory entries with / suffix', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatResult(
        {
          content: [
            {
              type: 'text',
              text: 'src/\nlib/\nnode_modules/',
            },
          ],
        },
        { path: '/Users/testuser/project' }
      );

      expect(result.details).toContain('src/');
      expect(result.details).toContain('lib/');
      expect(result.details).toContain('node_modules/');
    });

    it('handles empty directory', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatResult(
        {
          content: [{ type: 'text', text: '' }],
        },
        { path: '/Users/testuser/empty' }
      );

      expect(result.summary).toBe('~/empty (0 entries)');
      expect(result.details).toHaveLength(0);
    });

    it('truncates long listings', async () => {
      const { lsFormatter } = await import('./find.js');

      const entries = Array.from({ length: 25 }, (_, i) => `file${i}.txt`).join('\n');
      const result = lsFormatter.formatResult(
        {
          content: [{ type: 'text', text: entries }],
        },
        { path: '/Users/testuser/many' }
      );

      expect(result.details.length).toBeLessThanOrEqual(11);
      expect(result.details.some((d) => d.includes('more'))).toBe(true);
    });

    it('uses default path when args not provided', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatResult({
        content: [{ type: 'text', text: 'a\nb\nc' }],
      });

      expect(result.summary).toBe('. (3 entries)');
    });

    it('handles string result directly', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatResult('file.txt\ndir/', { path: '/Users/testuser/test' });

      expect(result.summary).toBe('~/test (2 entries)');
    });

    it('handles mixed files and directories', async () => {
      const { lsFormatter } = await import('./find.js');

      const result = lsFormatter.formatResult(
        {
          content: [
            {
              type: 'text',
              text: 'package.json\nsrc/\nREADME.md\nlib/\nindex.ts',
            },
          ],
        },
        { path: '/Users/testuser/project' }
      );

      expect(result.summary).toBe('~/project (5 entries)');
      // Check that directories keep their / suffix
      expect(result.details).toContain('src/');
      expect(result.details).toContain('lib/');
      // Files should not have /
      expect(result.details).toContain('package.json');
      expect(result.details).toContain('README.md');
    });
  });

  describe('tools property', () => {
    it('handles ls tool', async () => {
      const { lsFormatter } = await import('./find.js');

      expect(lsFormatter.tools).toContain('ls');
    });
  });
});

describe('default export', () => {
  it('exports array of all three formatters', async () => {
    const formatters = await import('./find.js');

    expect(formatters.default).toBeInstanceOf(Array);
    expect(formatters.default).toHaveLength(3);
    expect(formatters.default[0].tools).toContain('find');
    expect(formatters.default[1].tools).toContain('glob');
    expect(formatters.default[2].tools).toContain('ls');
  });
});

describe('edge cases', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.resetModules();
  });

  it('handles Windows-style line endings in results', async () => {
    const { findFormatter } = await import('./find.js');

    const result = findFormatter.formatResult({
      content: [{ type: 'text', text: 'file1.ts\r\nfile2.ts\r\nfile3.ts' }],
    });

    expect(result.summary).toBe('3 files found');
  });

  it('handles extra whitespace in results', async () => {
    const { findFormatter } = await import('./find.js');

    const result = findFormatter.formatResult({
      content: [{ type: 'text', text: '  file1.ts  \n  file2.ts  \n\n  file3.ts  ' }],
    });

    expect(result.summary).toBe('3 files found');
    expect(result.details).toContain('file1.ts');
  });

  it('handles result with only whitespace lines', async () => {
    const { findFormatter } = await import('./find.js');

    const result = findFormatter.formatResult({
      content: [{ type: 'text', text: '   \n\n   \n' }],
    });

    expect(result.summary).toBe('No matches');
  });

  it('handles result object with output field', async () => {
    const { findFormatter } = await import('./find.js');

    const result = findFormatter.formatResult({
      output: 'file1.ts\nfile2.ts',
    });

    expect(result.summary).toBe('2 files found');
  });

  it('handles result object with text field', async () => {
    const { findFormatter } = await import('./find.js');

    const result = findFormatter.formatResult({
      text: 'file1.ts\nfile2.ts\nfile3.ts',
    });

    expect(result.summary).toBe('3 files found');
  });
});
