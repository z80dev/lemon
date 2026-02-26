/**
 * Tests for the FormatterRegistry.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { FormatterRegistry, defaultRegistry } from './index.js';
import type { ToolFormatter, FormattedOutput } from './types.js';

/**
 * Creates a mock formatter for testing.
 */
function createMockFormatter(
  tools: string[],
  options: {
    argsResult?: FormattedOutput;
    resultResult?: FormattedOutput;
    partialResult?: FormattedOutput;
    argsThrows?: boolean;
    resultThrows?: boolean;
    partialThrows?: boolean;
  } = {}
): ToolFormatter {
  const defaultArgs: FormattedOutput = {
    summary: 'mock args summary',
    details: ['mock args detail'],
  };

  const defaultResult: FormattedOutput = {
    summary: 'mock result summary',
    details: ['mock result detail'],
  };

  return {
    tools,
    formatArgs: (args) => {
      if (options.argsThrows) {
        throw new Error('formatArgs error');
      }
      return options.argsResult ?? defaultArgs;
    },
    formatResult: (result, args) => {
      if (options.resultThrows) {
        throw new Error('formatResult error');
      }
      return options.resultResult ?? defaultResult;
    },
    ...(options.partialResult || options.partialThrows
      ? {
          formatPartial: (partial, args) => {
            if (options.partialThrows) {
              throw new Error('formatPartial error');
            }
            return options.partialResult!;
          },
        }
      : {}),
  };
}

