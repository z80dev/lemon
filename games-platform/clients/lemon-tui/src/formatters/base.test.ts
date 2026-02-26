/**
 * Tests for the base formatter utility functions.
 */

import { describe, it, expect, vi } from 'vitest';
import {
  truncateText,
  truncateLines,
  formatPath,
  formatDuration,
  formatBytes,
  highlightPattern,
  extractText,
  safeStringify,
} from './base.js';
import { homedir } from 'node:os';
import { sep } from 'node:path';

describe('truncateText', () => {
  it('should return text unchanged when shorter than maxLength', () => {
    expect(truncateText('hello', 10)).toBe('hello');
  });

  it('should return text unchanged when exactly at maxLength', () => {
    expect(truncateText('hello', 5)).toBe('hello');
  });

  it('should truncate text with "..." when longer than maxLength', () => {
    expect(truncateText('hello world', 8)).toBe('hello...');
  });

  it('should return empty string for empty input', () => {
    expect(truncateText('', 10)).toBe('');
  });

  it('should handle maxLength = 0', () => {
    expect(truncateText('hello', 0)).toBe('');
  });

  it('should handle maxLength = 1', () => {
    expect(truncateText('hello', 1)).toBe('h');
  });

  it('should handle maxLength = 2', () => {
    expect(truncateText('hello', 2)).toBe('he');
  });

  it('should handle maxLength = 3 (edge case for "...")', () => {
    expect(truncateText('hello', 3)).toBe('hel');
  });

  it('should handle maxLength = 4 (minimum for truncation with "...")', () => {
    expect(truncateText('hello', 4)).toBe('h...');
  });

  it('should handle very long text', () => {
    const longText = 'a'.repeat(1000);
    const result = truncateText(longText, 50);
    expect(result.length).toBe(50);
    expect(result.endsWith('...')).toBe(true);
  });

  it('should preserve exact content when not truncating', () => {
    const text = 'Special chars: !@#$%^&*()';
    expect(truncateText(text, 100)).toBe(text);
  });
});

describe('truncateLines', () => {
  it('should return lines unchanged when fewer than maxLines', () => {
    const lines = ['line1', 'line2'];
    expect(truncateLines(lines, 5)).toEqual(['line1', 'line2']);
  });

  it('should return lines unchanged when exactly at maxLines', () => {
    const lines = ['line1', 'line2', 'line3'];
    expect(truncateLines(lines, 3)).toEqual(['line1', 'line2', 'line3']);
  });

  it('should truncate lines with count message when more than maxLines', () => {
    const lines = ['line1', 'line2', 'line3', 'line4', 'line5'];
    expect(truncateLines(lines, 2)).toEqual(['line1', 'line2', '... (3 more)']);
  });

  it('should return empty array for empty input', () => {
    expect(truncateLines([], 5)).toEqual([]);
  });

  it('should handle maxLines = 0', () => {
    const lines = ['line1', 'line2'];
    expect(truncateLines(lines, 0)).toEqual(['... (2 more)']);
  });

  it('should handle maxLines = 1', () => {
    const lines = ['line1', 'line2', 'line3'];
    expect(truncateLines(lines, 1)).toEqual(['line1', '... (2 more)']);
  });

  it('should not show count message when showCount is false', () => {
    const lines = ['line1', 'line2', 'line3', 'line4'];
    expect(truncateLines(lines, 2, false)).toEqual(['line1', 'line2']);
  });

  it('should show singular "more" for one remaining line', () => {
    const lines = ['line1', 'line2'];
    expect(truncateLines(lines, 1)).toEqual(['line1', '... (1 more)']);
  });

  it('should handle large number of remaining lines', () => {
    const lines = Array.from({ length: 100 }, (_, i) => `line${i + 1}`);
    const result = truncateLines(lines, 5);
    expect(result).toHaveLength(6);
    expect(result[5]).toBe('... (95 more)');
  });

  it('should not modify the original array', () => {
    const lines = ['line1', 'line2', 'line3'];
    const original = [...lines];
    truncateLines(lines, 1);
    expect(lines).toEqual(original);
  });
});

