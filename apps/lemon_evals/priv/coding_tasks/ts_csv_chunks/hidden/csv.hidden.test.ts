import test from 'node:test';
import assert from 'node:assert/strict';
import { CsvParser, CsvTable, CsvError, CsvSchemaError } from '../src/index.ts';

function parse(chunks: string[], delimiter = ','): string[][] {
  const parser = new CsvParser({ delimiter });
  return [...chunks.flatMap(chunk => parser.write(chunk)), ...parser.finish()];
}

function capture(fn: () => unknown): unknown {
  try { fn(); } catch (error) { return error; }
  assert.fail('Expected an error');
}

test('every two-chunk boundary and one-code-unit chunks preserve quoted records', () => {
  const text = 'name,note\r\nAda,"one\r\ntwo, and ""quotes"""\r\nBob,\rLast,end';
  const expected = [['name', 'note'], ['Ada', 'one\r\ntwo, and "quotes"'], ['Bob', ''], ['Last', 'end']];
  for (let index = 0; index <= text.length; index++) assert.deepEqual(parse([text.slice(0, index), '', text.slice(index)]), expected, 'split ' + index);
  assert.deepEqual(parse(text.split('')), expected);
});

test('empty records, trailing separators, quotes and trailing fields', () => {
  const cases: [string, string[][]][] = [
    ['', []], ['\n', [['']]], ['\r\n', [['']]], ['\r\n\n', [[''], ['']]],
    [',', [['', '']]], ['a,', [['a', '']]], ['a,\n', [['a', '']]],
    ['""', [['']]], ['""""', [['"']]], ['a\r', [['a']]], ['a\r\nb', [['a'], ['b']]],
    [' a , b ', [[' a ', ' b ']]], ['a\\b,c', [['a\\b', 'c']]],
    ['\uFEFFa,b', [['\uFEFFa', 'b']]], ['😀,é', [['😀', 'é']]],
  ];
  for (const [text, expected] of cases) assert.deepEqual(parse(text.split('')), expected, JSON.stringify(text));
  assert.deepEqual(parse(['"a|b"|', '"c""d"\r', '\n'], '|'), [['a|b', 'c"d']]);
});

test('CR is emitted immediately; only its directly following LF is swallowed', () => {
  const parser = new CsvParser();
  assert.deepEqual(parser.write('x\r'), [['x']]);
  assert.deepEqual(parser.write(''), []);
  assert.deepEqual(parser.write('\ny\r'), [['y']]);
  assert.deepEqual(parser.write('z\n'), [['z']]);
  assert.deepEqual(parser.finish(), []);
});

test('delimiter validation and literal alternate delimiters', () => {
  for (const delimiter of ['', 'ab', '"', '\r', '\n', '😀']) {
    assert.throws(() => new CsvParser({ delimiter }), { name: 'RangeError', message: 'delimiter must be one character other than quote or newline' });
    assert.throws(() => new CsvTable({ delimiter }), RangeError);
  }
  assert.deepEqual(parse(['a.b."c.d"'], '.'), [['a', 'b', 'c.d']]);
  assert.deepEqual(parse(['a\tb'], '\t'), [['a', 'b']]);
});

test('syntax error offsets do not depend on chunk boundaries and errors poison parser', () => {
  const cases: [string, string, number][] = [
    ['ab"c', 'UNEXPECTED_QUOTE', 2], ['"a"x', 'AFTER_QUOTE', 3],
    ['"a" ', 'AFTER_QUOTE', 3], ['a\nq"', 'UNEXPECTED_QUOTE', 3],
    ['😀"', 'UNEXPECTED_QUOTE', 2], ['"a', 'UNTERMINATED_QUOTE', 2],
    ['"a""', 'UNTERMINATED_QUOTE', 4],
  ];
  for (const [text, code, offset] of cases) {
    for (let split = 0; split <= text.length; split++) {
      const parser = new CsvParser();
      const error = capture(() => { parser.write(text.slice(0, split)); parser.write(text.slice(split)); parser.finish(); });
      assert.ok(error instanceof CsvError);
      assert.equal(error.name, 'CsvError'); assert.equal(error.code, code); assert.equal(error.offset, offset);
      assert.equal(error.message, code + ' at offset ' + offset);
      assert.equal(capture(() => parser.write('recovery')), error);
      assert.equal(capture(() => parser.finish()), error);
    }
  }
});

