/**
 * Tests for the grep formatter.
 *
 * Tests the formatting of grep tool arguments and results,
 * including match parsing, grouping, and highlighting.
 */

import { describe, expect, it } from 'vitest';
import { grepFormatter, parseGrepOutput } from './grep.js';

describe('grepFormatter', () => {
  describe('tools property', () => {
    it('contains "grep"', () => {
      expect(grepFormatter.tools).toContain('grep');
    });

    it('contains exactly one tool', () => {
      expect(grepFormatter.tools).toHaveLength(1);
    });
  });

  describe('formatArgs', () => {
    it('shows pattern in quotes in summary', () => {
      const result = grepFormatter.formatArgs({
        pattern: 'function',
      });

      expect(result.summary).toContain('"function"');
    });

    it('shows path in summary when provided', () => {
      const result = grepFormatter.formatArgs({
        pattern: 'TODO',
        path: '/Users/test/project/src',
      });

      expect(result.summary).toContain('in');
      expect(result.summary).toContain('src');
    });

    it('shows glob in summary when provided', () => {
      const result = grepFormatter.formatArgs({
        pattern: 'import',
        glob: '*.ts',
      });

      expect(result.summary).toContain('(*.ts)');
    });

    it('shows pattern, path, and glob together in summary', () => {
      const result = grepFormatter.formatArgs({
        pattern: 'export',
        path: '/Users/test/project',
        glob: '**/*.tsx',
      });

      expect(result.summary).toContain('"export"');
      expect(result.summary).toContain('in');
      expect(result.summary).toContain('(**/*.tsx)');
    });

    it('shows "(no pattern)" when pattern is missing', () => {
      const result = grepFormatter.formatArgs({});

      expect(result.summary).toBe('(no pattern)');
    });

    it('shows case_sensitive in details when provided', () => {
      const result = grepFormatter.formatArgs({
        pattern: 'TEST',
        case_sensitive: true,
      });

      expect(result.details).toContainEqual('Case sensitive: true');
    });

    it('shows case_sensitive false in details', () => {
      const result = grepFormatter.formatArgs({
        pattern: 'test',
        case_sensitive: false,
      });

      expect(result.details).toContainEqual('Case sensitive: false');
    });

    it('shows context_lines in details when provided', () => {
      const result = grepFormatter.formatArgs({
        pattern: 'error',
        context_lines: 3,
      });

      expect(result.details).toContainEqual('Context lines: 3');
    });

    it('shows pattern in details', () => {
      const result = grepFormatter.formatArgs({
        pattern: 'searchterm',
      });

      expect(result.details).toContainEqual('Pattern: "searchterm"');
    });

    it('shows path in details when provided', () => {
      const result = grepFormatter.formatArgs({
        pattern: 'test',
        path: '/Users/test/project/lib',
      });

      expect(result.details).toContainEqual(expect.stringContaining('Path:'));
      expect(result.details).toContainEqual(expect.stringContaining('lib'));
    });

    it('shows glob in details when provided', () => {
      const result = grepFormatter.formatArgs({
        pattern: 'test',
        glob: '*.spec.ts',
      });

      expect(result.details).toContainEqual('Glob: *.spec.ts');
    });
  });

  describe('formatResult - with matches', () => {
    it('shows "N matches in M files" summary', () => {
      const grepOutput = [
        '/project/src/app.ts:10:const greeting = "hello";',
        '/project/src/app.ts:20:console.log("hello world");',
        '/project/src/utils.ts:5:export function hello() {}',
      ].join('\n');

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'hello' }
      );

      expect(result.summary).toContain('3 matches');
      expect(result.summary).toContain('2 files');
    });

    it('shows singular "match" and "file" for single result', () => {
      const grepOutput = '/project/src/app.ts:10:const x = 1;';

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'const' }
      );

      expect(result.summary).toContain('1 match');
      expect(result.summary).toContain('1 file');
      expect(result.summary).not.toContain('matches');
      expect(result.summary).not.toContain('files');
    });

    it('groups matches by file in details', () => {
      const grepOutput = [
        '/project/src/app.ts:10:first match',
        '/project/src/app.ts:20:second match',
        '/project/src/utils.ts:5:third match',
      ].join('\n');

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'match' }
      );

      // Should have file headers
      expect(result.details.some((line) => line.includes('app.ts'))).toBe(true);
      expect(result.details.some((line) => line.includes('utils.ts'))).toBe(true);
    });

    it('shows line numbers in details', () => {
      const grepOutput = '/project/src/app.ts:42:const answer = 42;';

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: '42' }
      );

      // Line number should be formatted in output
      expect(result.details.some((line) => line.includes('42'))).toBe(true);
    });

    it('shows match content in details', () => {
      const grepOutput = '/project/src/app.ts:10:export function calculateTotal(items) {';

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'calculateTotal' }
      );

      expect(result.details.some((line) => line.includes('export function'))).toBe(true);
    });

    it('highlights pattern in match content with brackets', () => {
      const grepOutput = '/project/src/app.ts:10:const greeting = "hello";';

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'hello' }
      );

      // The highlightFn wraps matches in brackets
      expect(result.details.some((line) => line.includes('[hello]'))).toBe(true);
    });

    it('highlights pattern case-insensitively', () => {
      const grepOutput = '/project/src/app.ts:10:const HELLO = "Hello";';

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'hello' }
      );

      // Should highlight both HELLO and Hello
      expect(result.details.some((line) => line.includes('[HELLO]'))).toBe(true);
      expect(result.details.some((line) => line.includes('[Hello]'))).toBe(true);
    });

    it('shows match count per file in file header', () => {
      const grepOutput = [
        '/project/src/app.ts:10:match one',
        '/project/src/app.ts:20:match two',
        '/project/src/app.ts:30:match three',
      ].join('\n');

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'match' }
      );

      expect(result.details.some((line) => line.includes('(3 matches)'))).toBe(true);
    });

    it('shows singular "match" in file header for single match', () => {
      const grepOutput = '/project/src/app.ts:10:single match here';

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'match' }
      );

      expect(result.details.some((line) => line.includes('(1 match)'))).toBe(true);
    });
  });

  describe('formatResult - file list mode', () => {
    it('handles grep -l style output (just filenames)', () => {
      const grepOutput = [
        '/project/src/app.ts',
        '/project/src/utils.ts',
        '/project/src/index.ts',
      ].join('\n');

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'function' }
      );

      // Each file counts as 1 match
      expect(result.summary).toContain('3');
      expect(result.summary).toContain('3 files');
    });

    it('shows file count in summary for file list mode', () => {
      const grepOutput = [
        '/project/src/a.ts',
        '/project/src/b.ts',
      ].join('\n');

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'test' }
      );

      expect(result.summary).toContain('2 files');
    });

    it('shows file paths in details for file list mode', () => {
      const grepOutput = [
        '/project/src/components/Button.tsx',
        '/project/src/components/Input.tsx',
      ].join('\n');

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'component' }
      );

      expect(result.details.some((line) => line.includes('Button.tsx'))).toBe(true);
      expect(result.details.some((line) => line.includes('Input.tsx'))).toBe(true);
    });
  });

  describe('formatResult - no matches', () => {
    it('shows "No matches" summary', () => {
      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: '' }] },
        { pattern: 'nonexistent' }
      );

      expect(result.summary).toBe('No matches');
    });

    it('shows "No matches found" in details', () => {
      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: '' }] },
        { pattern: 'notfound' }
      );

      expect(result.details).toContainEqual('No matches found');
    });

    it('handles whitespace-only output as no matches', () => {
      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: '   \n\t\n  ' }] },
        { pattern: 'test' }
      );

      expect(result.summary).toBe('No matches');
    });

    it('handles null content as no matches', () => {
      const result = grepFormatter.formatResult(
        { content: null },
        { pattern: 'test' }
      );

      expect(result.summary).toBe('No matches');
    });
  });

  describe('formatResult - truncation', () => {
    it('limits displayed files (MAX_FILES = 10)', () => {
      const files = [];
      for (let i = 0; i < 15; i++) {
        files.push(`/project/src/file${i}.ts:1:match`);
      }
      const grepOutput = files.join('\n');

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'match' }
      );

      // Should show truncation indicator
      expect(result.details.some((line) => line.includes('more files'))).toBe(true);
    });

    it('shows count of remaining files in truncation message', () => {
      const files = [];
      for (let i = 0; i < 15; i++) {
        files.push(`/project/src/file${i}.ts:1:match`);
      }
      const grepOutput = files.join('\n');

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'match' }
      );

      // 15 files - 10 shown = 5 more
      expect(result.details.some((line) => line.includes('5 more files'))).toBe(true);
    });

    it('limits matches per file (MAX_MATCHES_PER_FILE = 3)', () => {
      const matches = [];
      for (let i = 1; i <= 10; i++) {
        matches.push(`/project/src/app.ts:${i}:match line ${i}`);
      }
      const grepOutput = matches.join('\n');

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'match' }
      );

      // Should show truncation indicator for matches
      expect(result.details.some((line) => line.includes('more)'))).toBe(true);
    });

    it('shows count of remaining matches per file', () => {
      const matches = [];
      for (let i = 1; i <= 8; i++) {
        matches.push(`/project/src/app.ts:${i}:match line ${i}`);
      }
      const grepOutput = matches.join('\n');

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'match' }
      );

      // 8 matches - 3 shown = 5 more
      expect(result.details.some((line) => line.includes('5 more'))).toBe(true);
    });

    it('truncates long content lines (MAX_LINE_LENGTH = 120)', () => {
      const longLine = 'x'.repeat(200);
      const grepOutput = `/project/src/app.ts:1:${longLine}`;

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'x' }
      );

      // Should be truncated with "..."
      const contentLine = result.details.find((line) => line.includes('|'));
      expect(contentLine).toBeDefined();
      expect(contentLine!.includes('...')).toBe(true);
    });
  });

  describe('formatResult - error handling', () => {
    it('shows error message for is_error result', () => {
      const result = grepFormatter.formatResult(
        {
          is_error: true,
          content: [{ type: 'text', text: 'grep: invalid regex pattern' }],
        },
        { pattern: '[invalid' }
      );

      expect(result.isError).toBe(true);
      expect(result.summary).toContain('invalid regex');
    });

    it('shows error message for isError result', () => {
      const result = grepFormatter.formatResult(
        {
          isError: true,
          content: [{ type: 'text', text: 'Permission denied' }],
        },
        { pattern: 'test' }
      );

      expect(result.isError).toBe(true);
    });

    it('shows error details in details array', () => {
      const errorMessage = 'grep: /nonexistent: No such file or directory';
      const result = grepFormatter.formatResult(
        {
          is_error: true,
          content: [{ type: 'text', text: errorMessage }],
        },
        { pattern: 'test' }
      );

      expect(result.details).toContainEqual(expect.stringContaining('No such file'));
    });

    it('truncates long error message in summary', () => {
      const longError = 'Error: ' + 'x'.repeat(200);
      const result = grepFormatter.formatResult(
        {
          is_error: true,
          content: [{ type: 'text', text: longError }],
        },
        { pattern: 'test' }
      );

      expect(result.summary.length).toBeLessThanOrEqual(103); // 100 + "..."
    });
  });

  describe('formatResult - edge cases', () => {
    it('handles missing args', () => {
      const result = grepFormatter.formatResult({
        content: [{ type: 'text', text: '/project/app.ts:1:hello' }],
      });

      // Should not crash, pattern will be empty
      expect(result.summary).toBeDefined();
    });

    it('handles string result directly', () => {
      const result = grepFormatter.formatResult(
        '/project/app.ts:10:direct string result',
        { pattern: 'string' }
      );

      expect(result.summary).toContain('1 match');
    });

    it('handles result with text property', () => {
      const result = grepFormatter.formatResult(
        { text: '/project/app.ts:10:text property result' },
        { pattern: 'text' }
      );

      expect(result.summary).toContain('1 match');
    });

    it('handles result with output property', () => {
      const result = grepFormatter.formatResult(
        { output: '/project/app.ts:10:output property result' },
        { pattern: 'output' }
      );

      expect(result.summary).toContain('1 match');
    });

    it('handles special regex characters in pattern for highlighting', () => {
      const grepOutput = '/project/app.ts:10:const arr = items.map(x => x);';

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: '.map(' }
      );

      // Should not crash due to regex special chars
      expect(result.summary).toBeDefined();
    });

    it('handles empty pattern gracefully', () => {
      const grepOutput = '/project/app.ts:10:some content';

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: '' }
      );

      // Content should still be shown without highlighting
      expect(result.details.some((line) => line.includes('some content'))).toBe(true);
    });

    it('handles Windows-style paths', () => {
      const grepOutput = 'C:\\project\\src\\app.ts:10:windows path match';

      const result = grepFormatter.formatResult(
        { content: [{ type: 'text', text: grepOutput }] },
        { pattern: 'windows' }
      );

      // Should handle the path (may or may not parse correctly, but shouldn't crash)
      expect(result.summary).toBeDefined();
    });
  });
});