describe('formatPath', () => {
  const home = homedir();

  it('should return relative path when path is within cwd', () => {
    const cwd = '/Users/test/project';
    const path = '/Users/test/project/src/file.ts';
    expect(formatPath(path, cwd)).toBe(`src${sep}file.ts`);
  });

  it('should handle path equal to cwd (returns ~ path or original)', () => {
    // When path equals cwd, relative() returns empty string which is falsy,
    // so it falls through to home directory replacement or returns original path
    const cwd = '/Users/test/project';
    const result = formatPath(cwd, cwd);
    // Result will be ~ prefixed if within home, otherwise original path
    expect(result.startsWith('~') || result === cwd).toBe(true);
  });

  it('should use ~ for home directory when no cwd match', () => {
    const path = `${home}/documents/file.txt`;
    expect(formatPath(path)).toBe('~/documents/file.txt');
  });

  it('should use ~ for home directory when path is not in cwd', () => {
    const cwd = '/var/other';
    const path = `${home}/documents/file.txt`;
    expect(formatPath(path, cwd)).toBe('~/documents/file.txt');
  });

  it('should return empty string for empty path', () => {
    expect(formatPath('')).toBe('');
  });

  it('should return empty string for null-ish path', () => {
    expect(formatPath(null as unknown as string)).toBe('');
    expect(formatPath(undefined as unknown as string)).toBe('');
  });

  it('should handle path with trailing slash', () => {
    const cwd = '/Users/test/project/';
    const path = '/Users/test/project/src/';
    // The function normalizes trailing slashes
    expect(formatPath(path, cwd)).toBe('src');
  });

  it('should return original path when not in cwd and not in home', () => {
    const path = '/var/log/system.log';
    const cwd = '/Users/test';
    // Only return original if not starting with home
    if (!path.startsWith(home)) {
      expect(formatPath(path, cwd)).toBe('/var/log/system.log');
    }
  });

  it('should not use relative path if it goes up too many directories', () => {
    const cwd = '/Users/test/project/deep/nested/dir';
    const path = '/Users/test/other/file.txt';
    // Path would be ../../../../other/file.txt which is more than 3 levels up
    // So it should fall back to ~ or absolute
    const result = formatPath(path, cwd);
    expect(result.startsWith('~') || result.startsWith('/')).toBe(true);
  });

  it('should handle cwd without trailing slash', () => {
    const cwd = '/Users/test/project';
    const path = '/Users/test/project/file.ts';
    expect(formatPath(path, cwd)).toBe('file.ts');
  });
});

describe('formatDuration', () => {
  it('should show milliseconds for durations < 1000ms', () => {
    expect(formatDuration(0)).toBe('0ms');
    expect(formatDuration(1)).toBe('1ms');
    expect(formatDuration(500)).toBe('500ms');
    expect(formatDuration(999)).toBe('999ms');
  });

  it('should show decimal seconds for 1-10 seconds', () => {
    expect(formatDuration(1000)).toBe('1.0s');
    expect(formatDuration(1500)).toBe('1.5s');
    expect(formatDuration(5432)).toBe('5.4s');
    expect(formatDuration(9999)).toBe('10.0s');
  });

  it('should show rounded seconds for 10-60 seconds', () => {
    expect(formatDuration(10000)).toBe('10s');
    expect(formatDuration(15000)).toBe('15s');
    expect(formatDuration(30500)).toBe('31s');
    expect(formatDuration(59999)).toBe('60s');
  });

  it('should show minutes and seconds for >= 60 seconds', () => {
    expect(formatDuration(60000)).toBe('1m');
    expect(formatDuration(90000)).toBe('1m 30s');
    expect(formatDuration(120000)).toBe('2m');
    expect(formatDuration(125000)).toBe('2m 5s');
  });

  it('should handle negative values', () => {
    expect(formatDuration(-1)).toBe('0ms');
    expect(formatDuration(-1000)).toBe('0ms');
  });

  it('should handle zero', () => {
    expect(formatDuration(0)).toBe('0ms');
  });

  it('should handle very large durations', () => {
    expect(formatDuration(3600000)).toBe('60m'); // 1 hour
    expect(formatDuration(3661000)).toBe('61m 1s'); // 1 hour, 1 minute, 1 second
  });

  it('should round milliseconds correctly', () => {
    expect(formatDuration(0.4)).toBe('0ms');
    expect(formatDuration(0.6)).toBe('1ms');
    expect(formatDuration(999.4)).toBe('999ms');
  });

  it('should not show seconds when exactly on the minute', () => {
    expect(formatDuration(60000)).toBe('1m');
    expect(formatDuration(180000)).toBe('3m');
  });
});

