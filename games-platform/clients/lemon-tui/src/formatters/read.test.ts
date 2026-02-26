/**
 * Tests for the read formatter.
 */

import { describe, it, expect } from 'vitest';
import { readFormatter } from './read.js';

describe('readFormatter', () => {
  describe('tools property', () => {
    it('should contain read', () => {
      expect(readFormatter.tools).toContain('read');
    });

    it('should only contain read', () => {
      expect(readFormatter.tools).toHaveLength(1);
    });
  });

  describe('formatArgs', () => {
    it('should show shortened path in summary using path field', () => {
      const result = readFormatter.formatArgs({ path: '/home/user/project/src/index.ts' });

      // Path should be formatted (may use ~ for home dir)
      expect(result.summary).toBeTruthy();
      expect(result.summary).toContain('index.ts');
    });

    it('should show shortened path using file_path field', () => {
      const result = readFormatter.formatArgs({ file_path: '/home/user/project/src/app.tsx' });

      expect(result.summary).toBeTruthy();
      expect(result.summary).toContain('app.tsx');
    });

    it('should prefer path over file_path when both present', () => {
      const result = readFormatter.formatArgs({
        path: '/path/from/path.ts',
        file_path: '/path/from/file_path.ts',
      });

      expect(result.summary).toContain('path.ts');
    });

    it('should show offset when provided', () => {
      const result = readFormatter.formatArgs({
        path: '/test/file.ts',
        offset: 100,
      });

      expect(result.summary).toContain('offset=100');
    });

    it('should show limit when provided', () => {
      const result = readFormatter.formatArgs({
        path: '/test/file.ts',
        limit: 50,
      });

      expect(result.summary).toContain('limit=50');
    });

    it('should show both offset and limit when provided', () => {
      const result = readFormatter.formatArgs({
        path: '/test/file.ts',
        offset: 100,
        limit: 50,
      });

      expect(result.summary).toContain('offset=100');
      expect(result.summary).toContain('limit=50');
    });

    it('should handle long path', () => {
      const longPath =
        '/very/long/path/to/some/deeply/nested/directory/structure/in/a/project/src/components/ui/Button.tsx';
      const result = readFormatter.formatArgs({ path: longPath });

      // Should contain the filename
      expect(result.summary).toContain('Button.tsx');
    });

    it('should handle empty path gracefully', () => {
      const result = readFormatter.formatArgs({ path: '' });

      expect(result.summary).toBe('');
    });

    it('should handle missing path gracefully', () => {
      const result = readFormatter.formatArgs({});

      expect(result.summary).toBe('');
    });

    it('should include summary in details', () => {
      const result = readFormatter.formatArgs({ path: '/test/file.ts' });

      expect(result.details).toContain(result.summary);
    });
  });

  describe('formatResult - text content', () => {
    it('should show line count and content for single line', () => {
      const result = readFormatter.formatResult({
        content: [{ type: 'text', text: 'export const foo = "bar";' }],
      });

      expect(result.summary).toContain('1 line');
      expect(result.details.join('\n')).toContain('export const foo = "bar";');
    });

    it('should show line count for multiple lines', () => {
      const text = 'line 1\nline 2\nline 3\nline 4\nline 5';
      const result = readFormatter.formatResult({
        content: [{ type: 'text', text }],
      });

      expect(result.summary).toContain('5 lines');
    });

    it('should show line numbers in preview', () => {
      const text = 'const a = 1;\nconst b = 2;\nconst c = 3;';
      const result = readFormatter.formatResult({
        content: [{ type: 'text', text }],
      });

      // Should have line numbers like "1| const a = 1;"
      expect(result.details[0]).toMatch(/^\s*1\|/);
      expect(result.details[1]).toMatch(/^\s*2\|/);
      expect(result.details[2]).toMatch(/^\s*3\|/);
    });

    it('should show "more lines" indicator when truncated', () => {
      const lines = Array.from({ length: 20 }, (_, i) => `Line ${i + 1}`);
      const result = readFormatter.formatResult({
        content: [{ type: 'text', text: lines.join('\n') }],
      });

      // Default preview is 8 lines, so should show 12 more
      expect(result.details[result.details.length - 1]).toMatch(/\.\.\. \(12 more lines\)/);
    });

    it('should show byte size estimate in summary', () => {
      const text = 'Some content that has a certain byte size';
      const result = readFormatter.formatResult({
        content: [{ type: 'text', text }],
      });

      // Should show byte size
      expect(result.summary).toMatch(/\d+ B|KB|MB/);
    });

    it('should correctly count lines with Windows line endings', () => {
      const text = 'line 1\r\nline 2\r\nline 3';
      const result = readFormatter.formatResult({
        content: [{ type: 'text', text }],
      });

      expect(result.summary).toContain('3 lines');
    });

    it('should respect offset when formatting line numbers', () => {
      const text = 'function foo() {\n  return bar;\n}';
      const result = readFormatter.formatResult(
        { content: [{ type: 'text', text }] },
        { offset: 99 }
      );

      // Line numbers should start from 100 (offset + 1)
      expect(result.details[0]).toMatch(/100\|/);
      expect(result.details[1]).toMatch(/101\|/);
    });

    it('should handle plain string result', () => {
      const result = readFormatter.formatResult('console.log("hello")');

      expect(result.summary).toContain('1 line');
      expect(result.details.join('\n')).toContain('console.log("hello")');
    });
  });

  describe('formatResult - image content', () => {
    it('should show image indicator for image block', () => {
      const result = readFormatter.formatResult({
        content: [{ type: 'image', media_type: 'image/png' }],
      });

      expect(result.summary).toBe('[Image: image/png]');
      expect(result.details[0]).toContain('Image content');
      expect(result.details[0]).toContain('image/png');
    });

    it('should handle image without media_type', () => {
      const result = readFormatter.formatResult({
        content: [{ type: 'image' }],
      });

      expect(result.summary).toBe('[Image: image]');
    });

    it('should handle various image mime types', () => {
      const mimeTypes = ['image/jpeg', 'image/gif', 'image/webp', 'image/svg+xml'];

      for (const mimeType of mimeTypes) {
        const result = readFormatter.formatResult({
          content: [{ type: 'image', media_type: mimeType }],
        });

        expect(result.summary).toBe(`[Image: ${mimeType}]`);
      }
    });

    it('should show image summary when text is empty', () => {
      const result = readFormatter.formatResult({
        content: [
          { type: 'text', text: '' },
          { type: 'image', media_type: 'image/png' },
        ],
      });

      expect(result.summary).toBe('[Image: image/png]');
    });

    it('should show image summary when text is only whitespace', () => {
      const result = readFormatter.formatResult({
        content: [
          { type: 'text', text: '   \n\t  ' },
          { type: 'image', media_type: 'image/png' },
        ],
      });

      expect(result.summary).toBe('[Image: image/png]');
    });
  });

  describe('formatResult - mixed content', () => {
    it('should prioritize text content over image when text is present', () => {
      const result = readFormatter.formatResult({
        content: [
          { type: 'text', text: 'Some text content' },
          { type: 'image', media_type: 'image/png' },
        ],
      });

      // Should show text info, not image
      expect(result.summary).toContain('line');
      expect(result.summary).not.toBe('[Image: image/png]');
    });
  });

  describe('formatResult - edge cases', () => {
    it('should handle empty content', () => {
      const result = readFormatter.formatResult({
        content: [{ type: 'text', text: '' }],
      });

      expect(result.summary).toBe('(empty file)');
      expect(result.details).toHaveLength(0);
    });

    it('should handle null result', () => {
      const result = readFormatter.formatResult(null);

      expect(result.summary).toBe('(empty file)');
    });

    it('should handle undefined result', () => {
      const result = readFormatter.formatResult(undefined);

      expect(result.summary).toBe('(empty file)');
    });

    it('should handle empty content array', () => {
      const result = readFormatter.formatResult({
        content: [],
      });

      expect(result.summary).toBe('(empty file)');
    });

    it('should handle very long lines', () => {
      const longLine = 'x'.repeat(500);
      const result = readFormatter.formatResult({
        content: [{ type: 'text', text: longLine }],
      });

      expect(result.summary).toContain('1 line');
      // The line should still be included (truncation is UI's responsibility)
      expect(result.details[0]).toContain('1|');
    });

    it('should handle special characters', () => {
      const text = 'const emoji = "🎉";\nconst special = "<>&\\n\\t";';
      const result = readFormatter.formatResult({
        content: [{ type: 'text', text }],
      });

      expect(result.details.join('\n')).toContain('emoji');
      expect(result.details.join('\n')).toContain('special');
    });

    it('should handle unicode content', () => {
      const text = '// 日本語コメント\nconst greeting = "こんにちは";';
      const result = readFormatter.formatResult({
        content: [{ type: 'text', text }],
      });

      expect(result.summary).toContain('2 lines');
      expect(result.details.join('\n')).toContain('日本語');
    });

    it('should pad line numbers correctly for large files', () => {
      const lines = Array.from({ length: 100 }, (_, i) => `Line ${i + 1}`);
      const result = readFormatter.formatResult(
        { content: [{ type: 'text', text: lines.join('\n') }] },
        { offset: 99 }
      );

      // Line numbers 100-108 should be padded to 3 digits
      expect(result.details[0]).toMatch(/100\|/);
    });
  });

  describe('formatResult - realistic scenarios', () => {
    it('should format TypeScript source file', () => {
      const tsContent = `import React from 'react';

interface Props {
  name: string;
  onClick: () => void;
}

export const Button: React.FC<Props> = ({ name, onClick }) => {
  return (
    <button onClick={onClick}>
      {name}
    </button>
  );
};`;

      const result = readFormatter.formatResult({
        content: [{ type: 'text', text: tsContent }],
      });

      expect(result.summary).toContain('14 lines');
      expect(result.details[0]).toMatch(/1\|.*import React/);
    });

    it('should format JSON file', () => {
      const jsonContent = `{
  "name": "my-package",
  "version": "1.0.0",
  "dependencies": {
    "react": "^18.0.0"
  }
}`;

      const result = readFormatter.formatResult({
        content: [{ type: 'text', text: jsonContent }],
      });

      expect(result.summary).toContain('7 lines');
    });

    it('should format package.json preview correctly', () => {
      const content = `{
  "name": "lemon-tui",
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "test": "vitest"
  },
  "dependencies": {
    "react": "^18.0.0",
    "ink": "^4.0.0"
  }
}`;

      const result = readFormatter.formatResult({
        content: [{ type: 'text', text: content }],
      });

      // Should show first 8 lines in preview
      expect(result.details.length).toBeLessThanOrEqual(9); // 8 lines + "more" indicator
      expect(result.details[result.details.length - 1]).toMatch(/\.\.\. \(\d+ more lines\)/);
    });

    it('should format markdown file', () => {
      const mdContent = `# Project Title

## Installation

\`\`\`bash
npm install
\`\`\`

## Usage

Import the component:

\`\`\`tsx
import { Component } from './Component';
\`\`\``;

      const result = readFormatter.formatResult({
        content: [{ type: 'text', text: mdContent }],
      });

      expect(result.summary).toContain('15 lines');
    });

    it('should format screenshot/image read result', () => {
      const result = readFormatter.formatResult({
        content: [
          {
            type: 'image',
            media_type: 'image/png',
          },
        ],
      });

      expect(result.summary).toBe('[Image: image/png]');
    });

    it('should format binary file indicator', () => {
      // When reading a binary file, the content might be empty or have image type
      const result = readFormatter.formatResult({
        content: [{ type: 'image', media_type: 'application/octet-stream' }],
      });

      expect(result.summary).toContain('application/octet-stream');
    });
  });

  describe('formatResult - byte size formatting', () => {
    it('should show bytes for small files', () => {
      const result = readFormatter.formatResult({
        content: [{ type: 'text', text: 'small' }],
      });

      expect(result.summary).toMatch(/\d+ B/);
    });

    it('should show KB for larger files', () => {
      // Create content > 1KB
      const text = 'x'.repeat(1500);
      const result = readFormatter.formatResult({
        content: [{ type: 'text', text }],
      });

      expect(result.summary).toMatch(/KB/);
    });
  });
});