describe('parseGrepOutput', () => {
  it('returns empty map for empty string', () => {
    const result = parseGrepOutput('');
    expect(result.size).toBe(0);
  });

  it('returns empty map for whitespace-only string', () => {
    const result = parseGrepOutput('   \n\t\n  ');
    expect(result.size).toBe(0);
  });

  it('parses "file:line:content" format', () => {
    const output = '/project/src/app.ts:10:const x = 1;';
    const result = parseGrepOutput(output);

    expect(result.size).toBe(1);
    expect(result.has('/project/src/app.ts')).toBe(true);

    const matches = result.get('/project/src/app.ts')!;
    expect(matches).toHaveLength(1);
    expect(matches[0].line).toBe(10);
    expect(matches[0].content).toBe('const x = 1;');
  });

  it('parses multiple matches in same file', () => {
    const output = [
      '/project/src/app.ts:10:first match',
      '/project/src/app.ts:20:second match',
      '/project/src/app.ts:30:third match',
    ].join('\n');

    const result = parseGrepOutput(output);

    expect(result.size).toBe(1);
    const matches = result.get('/project/src/app.ts')!;
    expect(matches).toHaveLength(3);
    expect(matches[0].line).toBe(10);
    expect(matches[1].line).toBe(20);
    expect(matches[2].line).toBe(30);
  });

  it('parses matches across multiple files', () => {
    const output = [
      '/project/src/app.ts:10:app match',
      '/project/src/utils.ts:5:utils match',
      '/project/src/index.ts:1:index match',
    ].join('\n');

    const result = parseGrepOutput(output);

    expect(result.size).toBe(3);
    expect(result.has('/project/src/app.ts')).toBe(true);
    expect(result.has('/project/src/utils.ts')).toBe(true);
    expect(result.has('/project/src/index.ts')).toBe(true);
  });

  it('handles "file" only format (grep -l style)', () => {
    const output = [
      '/project/src/app.ts',
      '/project/src/utils.ts',
    ].join('\n');

    const result = parseGrepOutput(output);

    expect(result.size).toBe(2);
    expect(result.has('/project/src/app.ts')).toBe(true);
    expect(result.has('/project/src/utils.ts')).toBe(true);
    // File-only entries have empty match arrays
    expect(result.get('/project/src/app.ts')).toEqual([]);
  });

  it('groups matches by file correctly', () => {
    const output = [
      '/project/a.ts:1:first',
      '/project/b.ts:1:second',
      '/project/a.ts:2:third',
      '/project/b.ts:2:fourth',
    ].join('\n');

    const result = parseGrepOutput(output);

    expect(result.size).toBe(2);

    const aMatches = result.get('/project/a.ts')!;
    expect(aMatches).toHaveLength(2);
    expect(aMatches[0].content).toBe('first');
    expect(aMatches[1].content).toBe('third');

    const bMatches = result.get('/project/b.ts')!;
    expect(bMatches).toHaveLength(2);
    expect(bMatches[0].content).toBe('second');
    expect(bMatches[1].content).toBe('fourth');
  });

  it('handles content with colons', () => {
    const output = '/project/app.ts:10:const url = "http://example.com:8080";';
    const result = parseGrepOutput(output);

    const matches = result.get('/project/app.ts')!;
    expect(matches[0].content).toBe('const url = "http://example.com:8080";');
  });

  it('handles empty content after line number', () => {
    const output = '/project/app.ts:10:';
    const result = parseGrepOutput(output);

    const matches = result.get('/project/app.ts')!;
    expect(matches[0].line).toBe(10);
    expect(matches[0].content).toBe('');
  });

  it('handles Windows line endings', () => {
    const output = '/project/a.ts:1:first\r\n/project/b.ts:2:second';
    const result = parseGrepOutput(output);

    expect(result.size).toBe(2);
  });

  it('skips lines without file path characteristics', () => {
    const output = [
      '/project/app.ts:10:valid match',
      'some random text',
      '/project/utils.ts:5:another match',
    ].join('\n');

    const result = parseGrepOutput(output);

    expect(result.size).toBe(2);
    expect(result.has('some random text')).toBe(false);
  });

  it('handles relative paths with dots', () => {
    const output = './src/app.ts:10:relative path match';
    const result = parseGrepOutput(output);

    expect(result.has('./src/app.ts')).toBe(true);
  });

  it('handles paths with spaces (file only mode)', () => {
    const output = '/project/my files/app.ts';
    const result = parseGrepOutput(output);

    // Should recognize as a file path because it contains /
    expect(result.has('/project/my files/app.ts')).toBe(true);
  });

  it('handles very large line numbers', () => {
    const output = '/project/app.ts:999999:content at end of file';
    const result = parseGrepOutput(output);

    const matches = result.get('/project/app.ts')!;
    expect(matches[0].line).toBe(999999);
  });

  it('handles file paths with special characters', () => {
    const output = '/project/src/[component].tsx:10:dynamic route file';
    const result = parseGrepOutput(output);

    expect(result.has('/project/src/[component].tsx')).toBe(true);
  });

  it('handles mixed file-only and file:line:content format', () => {
    const output = [
      '/project/file1.ts:10:with content',
      '/project/file2.ts',
      '/project/file3.ts:20:also with content',
    ].join('\n');

    const result = parseGrepOutput(output);

    expect(result.size).toBe(3);
    expect(result.get('/project/file1.ts')!).toHaveLength(1);
    expect(result.get('/project/file2.ts')!).toHaveLength(0);
    expect(result.get('/project/file3.ts')!).toHaveLength(1);
  });

  it('preserves order of files (first seen)', () => {
    const output = [
      '/project/c.ts:1:third alphabetically',
      '/project/a.ts:1:first alphabetically',
      '/project/b.ts:1:second alphabetically',
    ].join('\n');

    const result = parseGrepOutput(output);
    const files = Array.from(result.keys());

    // Should maintain insertion order (Map preserves order)
    expect(files[0]).toBe('/project/c.ts');
    expect(files[1]).toBe('/project/a.ts');
    expect(files[2]).toBe('/project/b.ts');
  });

  it('handles null/undefined input gracefully', () => {
    expect(parseGrepOutput(null as unknown as string).size).toBe(0);
    expect(parseGrepOutput(undefined as unknown as string).size).toBe(0);
  });

  it('handles realistic grep output', () => {
    const output = [
      '/Users/dev/project/src/components/Button.tsx:15:export function Button({ onClick, children }: ButtonProps) {',
      '/Users/dev/project/src/components/Button.tsx:28:  return <button onClick={onClick}>{children}</button>;',
      '/Users/dev/project/src/components/Input.tsx:10:export function Input({ value, onChange }: InputProps) {',
      '/Users/dev/project/src/hooks/useAuth.ts:25:export function useAuth() {',
      '/Users/dev/project/src/hooks/useAuth.ts:42:  const login = async (credentials: Credentials) => {',
      '/Users/dev/project/src/utils/helpers.ts:8:export function debounce<T extends (...args: unknown[]) => void>(',
    ].join('\n');

    const result = parseGrepOutput(output);

    expect(result.size).toBe(4);
    expect(result.get('/Users/dev/project/src/components/Button.tsx')!).toHaveLength(2);
    expect(result.get('/Users/dev/project/src/components/Input.tsx')!).toHaveLength(1);
    expect(result.get('/Users/dev/project/src/hooks/useAuth.ts')!).toHaveLength(2);
    expect(result.get('/Users/dev/project/src/utils/helpers.ts')!).toHaveLength(1);
  });
});