describe('formatBytes', () => {
  it('should show bytes for values < 1024', () => {
    expect(formatBytes(0)).toBe('0 B');
    expect(formatBytes(1)).toBe('1 B');
    expect(formatBytes(512)).toBe('512 B');
    expect(formatBytes(1023)).toBe('1023 B');
  });

  it('should show KB with one decimal for small KB values', () => {
    expect(formatBytes(1024)).toBe('1.0 KB');
    expect(formatBytes(1536)).toBe('1.5 KB');
    expect(formatBytes(5120)).toBe('5.0 KB');
    expect(formatBytes(10239)).toBe('10.0 KB');
  });

  it('should show rounded KB for >= 10 KB', () => {
    expect(formatBytes(10240)).toBe('10 KB');
    expect(formatBytes(102400)).toBe('100 KB');
    expect(formatBytes(1048575)).toBe('1024 KB');
  });

  it('should show MB with one decimal for small MB values', () => {
    expect(formatBytes(1048576)).toBe('1.0 MB');
    expect(formatBytes(1572864)).toBe('1.5 MB');
    expect(formatBytes(5242880)).toBe('5.0 MB');
  });

  it('should show rounded MB for >= 10 MB', () => {
    expect(formatBytes(10485760)).toBe('10 MB');
    expect(formatBytes(104857600)).toBe('100 MB');
  });

  it('should show GB for very large values', () => {
    expect(formatBytes(1073741824)).toBe('1.0 GB');
    expect(formatBytes(10737418240)).toBe('10 GB');
  });

  it('should handle negative values', () => {
    expect(formatBytes(-1)).toBe('0 B');
    expect(formatBytes(-1000)).toBe('0 B');
  });

  it('should handle zero', () => {
    expect(formatBytes(0)).toBe('0 B');
  });

  it('should handle exact boundary values', () => {
    expect(formatBytes(1024)).toBe('1.0 KB');
    expect(formatBytes(1048576)).toBe('1.0 MB');
    expect(formatBytes(1073741824)).toBe('1.0 GB');
  });
});

describe('highlightPattern', () => {
  const highlight = (s: string) => `[${s}]`;

  it('should highlight pattern when found', () => {
    expect(highlightPattern('hello world', 'world', highlight)).toBe('hello [world]');
  });

  it('should return text unchanged when pattern not found', () => {
    expect(highlightPattern('hello world', 'foo', highlight)).toBe('hello world');
  });

  it('should highlight multiple matches', () => {
    expect(highlightPattern('foo bar foo baz foo', 'foo', highlight)).toBe(
      '[foo] bar [foo] baz [foo]'
    );
  });

  it('should be case insensitive', () => {
    expect(highlightPattern('Hello HELLO hello', 'hello', highlight)).toBe(
      '[Hello] [HELLO] [hello]'
    );
  });

  it('should return original text for empty pattern', () => {
    expect(highlightPattern('hello world', '', highlight)).toBe('hello world');
  });

  it('should return original text for empty text', () => {
    expect(highlightPattern('', 'pattern', highlight)).toBe('');
  });

  it('should handle special regex characters in pattern', () => {
    expect(highlightPattern('a.b*c?d', '.', highlight)).toBe('a[.]b*c?d');
    expect(highlightPattern('a.b*c?d', '*', highlight)).toBe('a.b[*]c?d');
    expect(highlightPattern('a.b*c?d', '?', highlight)).toBe('a.b*c[?]d');
  });

  it('should handle pattern with parentheses', () => {
    expect(highlightPattern('func(arg)', '(arg)', highlight)).toBe('func[(arg)]');
  });

  it('should handle pattern with brackets', () => {
    expect(highlightPattern('array[0]', '[0]', highlight)).toBe('array[[0]]');
  });

  it('should handle pattern with backslashes', () => {
    expect(highlightPattern('path\\file', '\\', highlight)).toBe('path[\\]file');
  });

  it('should preserve original case in highlighted text', () => {
    const result = highlightPattern('Hello World', 'world', highlight);
    expect(result).toBe('Hello [World]');
  });

  it('should handle adjacent matches', () => {
    expect(highlightPattern('aaa', 'a', highlight)).toBe('[a][a][a]');
  });

  it('should handle overlapping pattern searches (non-overlapping matches)', () => {
    // Note: regex replace is non-overlapping by default
    expect(highlightPattern('aaaa', 'aa', highlight)).toBe('[aa][aa]');
  });
});

