import { describe, it, expect, vi, beforeEach } from 'vitest';
import { JsonLineDecoder, encodeJsonLine, type JsonLineParserOptions } from './codec';

describe('JsonLineDecoder', () => {
  describe('constructor and basic properties', () => {
    it('creates a decoder with required options', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });
      expect(decoder).toBeInstanceOf(JsonLineDecoder);
    });

    it('creates a decoder with optional onError handler', () => {
      const onMessage = vi.fn();
      const onError = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage, onError });
      expect(decoder).toBeInstanceOf(JsonLineDecoder);
    });
  });

  describe('write() with single complete line', () => {
    it('parses a simple JSON object line', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"type":"ping"}\n');

      expect(onMessage).toHaveBeenCalledTimes(1);
      expect(onMessage).toHaveBeenCalledWith({ type: 'ping' });
    });

    it('parses a JSON array line', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('[1,2,3]\n');

      expect(onMessage).toHaveBeenCalledTimes(1);
      expect(onMessage).toHaveBeenCalledWith([1, 2, 3]);
    });

    it('parses a JSON string line', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('"hello world"\n');

      expect(onMessage).toHaveBeenCalledTimes(1);
      expect(onMessage).toHaveBeenCalledWith('hello world');
    });

    it('parses a JSON number line', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('42\n');

      expect(onMessage).toHaveBeenCalledTimes(1);
      expect(onMessage).toHaveBeenCalledWith(42);
    });

    it('parses a JSON boolean line', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('true\n');

      expect(onMessage).toHaveBeenCalledTimes(1);
      expect(onMessage).toHaveBeenCalledWith(true);
    });

    it('parses a JSON null line', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('null\n');

      expect(onMessage).toHaveBeenCalledTimes(1);
      expect(onMessage).toHaveBeenCalledWith(null);
    });
  });

  describe('write() with partial lines (buffering)', () => {
    it('buffers partial JSON and parses on newline', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"type":');
      expect(onMessage).not.toHaveBeenCalled();

      decoder.write('"ping"}\n');
      expect(onMessage).toHaveBeenCalledTimes(1);
      expect(onMessage).toHaveBeenCalledWith({ type: 'ping' });
    });

    it('buffers across multiple write calls', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{');
      decoder.write('"a"');
      decoder.write(':');
      decoder.write('1');
      decoder.write('}');
      decoder.write('\n');

      expect(onMessage).toHaveBeenCalledTimes(1);
      expect(onMessage).toHaveBeenCalledWith({ a: 1 });
    });

    it('handles split in the middle of a key', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"user');
      decoder.write('name":"test"}\n');

      expect(onMessage).toHaveBeenCalledWith({ username: 'test' });
    });

    it('handles split in the middle of a value', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"name":"John');
      decoder.write(' Doe"}\n');

      expect(onMessage).toHaveBeenCalledWith({ name: 'John Doe' });
    });
  });

  describe('write() with multiple lines in one chunk', () => {
    it('parses multiple JSON objects in one chunk', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"a":1}\n{"b":2}\n{"c":3}\n');

      expect(onMessage).toHaveBeenCalledTimes(3);
      expect(onMessage).toHaveBeenNthCalledWith(1, { a: 1 });
      expect(onMessage).toHaveBeenNthCalledWith(2, { b: 2 });
      expect(onMessage).toHaveBeenNthCalledWith(3, { c: 3 });
    });

    it('parses multiple lines with trailing partial', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"a":1}\n{"b":2}\n{"c":');

      expect(onMessage).toHaveBeenCalledTimes(2);
      expect(onMessage).toHaveBeenNthCalledWith(1, { a: 1 });
      expect(onMessage).toHaveBeenNthCalledWith(2, { b: 2 });
    });

    it('parses multiple lines with leading partial from previous write', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"x":');
      decoder.write('100}\n{"y":200}\n');

      expect(onMessage).toHaveBeenCalledTimes(2);
      expect(onMessage).toHaveBeenNthCalledWith(1, { x: 100 });
      expect(onMessage).toHaveBeenNthCalledWith(2, { y: 200 });
    });
  });

  describe('flush()', () => {
    it('processes remaining buffer content', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"final":true}');
      expect(onMessage).not.toHaveBeenCalled();

      decoder.flush();
      expect(onMessage).toHaveBeenCalledWith({ final: true });
    });

    it('does nothing when buffer is empty', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.flush();
      expect(onMessage).not.toHaveBeenCalled();
    });

    it('does nothing when buffer only contains whitespace', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('   \t  ');
      decoder.flush();
      expect(onMessage).not.toHaveBeenCalled();
    });

    it('clears the buffer after flush', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"a":1}');
      decoder.flush();
      decoder.flush(); // Second flush should not call onMessage again

      expect(onMessage).toHaveBeenCalledTimes(1);
    });

    it('handles flush after complete line (buffer should be empty)', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"complete":true}\n');
      expect(onMessage).toHaveBeenCalledTimes(1);

      decoder.flush();
      expect(onMessage).toHaveBeenCalledTimes(1); // No additional call
    });
  });

  describe('handleLine() callback invocation', () => {
    it('trims whitespace before parsing', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('  {"trimmed":true}  \n');
      expect(onMessage).toHaveBeenCalledWith({ trimmed: true });
    });

    it('invokes callbacks in order for sequential lines', () => {
      const calls: unknown[] = [];
      const onMessage = (value: unknown) => calls.push(value);
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('1\n2\n3\n');

      expect(calls).toEqual([1, 2, 3]);
    });
  });

  describe('empty line handling', () => {
    it('ignores empty lines', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('\n');
      expect(onMessage).not.toHaveBeenCalled();
    });

    it('ignores lines with only whitespace', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('   \n');
      expect(onMessage).not.toHaveBeenCalled();
    });

    it('ignores multiple empty lines', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('\n\n\n');
      expect(onMessage).not.toHaveBeenCalled();
    });

    it('ignores empty lines between valid JSON', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"a":1}\n\n{"b":2}\n\n\n{"c":3}\n');

      expect(onMessage).toHaveBeenCalledTimes(3);
      expect(onMessage).toHaveBeenNthCalledWith(1, { a: 1 });
      expect(onMessage).toHaveBeenNthCalledWith(2, { b: 2 });
      expect(onMessage).toHaveBeenNthCalledWith(3, { c: 3 });
    });

    it('ignores whitespace-only lines between valid JSON', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"a":1}\n   \n{"b":2}\n');

      expect(onMessage).toHaveBeenCalledTimes(2);
    });
  });

  describe('unicode handling', () => {
    it('parses unicode characters in strings', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"emoji":"Hello"}\n');
      expect(onMessage).toHaveBeenCalledWith({ emoji: 'Hello' });
    });

    it('parses unicode escape sequences', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"escaped":"\\u0048\\u0065\\u006c\\u006c\\u006f"}\n');
      expect(onMessage).toHaveBeenCalledWith({ escaped: 'Hello' });
    });

    it('parses Chinese characters', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"chinese":"\u4f60\u597d\u4e16\u754c"}\n');
      expect(onMessage).toHaveBeenCalledWith({ chinese: '\u4f60\u597d\u4e16\u754c' });
    });

    it('parses Japanese characters', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"japanese":"\u3053\u3093\u306b\u3061\u306f"}\n');
      expect(onMessage).toHaveBeenCalledWith({ japanese: '\u3053\u3093\u306b\u3061\u306f' });
    });

    it('parses mixed unicode content', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"mixed":"Hello \u4e16\u754c! \ud83c\udf0d"}\n');
      expect(onMessage).toHaveBeenCalledWith({ mixed: 'Hello \u4e16\u754c! \ud83c\udf0d' });
    });

    it('handles unicode split across chunks', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      // Note: This tests string splitting, not byte splitting
      // Real byte-level unicode splitting would require Buffer handling
      decoder.write('{"text":"Hello ');
      decoder.write('\u4e16\u754c"}\n');

      expect(onMessage).toHaveBeenCalledWith({ text: 'Hello \u4e16\u754c' });
    });
  });

  describe('large payload handling', () => {
    it('handles large JSON objects', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      const largeObject: Record<string, number> = {};
      for (let i = 0; i < 1000; i++) {
        largeObject[`key${i}`] = i;
      }

      decoder.write(JSON.stringify(largeObject) + '\n');

      expect(onMessage).toHaveBeenCalledTimes(1);
      expect(onMessage).toHaveBeenCalledWith(largeObject);
    });

    it('handles large arrays', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      const largeArray = Array.from({ length: 10000 }, (_, i) => i);
      decoder.write(JSON.stringify(largeArray) + '\n');

      expect(onMessage).toHaveBeenCalledWith(largeArray);
    });

    it('handles deeply nested objects', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      let nested: Record<string, unknown> = { value: 'deep' };
      for (let i = 0; i < 50; i++) {
        nested = { level: i, child: nested };
      }

      decoder.write(JSON.stringify(nested) + '\n');
      expect(onMessage).toHaveBeenCalledWith(nested);
    });

    it('handles long strings', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      const longString = 'x'.repeat(100000);
      decoder.write(JSON.stringify({ text: longString }) + '\n');

      expect(onMessage).toHaveBeenCalledWith({ text: longString });
    });

    it('handles large payload split across many chunks', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      const payload = JSON.stringify({ data: 'a'.repeat(10000) }) + '\n';
      const chunkSize = 100;

      for (let i = 0; i < payload.length; i += chunkSize) {
        decoder.write(payload.slice(i, i + chunkSize));
      }

      expect(onMessage).toHaveBeenCalledTimes(1);
    });
  });

  describe('invalid JSON handling', () => {
    it('calls onError for malformed JSON', () => {
      const onMessage = vi.fn();
      const onError = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage, onError });

      decoder.write('{invalid json}\n');

      expect(onMessage).not.toHaveBeenCalled();
      expect(onError).toHaveBeenCalledTimes(1);
      expect(onError).toHaveBeenCalledWith(expect.any(Error), '{invalid json}');
    });

    it('continues parsing after invalid JSON', () => {
      const onMessage = vi.fn();
      const onError = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage, onError });

      decoder.write('{invalid}\n{"valid":true}\n');

      expect(onError).toHaveBeenCalledTimes(1);
      expect(onMessage).toHaveBeenCalledTimes(1);
      expect(onMessage).toHaveBeenCalledWith({ valid: true });
    });

    it('handles missing onError gracefully', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      // Should not throw even without onError handler
      expect(() => decoder.write('{invalid}\n')).not.toThrow();
      expect(onMessage).not.toHaveBeenCalled();
    });

    it('handles truncated JSON', () => {
      const onMessage = vi.fn();
      const onError = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage, onError });

      decoder.write('{"key": "val\n');

      expect(onError).toHaveBeenCalledTimes(1);
    });

    it('handles undefined value (non-JSON)', () => {
      const onMessage = vi.fn();
      const onError = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage, onError });

      decoder.write('undefined\n');

      expect(onError).toHaveBeenCalledTimes(1);
    });

    it('handles trailing comma (invalid JSON)', () => {
      const onMessage = vi.fn();
      const onError = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage, onError });

      decoder.write('{"key": 1,}\n');

      expect(onError).toHaveBeenCalledTimes(1);
    });

    it('handles single quotes (invalid JSON)', () => {
      const onMessage = vi.fn();
      const onError = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage, onError });

      decoder.write("{'key': 'value'}\n");

      expect(onError).toHaveBeenCalledTimes(1);
    });

    it('provides proper error object', () => {
      const onMessage = vi.fn();
      const onError = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage, onError });

      decoder.write('not json\n');

      expect(onError.mock.calls[0][0]).toBeInstanceOf(Error);
      expect(onError.mock.calls[0][0].message).toContain('JSON');
    });

    it('provides raw line in onError', () => {
      const onMessage = vi.fn();
      const onError = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage, onError });

      decoder.write('  bad json content  \n');

      // Raw line should be trimmed
      expect(onError.mock.calls[0][1]).toBe('bad json content');
    });
  });

  describe('newline variations', () => {
    it('handles Unix newlines (\\n)', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"a":1}\n{"b":2}\n');

      expect(onMessage).toHaveBeenCalledTimes(2);
    });

    it('handles Windows newlines (\\r\\n)', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"a":1}\r\n{"b":2}\r\n');

      expect(onMessage).toHaveBeenCalledTimes(2);
      expect(onMessage).toHaveBeenNthCalledWith(1, { a: 1 });
      expect(onMessage).toHaveBeenNthCalledWith(2, { b: 2 });
    });

    it('handles mixed newline styles', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"a":1}\n{"b":2}\r\n{"c":3}\n');

      expect(onMessage).toHaveBeenCalledTimes(3);
    });

    it('handles carriage return at end of line (trimmed)', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      // \r at end should be trimmed
      decoder.write('{"trimmed":true}\r\n');

      expect(onMessage).toHaveBeenCalledWith({ trimmed: true });
    });
  });

  describe('Buffer input handling', () => {
    it('accepts Buffer input and converts to string', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      const buffer = Buffer.from('{"from":"buffer"}\n');
      decoder.write(buffer);

      expect(onMessage).toHaveBeenCalledWith({ from: 'buffer' });
    });

    it('handles Buffer with UTF-8 encoding', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      const buffer = Buffer.from('{"utf8":"\u4e2d\u6587"}\n', 'utf8');
      decoder.write(buffer);

      expect(onMessage).toHaveBeenCalledWith({ utf8: '\u4e2d\u6587' });
    });
  });

  describe('edge cases', () => {
    it('handles zero-length strings', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('');
      expect(onMessage).not.toHaveBeenCalled();
    });

    it('handles JSON with escaped newlines in strings', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"text":"line1\\nline2"}\n');

      expect(onMessage).toHaveBeenCalledWith({ text: 'line1\nline2' });
    });

    it('handles multiple decoders independently', () => {
      const onMessage1 = vi.fn();
      const onMessage2 = vi.fn();
      const decoder1 = new JsonLineDecoder({ onMessage: onMessage1 });
      const decoder2 = new JsonLineDecoder({ onMessage: onMessage2 });

      decoder1.write('{"d":1}');
      decoder2.write('{"d":2}\n');

      expect(onMessage1).not.toHaveBeenCalled();
      expect(onMessage2).toHaveBeenCalledWith({ d: 2 });

      decoder1.write('\n');
      expect(onMessage1).toHaveBeenCalledWith({ d: 1 });
    });

    it('handles special JSON values (Infinity-like strings)', () => {
      const onMessage = vi.fn();
      const onError = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage, onError });

      // Infinity is not valid JSON
      decoder.write('Infinity\n');
      expect(onError).toHaveBeenCalled();
    });

    it('handles floating point numbers', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"pi":3.14159265359}\n');
      expect(onMessage).toHaveBeenCalledWith({ pi: 3.14159265359 });
    });

    it('handles scientific notation', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"big":1.23e10}\n');
      expect(onMessage).toHaveBeenCalledWith({ big: 1.23e10 });
    });

    it('handles negative numbers', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      decoder.write('{"negative":-42}\n');
      expect(onMessage).toHaveBeenCalledWith({ negative: -42 });
    });
  });
});

