/**
 * Tests for the edit formatter.
 *
 * Tests the formatting of edit and multiedit tool arguments and results,
 * including diff formatting and error handling.
 */

import { describe, expect, it } from 'vitest';
import { editFormatter, formatDiff } from './edit.js';

describe('editFormatter', () => {
  describe('tools property', () => {
    it('contains "edit"', () => {
      expect(editFormatter.tools).toContain('edit');
    });

    it('contains "multiedit"', () => {
      expect(editFormatter.tools).toContain('multiedit');
    });

    it('contains exactly two tools', () => {
      expect(editFormatter.tools).toHaveLength(2);
    });
  });

  describe('formatArgs - edit', () => {
    it('shows path in summary', () => {
      const result = editFormatter.formatArgs({
        path: '/Users/test/project/src/app.ts',
        old_text: 'const x = 1;',
        new_text: 'const x = 2;',
      });

      expect(result.summary).toContain('app.ts');
    });

    it('shows "unknown" when path is missing', () => {
      const result = editFormatter.formatArgs({
        old_text: 'const x = 1;',
        new_text: 'const x = 2;',
      });

      expect(result.summary).toBe('unknown');
    });

    it('shows old_text preview in details', () => {
      const result = editFormatter.formatArgs({
        path: '/Users/test/project/src/app.ts',
        old_text: 'const x = 1;',
        new_text: 'const x = 2;',
      });

      expect(result.details).toContainEqual(expect.stringContaining('Match:'));
      expect(result.details).toContainEqual(expect.stringContaining('const x = 1;'));
    });

    it('truncates long old_text in preview', () => {
      const longText = 'a'.repeat(100);
      const result = editFormatter.formatArgs({
        path: '/Users/test/project/src/app.ts',
        old_text: longText,
        new_text: 'replacement',
      });

      // The preview should be truncated with "..."
      const matchLine = result.details.find((line) => line.includes('Match:'));
      expect(matchLine).toBeDefined();
      expect(matchLine).toContain('...');
      // Should not contain the full 100 character string
      expect(matchLine!.length).toBeLessThan(100);
    });

    it('escapes newlines in old_text preview', () => {
      const result = editFormatter.formatArgs({
        path: '/Users/test/project/src/app.ts',
        old_text: 'line1\nline2\nline3',
        new_text: 'replacement',
      });

      const matchLine = result.details.find((line) => line.includes('Match:'));
      expect(matchLine).toContain('\\n');
    });

    it('shows path in details', () => {
      const result = editFormatter.formatArgs({
        path: '/Users/test/project/src/app.ts',
        old_text: 'const x = 1;',
        new_text: 'const x = 2;',
      });

      expect(result.details).toContainEqual(expect.stringContaining('Path:'));
    });

    it('handles missing old_text gracefully', () => {
      const result = editFormatter.formatArgs({
        path: '/Users/test/project/src/app.ts',
        new_text: 'const x = 2;',
      });

      expect(result.summary).toContain('app.ts');
      // Should not have Match line
      const matchLine = result.details.find((line) => line.includes('Match:'));
      expect(matchLine).toBeUndefined();
    });
  });

  describe('formatArgs - multiedit', () => {
    it('shows "path (N edits)" in summary', () => {
      const result = editFormatter.formatArgs({
        path: '/Users/test/project/src/app.ts',
        edits: [
          { old_text: 'const x = 1;', new_text: 'const x = 2;' },
          { old_text: 'const y = 1;', new_text: 'const y = 2;' },
          { old_text: 'const z = 1;', new_text: 'const z = 2;' },
        ],
      });

      expect(result.summary).toContain('app.ts');
      expect(result.summary).toContain('(3 edits)');
    });

    it('shows singular "edit" for single edit', () => {
      const result = editFormatter.formatArgs({
        path: '/Users/test/project/src/app.ts',
        edits: [{ old_text: 'const x = 1;', new_text: 'const x = 2;' }],
      });

      expect(result.summary).toContain('(1 edit)');
    });

    it('shows edit count in details', () => {
      const result = editFormatter.formatArgs({
        path: '/Users/test/project/src/app.ts',
        edits: [
          { old_text: 'const x = 1;', new_text: 'const x = 2;' },
          { old_text: 'const y = 1;', new_text: 'const y = 2;' },
        ],
      });

      expect(result.details).toContainEqual(expect.stringContaining('Edits: 2'));
    });

    it('shows first edit preview in details', () => {
      const result = editFormatter.formatArgs({
        path: '/Users/test/project/src/app.ts',
        edits: [
          { old_text: 'first edit text', new_text: 'replacement1' },
          { old_text: 'second edit text', new_text: 'replacement2' },
        ],
      });

      expect(result.details).toContainEqual(expect.stringContaining('First match:'));
      expect(result.details).toContainEqual(expect.stringContaining('first edit text'));
    });

    it('handles empty edits array', () => {
      const result = editFormatter.formatArgs({
        path: '/Users/test/project/src/app.ts',
        edits: [],
      });

      expect(result.summary).toContain('(0 edits)');
    });

    it('handles edits without old_text', () => {
      const result = editFormatter.formatArgs({
        path: '/Users/test/project/src/app.ts',
        edits: [{ new_text: 'replacement' }],
      });

      expect(result.summary).toContain('(1 edit)');
      // Should not crash, no "First match" line
      const firstMatchLine = result.details.find((line) => line.includes('First match:'));
      expect(firstMatchLine).toBeUndefined();
    });
  });

  describe('formatResult - successful edit', () => {
    it('shows "Applied" in summary', () => {
      const result = editFormatter.formatResult(
        {
          content: [
            {
              type: 'text',
              text: '@@ -1,3 +1,3 @@\n-const x = 1;\n+const x = 2;\n context line',
            },
          ],
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.summary).toContain('\u2713');
      expect(result.summary).toContain('Applied');
    });

    it('shows path in success summary', () => {
      const result = editFormatter.formatResult(
        {
          content: [
            {
              type: 'text',
              text: '@@ -1,3 +1,3 @@\n-const x = 1;\n+const x = 2;\n context line',
            },
          ],
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.summary).toContain('app.ts');
    });

    it('includes diff content in details', () => {
      const diffText = '@@ -1,3 +1,3 @@\n-const x = 1;\n+const x = 2;\n context line';
      const result = editFormatter.formatResult(
        {
          content: [{ type: 'text', text: diffText }],
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.details.length).toBeGreaterThan(0);
    });

    it('preserves lines starting with "-"', () => {
      const diffText = '@@ -1,3 +1,3 @@\n-removed line\n+added line\n context';
      const result = editFormatter.formatResult(
        {
          content: [{ type: 'text', text: diffText }],
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.details).toContainEqual('-removed line');
    });

    it('preserves lines starting with "+"', () => {
      const diffText = '@@ -1,3 +1,3 @@\n-removed line\n+added line\n context';
      const result = editFormatter.formatResult(
        {
          content: [{ type: 'text', text: diffText }],
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.details).toContainEqual('+added line');
    });

    it('preserves context lines', () => {
      const diffText = '@@ -1,3 +1,3 @@\n unchanged context\n-removed\n+added';
      const result = editFormatter.formatResult(
        {
          content: [{ type: 'text', text: diffText }],
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      // Context lines with space prefix should be preserved
      expect(result.details).toContainEqual(' unchanged context');
    });

    it('preserves @@ headers', () => {
      const diffText = '@@ -1,5 +1,6 @@\n context\n-old\n+new';
      const result = editFormatter.formatResult(
        {
          content: [{ type: 'text', text: diffText }],
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.details).toContainEqual('@@ -1,5 +1,6 @@');
    });

    it('sets isError to false for successful edit', () => {
      const result = editFormatter.formatResult(
        {
          content: [{ type: 'text', text: '@@ -1 +1 @@\n-old\n+new' }],
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.isError).toBeFalsy();
    });

    it('handles result without path in args', () => {
      const result = editFormatter.formatResult({
        content: [{ type: 'text', text: '@@ -1 +1 @@\n-old\n+new' }],
      });

      expect(result.summary).toContain('\u2713');
      expect(result.summary).toContain('Applied');
    });
  });

  describe('formatResult - failed edit', () => {
    it('shows "No match found" in summary', () => {
      const result = editFormatter.formatResult(
        {
          content: [{ type: 'text', text: 'No match found for the specified text.' }],
          details: { matched: false },
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.summary).toContain('\u2717');
      expect(result.summary).toContain('No match');
    });

    it('sets isError to true for no match', () => {
      const result = editFormatter.formatResult(
        {
          content: [{ type: 'text', text: 'No match found' }],
          details: { matched: false },
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.isError).toBe(true);
    });

    it('detects "no match" in text content', () => {
      const result = editFormatter.formatResult(
        {
          content: [{ type: 'text', text: 'Error: no match found in file' }],
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.isError).toBe(true);
    });

    it('detects "not found" in text content', () => {
      const result = editFormatter.formatResult(
        {
          content: [{ type: 'text', text: 'The specified text was not found.' }],
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.isError).toBe(true);
    });

    it('handles is_error flag in result', () => {
      const result = editFormatter.formatResult(
        {
          is_error: true,
          content: [{ type: 'text', text: 'Some error occurred' }],
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.isError).toBe(true);
      expect(result.summary).toContain('\u2717');
      expect(result.summary).toContain('Failed');
    });

    it('handles isError flag in result', () => {
      const result = editFormatter.formatResult(
        {
          isError: true,
          content: [{ type: 'text', text: 'Some error occurred' }],
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.isError).toBe(true);
    });

    it('handles error string property', () => {
      const result = editFormatter.formatResult(
        {
          error: 'File not found',
          content: [],
        },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.isError).toBe(true);
    });
  });

  describe('formatResult - multiedit', () => {
    it('shows edit count in summary', () => {
      const result = editFormatter.formatResult(
        {
          content: [
            {
              type: 'text',
              text: '@@ -1 +1 @@\n-old1\n+new1\n@@ -5 +5 @@\n-old2\n+new2',
            },
          ],
        },
        {
          path: '/Users/test/project/src/app.ts',
          edits: [
            { old_text: 'old1', new_text: 'new1' },
            { old_text: 'old2', new_text: 'new2' },
          ],
        }
      );

      expect(result.summary).toContain('2 edits');
    });

    it('shows singular "edit" for single multiedit', () => {
      const result = editFormatter.formatResult(
        {
          content: [{ type: 'text', text: '@@ -1 +1 @@\n-old\n+new' }],
        },
        {
          path: '/Users/test/project/src/app.ts',
          edits: [{ old_text: 'old', new_text: 'new' }],
        }
      );

      expect(result.summary).toContain('1 edit');
      expect(result.summary).not.toContain('1 edits');
    });

    it('aggregates diff info in details', () => {
      const diffText = '@@ -1 +1 @@\n-old1\n+new1\n@@ -10 +10 @@\n-old2\n+new2';
      const result = editFormatter.formatResult(
        {
          content: [{ type: 'text', text: diffText }],
        },
        {
          path: '/Users/test/project/src/app.ts',
          edits: [
            { old_text: 'old1', new_text: 'new1' },
            { old_text: 'old2', new_text: 'new2' },
          ],
        }
      );

      // Should contain both @@ headers
      expect(result.details.some((line) => line.includes('@@ -1'))).toBe(true);
      expect(result.details.some((line) => line.includes('@@ -10'))).toBe(true);
    });
  });

  describe('edge cases', () => {
    it('handles null result', () => {
      const result = editFormatter.formatResult(null, {
        path: '/Users/test/project/src/app.ts',
      });

      // Should not crash
      expect(result.summary).toBeDefined();
    });

    it('handles undefined result', () => {
      const result = editFormatter.formatResult(undefined, {
        path: '/Users/test/project/src/app.ts',
      });

      expect(result.summary).toBeDefined();
    });

    it('handles empty content array', () => {
      const result = editFormatter.formatResult(
        { content: [] },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.summary).toBeDefined();
      expect(result.details).toEqual([]);
    });

    it('handles string result', () => {
      const result = editFormatter.formatResult(
        '@@ -1 +1 @@\n-old\n+new',
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.details.length).toBeGreaterThan(0);
    });

    it('handles result with text property', () => {
      const result = editFormatter.formatResult(
        { text: '@@ -1 +1 @@\n-old\n+new' },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.details.length).toBeGreaterThan(0);
    });

    it('handles result with output property', () => {
      const result = editFormatter.formatResult(
        { output: '@@ -1 +1 @@\n-old\n+new' },
        { path: '/Users/test/project/src/app.ts' }
      );

      expect(result.details.length).toBeGreaterThan(0);
    });

    it('handles no args provided', () => {
      const result = editFormatter.formatResult({
        content: [{ type: 'text', text: '@@ -1 +1 @@\n-old\n+new' }],
      });

      expect(result.summary).toContain('Applied');
    });
  });
});

describe('formatDiff', () => {
  it('returns empty array for empty string', () => {
    const result = formatDiff('');
    expect(result).toEqual([]);
  });

  it('returns empty array for undefined-like input', () => {
    const result = formatDiff(undefined as unknown as string);
    expect(result).toEqual([]);
  });

  it('parses unified diff format correctly', () => {
    const diff = '@@ -1,3 +1,3 @@\n-old line\n+new line\n context';
    const result = formatDiff(diff);

    expect(result).toContain('@@ -1,3 +1,3 @@');
    expect(result).toContain('-old line');
    expect(result).toContain('+new line');
  });

  it('handles diff headers', () => {
    const diff = '@@ -10,5 +10,6 @@\n content';
    const result = formatDiff(diff);

    expect(result[0]).toBe('@@ -10,5 +10,6 @@');
  });

  it('handles removal lines', () => {
    const diff = '-removed line 1\n-removed line 2';
    const result = formatDiff(diff);

    expect(result).toContain('-removed line 1');
    expect(result).toContain('-removed line 2');
  });

  it('handles addition lines', () => {
    const diff = '+added line 1\n+added line 2';
    const result = formatDiff(diff);

    expect(result).toContain('+added line 1');
    expect(result).toContain('+added line 2');
  });

  it('handles context lines with space prefix', () => {
    const diff = ' context line 1\n context line 2';
    const result = formatDiff(diff);

    expect(result).toContain(' context line 1');
    expect(result).toContain(' context line 2');
  });

  it('adds space prefix to other content', () => {
    const diff = 'plain line without prefix';
    const result = formatDiff(diff);

    expect(result).toContain('  plain line without prefix');
  });

  it('truncates long diffs to MAX_DIFF_LINES', () => {
    const lines = [];
    for (let i = 0; i < 20; i++) {
      lines.push(`+line ${i}`);
    }
    const diff = lines.join('\n');
    const result = formatDiff(diff);

    // MAX_DIFF_LINES is 12, plus truncation indicator
    expect(result.length).toBeLessThanOrEqual(13);
    expect(result[result.length - 1]).toContain('more');
  });

  it('removes trailing empty lines', () => {
    const diff = '+added line\n\n\n';
    const result = formatDiff(diff);

    // Should not end with empty strings
    if (result.length > 0) {
      expect(result[result.length - 1]).not.toBe('');
    }
  });

  it('preserves empty lines within diff', () => {
    const diff = '+line1\n\n+line2';
    const result = formatDiff(diff);

    // Empty line in the middle should be preserved
    expect(result).toContain('');
  });

  it('handles Windows line endings (CRLF)', () => {
    const diff = '@@ -1 +1 @@\r\n-old\r\n+new';
    const result = formatDiff(diff);

    expect(result).toContain('@@ -1 +1 @@');
    expect(result).toContain('-old');
    expect(result).toContain('+new');
  });

  it('handles mixed line endings', () => {
    const diff = '-old\r\n+new\n context';
    const result = formatDiff(diff);

    expect(result).toContain('-old');
    expect(result).toContain('+new');
  });

  it('handles multiple @@ headers', () => {
    const diff = '@@ -1 +1 @@\n-old1\n+new1\n@@ -10 +10 @@\n-old2\n+new2';
    const result = formatDiff(diff);

    const headerCount = result.filter((line) => line.startsWith('@@')).length;
    expect(headerCount).toBe(2);
  });

  it('handles complex diff with all line types', () => {
    const diff = [
      '@@ -5,10 +5,12 @@',
      ' context before',
      '-removed line 1',
      '-removed line 2',
      '+added line 1',
      '+added line 2',
      '+added line 3',
      ' context after',
      '@@ -20,3 +22,3 @@',
      ' more context',
      '-another removal',
      '+another addition',
    ].join('\n');

    const result = formatDiff(diff);

    expect(result).toContain('@@ -5,10 +5,12 @@');
    expect(result).toContain(' context before');
    expect(result).toContain('-removed line 1');
    expect(result).toContain('+added line 1');
    expect(result).toContain('@@ -20,3 +22,3 @@');
  });
});