describe('extractText', () => {
  it('should return string result as-is', () => {
    expect(extractText('hello world')).toBe('hello world');
  });

  it('should return empty string for null', () => {
    expect(extractText(null)).toBe('');
  });

  it('should return empty string for undefined', () => {
    expect(extractText(undefined)).toBe('');
  });

  it('should convert number to string', () => {
    expect(extractText(42)).toBe('42');
    expect(extractText(3.14)).toBe('3.14');
    expect(extractText(0)).toBe('0');
  });

  it('should convert boolean to string', () => {
    expect(extractText(true)).toBe('true');
    expect(extractText(false)).toBe('false');
  });

  it('should extract text from content blocks array', () => {
    const blocks = [
      { type: 'text', text: 'Hello ' },
      { type: 'text', text: 'World' },
    ];
    expect(extractText(blocks)).toBe('Hello World');
  });

  it('should handle content blocks with images', () => {
    const blocks = [
      { type: 'text', text: 'Image: ' },
      { type: 'image', source: { data: 'base64...' } },
    ];
    expect(extractText(blocks)).toBe('Image: [1 image]');
  });

  it('should handle multiple images', () => {
    const blocks = [
      { type: 'image', source: {} },
      { type: 'image', source: {} },
      { type: 'image', source: {} },
    ];
    expect(extractText(blocks)).toBe('[3 images]');
  });

  it('should extract text from object with content string', () => {
    expect(extractText({ content: 'text content' })).toBe('text content');
  });

  it('should extract text from object with content array', () => {
    const obj = {
      content: [
        { type: 'text', text: 'From array' },
      ],
    };
    expect(extractText(obj)).toBe('From array');
  });

  it('should extract text from object with text field', () => {
    expect(extractText({ text: 'text field value' })).toBe('text field value');
  });

  it('should extract text from object with output field', () => {
    expect(extractText({ output: 'output value' })).toBe('output value');
  });

  it('should extract text from object with message field', () => {
    expect(extractText({ message: 'message value' })).toBe('message value');
  });

  it('should prioritize content over text field', () => {
    expect(extractText({ content: 'content', text: 'text' })).toBe('content');
  });

  it('should prioritize text over output field', () => {
    expect(extractText({ text: 'text', output: 'output' })).toBe('text');
  });

  it('should return empty string for object without recognized fields', () => {
    expect(extractText({ foo: 'bar', baz: 123 })).toBe('');
  });

  it('should handle empty content blocks array', () => {
    expect(extractText([])).toBe('');
  });

  it('should skip non-text, non-image blocks', () => {
    const blocks = [
      { type: 'text', text: 'Hello' },
      { type: 'tool_use', name: 'bash' },
      { type: 'text', text: ' World' },
    ];
    expect(extractText(blocks)).toBe('Hello World');
  });

  it('should handle content blocks with missing text field', () => {
    const blocks = [
      { type: 'text' }, // Missing text field
      { type: 'text', text: 'Valid' },
    ];
    expect(extractText(blocks)).toBe('Valid');
  });

  it('should handle nested structure with content array', () => {
    const obj = {
      content: [
        { type: 'text', text: 'Line 1\n' },
        { type: 'text', text: 'Line 2' },
      ],
    };
    expect(extractText(obj)).toBe('Line 1\nLine 2');
  });

  it('should handle array with null or non-object elements', () => {
    const blocks = [
      null,
      { type: 'text', text: 'Valid' },
      'string element',
      123,
    ];
    expect(extractText(blocks)).toBe('Valid');
  });
});