describe('encodeJsonLine', () => {
  describe('object encoding', () => {
    it('encodes a simple object', () => {
      const result = encodeJsonLine({ type: 'ping' });
      expect(result).toBe('{"type":"ping"}\n');
    });

    it('encodes an object with multiple properties', () => {
      const result = encodeJsonLine({ a: 1, b: 2, c: 3 });
      expect(result).toBe('{"a":1,"b":2,"c":3}\n');
    });

    it('encodes an object with string values', () => {
      const result = encodeJsonLine({ name: 'John', city: 'NYC' });
      expect(result).toBe('{"name":"John","city":"NYC"}\n');
    });

    it('encodes an object with boolean values', () => {
      const result = encodeJsonLine({ active: true, deleted: false });
      expect(result).toBe('{"active":true,"deleted":false}\n');
    });

    it('encodes an object with null values', () => {
      const result = encodeJsonLine({ value: null });
      expect(result).toBe('{"value":null}\n');
    });

    it('encodes an empty object', () => {
      const result = encodeJsonLine({});
      expect(result).toBe('{}\n');
    });
  });

  describe('array encoding', () => {
    it('encodes a simple array', () => {
      const result = encodeJsonLine([1, 2, 3]);
      expect(result).toBe('[1,2,3]\n');
    });

    it('encodes an array of strings', () => {
      const result = encodeJsonLine(['a', 'b', 'c']);
      expect(result).toBe('["a","b","c"]\n');
    });

    it('encodes an array of objects', () => {
      const result = encodeJsonLine([{ id: 1 }, { id: 2 }]);
      expect(result).toBe('[{"id":1},{"id":2}]\n');
    });

    it('encodes an empty array', () => {
      const result = encodeJsonLine([]);
      expect(result).toBe('[]\n');
    });

    it('encodes a mixed array', () => {
      const result = encodeJsonLine([1, 'two', true, null]);
      expect(result).toBe('[1,"two",true,null]\n');
    });
  });

  describe('nested objects', () => {
    it('encodes nested objects', () => {
      const result = encodeJsonLine({ outer: { inner: { deep: 'value' } } });
      expect(result).toBe('{"outer":{"inner":{"deep":"value"}}}\n');
    });

    it('encodes objects with nested arrays', () => {
      const result = encodeJsonLine({ items: [1, 2, 3] });
      expect(result).toBe('{"items":[1,2,3]}\n');
    });

    it('encodes arrays with nested objects', () => {
      const result = encodeJsonLine([{ a: { b: 1 } }]);
      expect(result).toBe('[{"a":{"b":1}}]\n');
    });

    it('encodes complex nested structure', () => {
      const data = {
        user: {
          name: 'John',
          addresses: [
            { city: 'NYC', zip: '10001' },
            { city: 'LA', zip: '90001' },
          ],
        },
      };
      const result = encodeJsonLine(data);
      expect(JSON.parse(result.slice(0, -1))).toEqual(data);
      expect(result.endsWith('\n')).toBe(true);
    });
  });

  describe('special characters', () => {
    it('encodes strings with double quotes', () => {
      const result = encodeJsonLine({ text: 'He said "hello"' });
      expect(result).toBe('{"text":"He said \\"hello\\""}\n');
    });

    it('encodes strings with backslashes', () => {
      const result = encodeJsonLine({ path: 'C:\\Users\\name' });
      expect(result).toBe('{"path":"C:\\\\Users\\\\name"}\n');
    });

    it('encodes strings with newlines', () => {
      const result = encodeJsonLine({ text: 'line1\nline2' });
      expect(result).toBe('{"text":"line1\\nline2"}\n');
    });

    it('encodes strings with tabs', () => {
      const result = encodeJsonLine({ text: 'col1\tcol2' });
      expect(result).toBe('{"text":"col1\\tcol2"}\n');
    });

    it('encodes strings with carriage returns', () => {
      const result = encodeJsonLine({ text: 'line1\rline2' });
      expect(result).toBe('{"text":"line1\\rline2"}\n');
    });

    it('encodes strings with control characters', () => {
      const result = encodeJsonLine({ text: 'hello\u0000world' });
      expect(result).toContain('\\u0000');
    });
  });

  describe('unicode', () => {
    it('encodes unicode characters', () => {
      const result = encodeJsonLine({ emoji: '\ud83d\ude00' });
      expect(result).toBe('{"emoji":"\ud83d\ude00"}\n');
    });

    it('encodes Chinese characters', () => {
      const result = encodeJsonLine({ text: '\u4f60\u597d' });
      expect(result).toBe('{"text":"\u4f60\u597d"}\n');
    });

    it('encodes Arabic characters', () => {
      const result = encodeJsonLine({ text: '\u0645\u0631\u062d\u0628\u0627' });
      expect(result).toBe('{"text":"\u0645\u0631\u062d\u0628\u0627"}\n');
    });

    it('encodes mixed unicode content', () => {
      const data = { greeting: 'Hello \u4e16\u754c \ud83c\udf0d' };
      const result = encodeJsonLine(data);
      const decoded = JSON.parse(result.slice(0, -1));
      expect(decoded).toEqual(data);
    });
  });

  describe('large objects', () => {
    it('encodes large objects', () => {
      const largeObj: Record<string, number> = {};
      for (let i = 0; i < 1000; i++) {
        largeObj[`key${i}`] = i;
      }
      const result = encodeJsonLine(largeObj);
      expect(result.endsWith('\n')).toBe(true);
      expect(JSON.parse(result.slice(0, -1))).toEqual(largeObj);
    });

    it('encodes large arrays', () => {
      const largeArray = Array.from({ length: 10000 }, (_, i) => i);
      const result = encodeJsonLine(largeArray);
      expect(result.endsWith('\n')).toBe(true);
      expect(JSON.parse(result.slice(0, -1))).toEqual(largeArray);
    });

    it('encodes deeply nested structures', () => {
      let nested: Record<string, unknown> = { value: 'deep' };
      for (let i = 0; i < 50; i++) {
        nested = { level: i, child: nested };
      }
      const result = encodeJsonLine(nested);
      expect(result.endsWith('\n')).toBe(true);
      expect(JSON.parse(result.slice(0, -1))).toEqual(nested);
    });
  });

  describe('null/undefined handling', () => {
    it('encodes null as a value', () => {
      const result = encodeJsonLine(null);
      expect(result).toBe('null\n');
    });

    it('encodes undefined in object (omitted)', () => {
      const result = encodeJsonLine({ a: 1, b: undefined, c: 3 });
      expect(result).toBe('{"a":1,"c":3}\n');
    });

    it('encodes undefined in array (as null)', () => {
      const result = encodeJsonLine([1, undefined, 3]);
      expect(result).toBe('[1,null,3]\n');
    });

    it('handles undefined as top-level value', () => {
      const result = encodeJsonLine(undefined);
      expect(result).toBe('undefined\n'); // This is technically invalid JSON
    });
  });

  describe('primitive types', () => {
    it('encodes string', () => {
      const result = encodeJsonLine('hello');
      expect(result).toBe('"hello"\n');
    });

    it('encodes number (integer)', () => {
      const result = encodeJsonLine(42);
      expect(result).toBe('42\n');
    });

    it('encodes number (float)', () => {
      const result = encodeJsonLine(3.14);
      expect(result).toBe('3.14\n');
    });

    it('encodes number (negative)', () => {
      const result = encodeJsonLine(-100);
      expect(result).toBe('-100\n');
    });

    it('encodes number (zero)', () => {
      const result = encodeJsonLine(0);
      expect(result).toBe('0\n');
    });

    it('encodes boolean true', () => {
      const result = encodeJsonLine(true);
      expect(result).toBe('true\n');
    });

    it('encodes boolean false', () => {
      const result = encodeJsonLine(false);
      expect(result).toBe('false\n');
    });
  });

  describe('roundtrip compatibility', () => {
    it('encoded output can be decoded', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      const original = { type: 'event', data: [1, 2, 3] };
      const encoded = encodeJsonLine(original);
      decoder.write(encoded);

      expect(onMessage).toHaveBeenCalledWith(original);
    });

    it('multiple encoded lines can be decoded', () => {
      const messages: unknown[] = [];
      const decoder = new JsonLineDecoder({ onMessage: (v) => messages.push(v) });

      const items = [
        { id: 1, name: 'first' },
        { id: 2, name: 'second' },
        { id: 3, name: 'third' },
      ];

      const encoded = items.map(encodeJsonLine).join('');
      decoder.write(encoded);

      expect(messages).toEqual(items);
    });

    it('complex nested structure survives roundtrip', () => {
      const onMessage = vi.fn();
      const decoder = new JsonLineDecoder({ onMessage });

      const complex = {
        users: [
          { id: 1, tags: ['admin', 'user'], meta: { created: 123 } },
          { id: 2, tags: ['user'], meta: { created: 456 } },
        ],
        config: {
          nested: { deeply: { value: true } },
        },
      };

      decoder.write(encodeJsonLine(complex));
      expect(onMessage).toHaveBeenCalledWith(complex);
    });
  });
});
