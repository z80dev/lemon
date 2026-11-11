import test from 'node:test';
import assert from 'node:assert/strict';
import { CsvParser, CsvTable, CsvError } from '../src/index.ts';

test('records span transport chunks', () => {
  const parser = new CsvParser();
  assert.deepEqual(parser.write('name,city\r'), [['name', 'city']]);
  assert.deepEqual(parser.write('\n"Ada, A.","New'), []);
  assert.deepEqual(parser.write(' York"\n'), [['Ada, A.', 'New York']]);
  assert.deepEqual(parser.finish(), []);
});

test('table maps headers and custom delimiters', () => {
  const table = new CsvTable({ delimiter: ';' });
  assert.deepEqual(table.write('id;note\n1;"a;b"\n'), [{ id: '1', note: 'a;b' }]);
  assert.deepEqual(table.finish(), []);
});

test('unterminated quoted field is an EOF error', () => {
  const parser = new CsvParser();
  parser.write('"unfinished');
  assert.throws(() => parser.finish(), error => error instanceof CsvError && error.code === 'UNTERMINATED_QUOTE' && error.offset === 11);
});