describe('safeStringify', () => {
  it('should stringify simple objects', () => {
    expect(safeStringify({ a: 1, b: 'two' })).toBe('{"a":1,"b":"two"}');
  });

  it('should stringify arrays', () => {
    expect(safeStringify([1, 2, 3])).toBe('[1,2,3]');
  });

  it('should stringify nested objects', () => {
    const obj = { outer: { inner: { deep: 'value' } } };
    expect(safeStringify(obj)).toBe('{"outer":{"inner":{"deep":"value"}}}');
  });

  it('should return "null" for null', () => {
    expect(safeStringify(null)).toBe('null');
  });

  it('should return "undefined" for undefined', () => {
    expect(safeStringify(undefined)).toBe('undefined');
  });

  it('should handle circular references', () => {
    const obj: Record<string, unknown> = { a: 1 };
    obj.self = obj;
    expect(safeStringify(obj)).toBe('{"a":1,"self":"[Circular]"}');
  });

  it('should handle deeply nested circular references', () => {
    const obj: Record<string, unknown> = { a: { b: { c: {} } } };
    ((obj.a as Record<string, unknown>).b as Record<string, unknown>).c = obj;
    const result = safeStringify(obj);
    expect(result).toContain('[Circular]');
  });

  it('should handle NaN', () => {
    // JSON.stringify converts NaN to null
    expect(safeStringify({ value: NaN })).toBe('{"value":null}');
  });

  it('should handle Infinity', () => {
    // JSON.stringify converts Infinity to null
    expect(safeStringify({ value: Infinity })).toBe('{"value":null}');
    expect(safeStringify({ value: -Infinity })).toBe('{"value":null}');
  });

  it('should handle bigint values', () => {
    expect(safeStringify({ big: BigInt(12345678901234567890n) })).toBe(
      '{"big":"12345678901234567890"}'
    );
  });

  it('should handle function values', () => {
    expect(safeStringify({ fn: () => {} })).toBe('{"fn":"[Function]"}');
  });

  it('should handle symbol values', () => {
    expect(safeStringify({ sym: Symbol('test') })).toBe('{"sym":"Symbol(test)"}');
  });

  it('should stringify strings', () => {
    expect(safeStringify('hello')).toBe('"hello"');
  });

  it('should stringify numbers', () => {
    expect(safeStringify(42)).toBe('42');
    expect(safeStringify(3.14)).toBe('3.14');
  });

  it('should stringify booleans', () => {
    expect(safeStringify(true)).toBe('true');
    expect(safeStringify(false)).toBe('false');
  });

  it('should handle empty objects and arrays', () => {
    expect(safeStringify({})).toBe('{}');
    expect(safeStringify([])).toBe('[]');
  });

  it('should handle objects with undefined values', () => {
    // JSON.stringify omits undefined values in objects
    const obj = { a: 1, b: undefined, c: 'three' };
    expect(safeStringify(obj)).toBe('{"a":1,"c":"three"}');
  });

  it('should handle arrays with undefined values', () => {
    // JSON.stringify converts undefined in arrays to null
    expect(safeStringify([1, undefined, 3])).toBe('[1,null,3]');
  });

  it('should handle mixed complex structure', () => {
    const obj = {
      string: 'hello',
      number: 42,
      bool: true,
      array: [1, 2, 3],
      nested: { a: 1 },
    };
    const result = JSON.parse(safeStringify(obj));
    expect(result.string).toBe('hello');
    expect(result.number).toBe(42);
    expect(result.bool).toBe(true);
    expect(result.array).toEqual([1, 2, 3]);
    expect(result.nested.a).toBe(1);
  });

  it('should handle Date objects', () => {
    const date = new Date('2024-01-15T12:00:00Z');
    const result = safeStringify({ date });
    expect(result).toBe('{"date":"2024-01-15T12:00:00.000Z"}');
  });

  it('should handle Map and Set (converted to empty objects by JSON.stringify)', () => {
    // Note: JSON.stringify does not serialize Map/Set contents
    expect(safeStringify(new Map([['a', 1]]))).toBe('{}');
    expect(safeStringify(new Set([1, 2, 3]))).toBe('{}');
  });
});