describe('FormatterRegistry', () => {
  let registry: FormatterRegistry;

  beforeEach(() => {
    registry = new FormatterRegistry();
  });

  describe('register(formatter)', () => {
    it('should register a formatter for a single tool', () => {
      const formatter = createMockFormatter(['mytool']);
      registry.register(formatter);

      expect(registry.hasFormatter('mytool')).toBe(true);
      expect(registry.getFormatter('mytool')).toBe(formatter);
    });

    it('should register a formatter for multiple tools', () => {
      const formatter = createMockFormatter(['tool1', 'tool2', 'tool3']);
      registry.register(formatter);

      expect(registry.hasFormatter('tool1')).toBe(true);
      expect(registry.hasFormatter('tool2')).toBe(true);
      expect(registry.hasFormatter('tool3')).toBe(true);
      expect(registry.getFormatter('tool1')).toBe(formatter);
      expect(registry.getFormatter('tool2')).toBe(formatter);
      expect(registry.getFormatter('tool3')).toBe(formatter);
    });

    it('should overwrite existing registration when registering same tool', () => {
      const formatter1 = createMockFormatter(['mytool']);
      const formatter2 = createMockFormatter(['mytool']);

      registry.register(formatter1);
      expect(registry.getFormatter('mytool')).toBe(formatter1);

      registry.register(formatter2);
      expect(registry.getFormatter('mytool')).toBe(formatter2);
    });

    it('should allow multiple formatters for different tools', () => {
      const formatter1 = createMockFormatter(['tool1']);
      const formatter2 = createMockFormatter(['tool2']);

      registry.register(formatter1);
      registry.register(formatter2);

      expect(registry.getFormatter('tool1')).toBe(formatter1);
      expect(registry.getFormatter('tool2')).toBe(formatter2);
    });
  });

  describe('unregister(formatter)', () => {
    it('should remove formatter registration', () => {
      const formatter = createMockFormatter(['mytool']);
      registry.register(formatter);
      expect(registry.hasFormatter('mytool')).toBe(true);

      registry.unregister(formatter);
      expect(registry.hasFormatter('mytool')).toBe(false);
    });

    it('should remove all tool mappings for formatter with multiple tools', () => {
      const formatter = createMockFormatter(['tool1', 'tool2', 'tool3']);
      registry.register(formatter);

      registry.unregister(formatter);

      expect(registry.hasFormatter('tool1')).toBe(false);
      expect(registry.hasFormatter('tool2')).toBe(false);
      expect(registry.hasFormatter('tool3')).toBe(false);
    });

    it('should handle unregistering non-existent formatter gracefully', () => {
      const formatter = createMockFormatter(['unknown']);

      // Should not throw
      expect(() => registry.unregister(formatter)).not.toThrow();
    });

    it('should only unregister if the current registration matches the formatter', () => {
      const formatter1 = createMockFormatter(['mytool']);
      const formatter2 = createMockFormatter(['mytool']);

      registry.register(formatter1);
      registry.register(formatter2); // Overwrites formatter1

      // Trying to unregister formatter1 should not remove formatter2
      registry.unregister(formatter1);
      expect(registry.hasFormatter('mytool')).toBe(true);
      expect(registry.getFormatter('mytool')).toBe(formatter2);
    });
  });

  describe('getFormatter(toolName)', () => {
    it('should return registered formatter', () => {
      const formatter = createMockFormatter(['mytool']);
      registry.register(formatter);

      expect(registry.getFormatter('mytool')).toBe(formatter);
    });

    it('should return undefined for unknown tool', () => {
      expect(registry.getFormatter('unknowntool')).toBeUndefined();
    });

    it('should return undefined after formatter is unregistered', () => {
      const formatter = createMockFormatter(['mytool']);
      registry.register(formatter);
      registry.unregister(formatter);

      expect(registry.getFormatter('mytool')).toBeUndefined();
    });
  });

  describe('hasFormatter(toolName)', () => {
    it('should return true for registered tool', () => {
      const formatter = createMockFormatter(['mytool']);
      registry.register(formatter);

      expect(registry.hasFormatter('mytool')).toBe(true);
    });

    it('should return false for unregistered tool', () => {
      expect(registry.hasFormatter('unknowntool')).toBe(false);
    });

    it('should return false after unregistration', () => {
      const formatter = createMockFormatter(['mytool']);
      registry.register(formatter);
      registry.unregister(formatter);

      expect(registry.hasFormatter('mytool')).toBe(false);
    });
  });

  describe('getRegisteredTools()', () => {
    it('should return empty array when no formatters registered', () => {
      expect(registry.getRegisteredTools()).toEqual([]);
    });

    it('should return all registered tool names', () => {
      const formatter1 = createMockFormatter(['tool1', 'tool2']);
      const formatter2 = createMockFormatter(['tool3']);

      registry.register(formatter1);
      registry.register(formatter2);

      const tools = registry.getRegisteredTools();
      expect(tools).toHaveLength(3);
      expect(tools).toContain('tool1');
      expect(tools).toContain('tool2');
      expect(tools).toContain('tool3');
    });

    it('should not include unregistered tools', () => {
      const formatter = createMockFormatter(['tool1', 'tool2']);
      registry.register(formatter);
      registry.unregister(formatter);

      expect(registry.getRegisteredTools()).toEqual([]);
    });
  });

  describe('formatArgs(toolName, args)', () => {
    it('should use registered formatter', () => {
      const customOutput: FormattedOutput = {
        summary: 'custom summary',
        details: ['custom detail 1', 'custom detail 2'],
      };
      const formatter = createMockFormatter(['mytool'], { argsResult: customOutput });
      registry.register(formatter);

      const result = registry.formatArgs('mytool', { key: 'value' });
      expect(result).toEqual(customOutput);
    });

    it('should fall back to default for unknown tool', () => {
      const result = registry.formatArgs('unknowntool', { key: 'value' });

      expect(result.summary).toContain('key');
      expect(result.details).toBeDefined();
      expect(Array.isArray(result.details)).toBe(true);
    });

    it('should handle empty args', () => {
      const result = registry.formatArgs('unknowntool', {});

      expect(result.summary).toBe('(no arguments)');
      expect(result.details).toEqual([]);
    });

    it('should handle null-like args', () => {
      // @ts-expect-error - Testing edge case with null
      const resultNull = registry.formatArgs('unknowntool', null);
      expect(resultNull.summary).toBe('(no arguments)');

      // @ts-expect-error - Testing edge case with undefined
      const resultUndefined = registry.formatArgs('unknowntool', undefined);
      expect(resultUndefined.summary).toBe('(no arguments)');
    });

    it('should fall back to default when formatter throws', () => {
      const formatter = createMockFormatter(['mytool'], { argsThrows: true });
      registry.register(formatter);

      const result = registry.formatArgs('mytool', { key: 'value' });

      // Should return default formatting, not throw
      expect(result.summary).toContain('key');
    });

    it('should format each key-value pair in details', () => {
      const result = registry.formatArgs('unknowntool', {
        command: 'ls -la',
        timeout: 5000,
        verbose: true,
      });

      expect(result.details.some((d) => d.includes('command:'))).toBe(true);
      expect(result.details.some((d) => d.includes('timeout:'))).toBe(true);
      expect(result.details.some((d) => d.includes('verbose:'))).toBe(true);
    });
  });

  describe('formatResult(toolName, result, args)', () => {
    it('should use registered formatter', () => {
      const customOutput: FormattedOutput = {
        summary: 'custom result',
        details: ['result line 1'],
        isError: false,
      };
      const formatter = createMockFormatter(['mytool'], { resultResult: customOutput });
      registry.register(formatter);

      const result = registry.formatResult('mytool', 'some output', { key: 'value' });
      expect(result).toEqual(customOutput);
    });

    it('should fall back to default for unknown tool', () => {
      const result = registry.formatResult('unknowntool', 'hello world');

      expect(result.summary).toContain('hello');
      expect(result.details).toBeDefined();
    });

    it('should handle null result', () => {
      const result = registry.formatResult('unknowntool', null);

      expect(result.summary).toBe('(no result)');
      expect(result.details).toEqual([]);
    });

    it('should handle undefined result', () => {
      const result = registry.formatResult('unknowntool', undefined);

      expect(result.summary).toBe('(no result)');
      expect(result.details).toEqual([]);
    });

    it('should handle object result with text content', () => {
      const result = registry.formatResult('unknowntool', { text: 'extracted text' });

      expect(result.summary).toContain('extracted text');
    });

    it('should handle object result with content field', () => {
      const result = registry.formatResult('unknowntool', { content: 'content text' });

      expect(result.summary).toContain('content text');
    });

    it('should handle array of content blocks', () => {
      const result = registry.formatResult('unknowntool', [
        { type: 'text', text: 'first block' },
        { type: 'text', text: ' second block' },
      ]);

      expect(result.summary).toContain('first block');
    });

    it('should detect error results with is_error flag', () => {
      const result = registry.formatResult('unknowntool', {
        is_error: true,
        message: 'Something went wrong',
      });

      expect(result.isError).toBe(true);
    });

    it('should detect error results with isError flag', () => {
      const result = registry.formatResult('unknowntool', {
        isError: true,
        text: 'Error occurred',
      });

      expect(result.isError).toBe(true);
    });

    it('should detect error results with error field', () => {
      const result = registry.formatResult('unknowntool', {
        error: 'File not found',
      });

      expect(result.isError).toBe(true);
    });

    it('should not mark non-error objects as errors', () => {
      const result = registry.formatResult('unknowntool', {
        success: true,
        data: 'some data',
      });

      expect(result.isError).toBeFalsy();
    });

    it('should fall back to default when formatter throws', () => {
      const formatter = createMockFormatter(['mytool'], { resultThrows: true });
      registry.register(formatter);

      const result = registry.formatResult('mytool', 'test output');

      // Should return default formatting, not throw
      expect(result.summary).toContain('test output');
    });

    it('should pass args to formatter', () => {
      let receivedArgs: Record<string, unknown> | undefined;
      const formatter: ToolFormatter = {
        tools: ['mytool'],
        formatArgs: () => ({ summary: '', details: [] }),
        formatResult: (result, args) => {
          receivedArgs = args;
          return { summary: '', details: [] };
        },
      };
      registry.register(formatter);

      registry.formatResult('mytool', 'output', { path: '/test.txt' });

      expect(receivedArgs).toEqual({ path: '/test.txt' });
    });
  });

  describe('formatPartial(toolName, partial, args)', () => {
    it('should use formatPartial when formatter has it', () => {
      const partialOutput: FormattedOutput = {
        summary: 'partial output',
        details: ['streaming...'],
      };
      const formatter = createMockFormatter(['mytool'], { partialResult: partialOutput });
      registry.register(formatter);

      const result = registry.formatPartial('mytool', 'partial data');
      expect(result).toEqual(partialOutput);
    });

    it('should fall back to formatResult when no formatPartial', () => {
      const resultOutput: FormattedOutput = {
        summary: 'result output',
        details: ['from result'],
      };
      const formatter = createMockFormatter(['mytool'], { resultResult: resultOutput });
      registry.register(formatter);

      const result = registry.formatPartial('mytool', 'partial data');
      expect(result).toEqual(resultOutput);
    });

    it('should fall back to default for unknown tool', () => {
      const result = registry.formatPartial('unknowntool', 'streaming data');

      expect(result.summary).toContain('streaming data');
    });

    it('should fall back to default when formatPartial throws', () => {
      const formatter = createMockFormatter(['mytool'], { partialThrows: true });
      registry.register(formatter);

      const result = registry.formatPartial('mytool', 'test data');

      // Should return default formatting, not throw
      expect(result.summary).toContain('test data');
    });

    it('should fall back to default when formatResult throws (no formatPartial)', () => {
      const formatter = createMockFormatter(['mytool'], { resultThrows: true });
      registry.register(formatter);

      const result = registry.formatPartial('mytool', 'test data');

      // Should return default formatting, not throw
      expect(result.summary).toContain('test data');
    });

    it('should pass args to formatPartial', () => {
      let receivedArgs: Record<string, unknown> | undefined;
      const formatter: ToolFormatter = {
        tools: ['mytool'],
        formatArgs: () => ({ summary: '', details: [] }),
        formatResult: () => ({ summary: '', details: [] }),
        formatPartial: (partial, args) => {
          receivedArgs = args;
          return { summary: '', details: [] };
        },
      };
      registry.register(formatter);

      registry.formatPartial('mytool', 'partial', { key: 'value' });

      expect(receivedArgs).toEqual({ key: 'value' });
    });
  });

  describe('default formatting behavior', () => {
    it('should produce valid FormattedOutput for default formatArgs', () => {
      const result = registry.formatArgs('unknown', { test: 'value' });

      expect(result).toHaveProperty('summary');
      expect(result).toHaveProperty('details');
      expect(typeof result.summary).toBe('string');
      expect(Array.isArray(result.details)).toBe(true);
    });

    it('should produce valid FormattedOutput for default formatResult', () => {
      const result = registry.formatResult('unknown', { data: 123 });

      expect(result).toHaveProperty('summary');
      expect(result).toHaveProperty('details');
      expect(typeof result.summary).toBe('string');
      expect(Array.isArray(result.details)).toBe(true);
    });

    it('should truncate long summary text', () => {
      const longText = 'a'.repeat(500);
      const result = registry.formatResult('unknown', longText);

      expect(result.summary.length).toBeLessThanOrEqual(203); // 200 + "..."
      expect(result.summary).toContain('...');
    });

    it('should truncate long details', () => {
      const manyLines = Array(50)
        .fill('line')
        .map((_, i) => `line ${i}`);
      const result = registry.formatResult('unknown', manyLines.join('\n'));

      // Default max lines is 20, plus 1 for "... (N more)"
      expect(result.details.length).toBeLessThanOrEqual(21);
      expect(result.details[result.details.length - 1]).toContain('more');
    });

    it('should format JSON properly', () => {
      const result = registry.formatArgs('unknown', {
        nested: { a: 1, b: 2 },
        array: [1, 2, 3],
      });

      // Summary should be JSON-like
      expect(result.summary).toContain('nested');
      expect(result.summary).toContain('array');
    });

    it('should handle multiline string results', () => {
      const multiline = 'line1\nline2\nline3';
      const result = registry.formatResult('unknown', multiline);

      expect(result.details.length).toBe(3);
      expect(result.details[0]).toContain('line1');
      expect(result.details[1]).toContain('line2');
      expect(result.details[2]).toContain('line3');
    });

    it('should handle number results', () => {
      const result = registry.formatResult('unknown', 42);

      expect(result.summary).toBe('42');
    });

    it('should handle boolean results', () => {
      const resultTrue = registry.formatResult('unknown', true);
      expect(resultTrue.summary).toBe('true');

      const resultFalse = registry.formatResult('unknown', false);
      expect(resultFalse.summary).toBe('false');
    });
  });

  describe('defaultRegistry', () => {
    it('should be a FormatterRegistry instance', () => {
      expect(defaultRegistry).toBeInstanceOf(FormatterRegistry);
    });

    it('should have bash formatter registered', () => {
      expect(defaultRegistry.hasFormatter('bash')).toBe(true);
      expect(defaultRegistry.hasFormatter('exec')).toBe(true);
    });

    it('should have read formatter registered', () => {
      expect(defaultRegistry.hasFormatter('read')).toBe(true);
    });

    it('should have edit formatter registered', () => {
      expect(defaultRegistry.hasFormatter('edit')).toBe(true);
      expect(defaultRegistry.hasFormatter('multiedit')).toBe(true);
    });

    it('should have grep formatter registered', () => {
      expect(defaultRegistry.hasFormatter('grep')).toBe(true);
    });

    it('should have write formatter registered', () => {
      expect(defaultRegistry.hasFormatter('write')).toBe(true);
    });

    it('should have patch formatter registered', () => {
      expect(defaultRegistry.hasFormatter('patch')).toBe(true);
    });

    it('should have find/glob/ls formatters registered', () => {
      expect(defaultRegistry.hasFormatter('find')).toBe(true);
      expect(defaultRegistry.hasFormatter('glob')).toBe(true);
      expect(defaultRegistry.hasFormatter('ls')).toBe(true);
    });

    it('should have web formatters registered', () => {
      expect(defaultRegistry.hasFormatter('webfetch')).toBe(true);
      expect(defaultRegistry.hasFormatter('websearch')).toBe(true);
    });

    it('should have todo formatter registered', () => {
      expect(defaultRegistry.hasFormatter('todoread')).toBe(true);
      expect(defaultRegistry.hasFormatter('todowrite')).toBe(true);
    });

    it('should have task formatter registered', () => {
      expect(defaultRegistry.hasFormatter('task')).toBe(true);
    });

    it('should have process formatter registered', () => {
      expect(defaultRegistry.hasFormatter('process')).toBe(true);
    });

    it('should format bash tool args', () => {
      const result = defaultRegistry.formatArgs('bash', {
        command: 'ls -la /tmp',
        timeout: 5000,
      });

      expect(result).toHaveProperty('summary');
      expect(result).toHaveProperty('details');
      expect(result.summary).toContain('ls');
    });

    it('should format read tool args', () => {
      const result = defaultRegistry.formatArgs('read', {
        file_path: '/path/to/file.txt',
        offset: 0,
        limit: 100,
      });

      expect(result).toHaveProperty('summary');
      expect(result.summary).toContain('file.txt');
    });

    it('should format edit tool args', () => {
      const result = defaultRegistry.formatArgs('edit', {
        file_path: '/path/to/file.txt',
        old_string: 'old',
        new_string: 'new',
      });

      expect(result).toHaveProperty('summary');
    });

    it('should format grep tool args', () => {
      const result = defaultRegistry.formatArgs('grep', {
        pattern: 'TODO',
        path: '/src',
      });

      expect(result).toHaveProperty('summary');
      expect(result.summary).toContain('TODO');
    });

    it('should format tool results correctly', () => {
      const bashResult = defaultRegistry.formatResult(
        'bash',
        'total 16\ndrwxr-xr-x  4 user staff 128 Jan  1 12:00 .'
      );
      expect(bashResult.summary).toBeDefined();
      expect(bashResult.details.length).toBeGreaterThan(0);

      const readResult = defaultRegistry.formatResult('read', 'file contents here', {
        file_path: '/test.txt',
      });
      expect(readResult.summary).toBeDefined();
    });

    it('should return all expected tools from getRegisteredTools', () => {
      const tools = defaultRegistry.getRegisteredTools();

      const expectedTools = [
        'bash',
        'exec',
        'read',
        'edit',
        'multiedit',
        'grep',
        'write',
        'patch',
        'find',
        'glob',
        'ls',
        'webfetch',
        'websearch',
        'todoread',
        'todowrite',
        'task',
        'process',
      ];

      for (const tool of expectedTools) {
        expect(tools).toContain(tool);
      }
    });
  });

  describe('edge cases', () => {
    it('should handle formatter with empty tools array', () => {
      const formatter = createMockFormatter([]);
      registry.register(formatter);

      expect(registry.getRegisteredTools()).toEqual([]);
    });

    it('should handle circular references in args', () => {
      const obj: Record<string, unknown> = { a: 1 };
      obj.self = obj;

      const result = registry.formatArgs('unknown', obj);

      expect(result.summary).toContain('[Circular]');
    });

    it('should handle special values in args', () => {
      const result = registry.formatArgs('unknown', {
        bigint: BigInt(123),
        func: () => {},
        symbol: Symbol('test'),
      });

      expect(result.summary).toBeDefined();
      expect(typeof result.summary).toBe('string');
    });

    it('should handle deeply nested objects', () => {
      const deep = { l1: { l2: { l3: { l4: { l5: 'deep' } } } } };
      const result = registry.formatArgs('unknown', deep);

      expect(result.summary).toContain('l1');
    });

    it('should handle very long single values', () => {
      const result = registry.formatArgs('unknown', {
        content: 'x'.repeat(10000),
      });

      // Should be truncated
      expect(result.summary.length).toBeLessThan(10000);
      expect(result.details[0].length).toBeLessThan(10000);
    });

    it('should handle empty string result', () => {
      const result = registry.formatResult('unknown', '');

      // extractText returns '' for empty string, which is falsy,
      // so it falls back to JSON formatting
      expect(result.summary).toBe('""');
    });

    it('should handle whitespace-only result', () => {
      const result = registry.formatResult('unknown', '   \n\t  ');

      expect(result.summary).toBeDefined();
    });

    it('should handle array results', () => {
      const result = registry.formatResult('unknown', [1, 2, 3]);

      expect(result.summary).toContain('1');
    });

    it('should handle object with output field', () => {
      const result = registry.formatResult('unknown', { output: 'command output' });

      expect(result.summary).toContain('command output');
    });

    it('should handle object with message field', () => {
      const result = registry.formatResult('unknown', { message: 'status message' });

      expect(result.summary).toContain('status message');
    });

    it('should handle content blocks with images', () => {
      const result = registry.formatResult('unknown', [
        { type: 'text', text: 'Some text' },
        { type: 'image', data: 'base64...' },
        { type: 'image', data: 'base64...' },
      ]);

      expect(result.summary).toContain('Some text');
      expect(result.details.join(' ')).toContain('2 images');
    });
  });
});