test('successful finalization is idempotent and rejects even empty writes', () => {
  const parser = new CsvParser();
  assert.deepEqual(parser.write('x,'), []);
  assert.deepEqual(parser.finish(), [['x', '']]);
  assert.deepEqual(parser.finish(), []);
  for (const chunk of ['', 'x']) {
    const error = capture(() => parser.write(chunk));
    assert.ok(error instanceof CsvError); assert.equal(error.code, 'CLOSED'); assert.equal(error.offset, 2);
  }
  assert.deepEqual(parser.finish(), []);
});

test('table handles multiline headers, literal special keys and all boundaries', () => {
  const text = '__proto__,constructor,"line\nkey"\r\nvalue,ctor,"multi\nline"\r\nx,y,z';
  const expected = [Object.fromEntries([['__proto__', 'value'], ['constructor', 'ctor'], ['line\nkey', 'multi\nline']]), Object.fromEntries([['__proto__', 'x'], ['constructor', 'y'], ['line\nkey', 'z']])];
  for (let split = 0; split <= text.length; split++) {
    const table = new CsvTable();
    const result = [...table.write(text.slice(0, split)), ...table.write(text.slice(split)), ...table.finish()];
    assert.deepEqual(result, expected);
    assert.equal(Object.getPrototypeOf(result[0]), Object.prototype);
    assert.equal(Object.hasOwn(result[0], '__proto__'), true);
    assert.deepEqual(table.finish(), []);
  }
});

test('schema errors are logical-record based, precise and sticky', () => {
  const cases: [string, string, number][] = [
    ['a,\n', 'EMPTY_HEADER', 1], ['x,x\n', 'DUPLICATE_HEADER', 1],
    ['x,x,\n', 'DUPLICATE_HEADER', 1], [',x,x\n', 'EMPTY_HEADER', 1],
    ['a,b\n1\n', 'ROW_WIDTH', 2], ['a\n1,2', 'ROW_WIDTH', 2],
    ['"a\nb",c\n1,2\n3', 'ROW_WIDTH', 3],
  ];
  for (const [text, code, record] of cases) {
    const table = new CsvTable();
    const error = capture(() => { for (const character of text) table.write(character); table.finish(); });
    assert.ok(error instanceof CsvSchemaError);
    assert.equal(error.name, 'CsvSchemaError'); assert.equal(error.code, code); assert.equal(error.record, record);
    assert.equal(error.message, code + ' at record ' + record);
    assert.equal(capture(() => table.finish()), error);
    assert.equal(capture(() => table.write('')), error);
  }
});

test('empty and header-only tables, case-sensitive headers, and parser failures', () => {
  const empty = new CsvTable(); assert.deepEqual(empty.finish(), []);
  const headers = new CsvTable(); assert.deepEqual(headers.write('a,b'), []); assert.deepEqual(headers.finish(), []);
  const table = new CsvTable();
  assert.deepEqual(table.write('A,a\n1,2\n'), [{ A: '1', a: '2' }]);
  const error = capture(() => table.write('"bad"x'));
  assert.ok(error instanceof CsvError); assert.equal(error.code, 'AFTER_QUOTE');
  assert.equal(capture(() => table.finish()), error);
  const closed = new CsvTable(); closed.finish();
  const lifecycle = capture(() => closed.write(''));
  assert.ok(lifecycle instanceof CsvError); assert.equal(lifecycle.code, 'CLOSED');
  assert.equal(capture(() => closed.finish()), lifecycle);
});
