import test from 'node:test';
import assert from 'node:assert/strict';
import { mergeConfig, DELETE } from '../src/merge.ts';
import { resolveServiceConfig } from '../src/service.ts';
import type { ConfigPatch } from '../src/value.ts';

function freeze<T>(value: T): T {
  if (value && typeof value === 'object') { Object.values(value).forEach(freeze); Object.freeze(value); }
  return value;
}

test('recursive replacement, deletion, and left-to-right recreation', () => {
  assert.deepEqual(mergeConfig({ a: { x: 1, y: 2 }, b: [1], c: null },
    { a: { x: DELETE, z: 3 }, b: { inner: true }, c: { n: null }, absent: DELETE },
    { a: DELETE, c: {} }, { a: { fresh: 4 } }),
    { a: { fresh: 4 }, b: { inner: true }, c: { n: null } });
});

test('empty objects replace every non-object and preserve object contents', () => {
  assert.deepEqual(mergeConfig({ a: 1, b: null, c: [1], d: { keep: 2 } }, { a: {}, b: {}, c: {}, d: {}, e: {} }), { a: {}, b: {}, c: {}, d: { keep: 2 }, e: {} });
});

test('arrays replace deeply and primitives are not treated as absence', () => {
  const patch = { a: [{ value: [false, null, 0, ''] }], b: 0, c: false, d: '', e: null, marker: 'DELETE' };
  // This test asserts the concrete shape of this merge below.
  const result = mergeConfig({ a: [1, 2], b: 9, c: true, d: 'old', e: {} }, patch) as typeof patch;
  assert.deepEqual(result, patch);
  result.a[0].value.push(3);
  assert.deepEqual(patch.a, [{ value: [false, null, 0, ''] }]);
});

test('frozen inputs survive and every unchanged branch is cloned', () => {
  const base = freeze({ a: { deep: [1, { n: 2 }] }, b: null });
  const patch = freeze({ new: { array: [{ z: 9 }] }, a: { ignored: undefined } });
  // The merge preserves base.a and adds patch.new under the declared contract.
  const result = mergeConfig(base, patch) as typeof base & { new: typeof patch.new };
  assert.deepEqual(result, { a: { deep: [1, { n: 2 }] }, b: null, new: { array: [{ z: 9 }] } });
  assert.notEqual(result.a.deep[1], base.a.deep[1]);
  assert.notEqual(result.new.array[0], patch.new.array[0]);
});

test('later input mutations cannot affect result', () => {
  const base = { nest: { a: 1 } };
  const patch = { list: [{ n: 2 }] };
  const result = mergeConfig(base, patch);
  base.nest.a = 8; patch.list[0].n = 7;
  assert.deepEqual(result, { nest: { a: 1 }, list: [{ n: 2 }] });
});

test('literal dangerous keys and enumerable ownership', () => {
  const base = JSON.parse('{"__proto__":{"safe":1},"constructor":{"x":2},"toString":3}');
  const patch: ConfigPatch = JSON.parse('{"__proto__":{"next":4},"constructor":{"x":null}}');
  Object.defineProperty(patch, 'hidden', { value: 'ignore', enumerable: false });
  const result = mergeConfig(base, patch);
  assert.deepEqual(result, JSON.parse('{"__proto__":{"safe":1,"next":4},"constructor":{"x":null},"toString":3}'));
  assert.equal(Object.getPrototypeOf(result), Object.prototype);
  assert.equal(Object.hasOwn(result, '__proto__'), true);
  assert.deepEqual(mergeConfig(result, { ['__proto__']: DELETE }), { constructor: { x: null }, toString: 3 });
});

test('undefined is ignored including nested and absent keys', () => {
  assert.deepEqual(mergeConfig({ x: null, a: { b: 1 } }, { x: undefined, a: { b: undefined, c: undefined }, absent: undefined }), { x: null, a: { b: 1 } });
});

test('service integration preserves source and checks environment ownership', () => {
  const source = freeze({ defaults: { auth: { token: 'secret', retries: 2 } }, environments: { prod: { auth: { retries: 4 } } } });
  assert.deepEqual(resolveServiceConfig(source, 'prod', { auth: { token: DELETE } }), { auth: { retries: 4 } });
  for (const name of ['missing', 'toString', '__proto__']) {
    assert.throws(() => resolveServiceConfig(source, name), { name: 'RangeError', message: 'Unknown environment: ' + name });
  }
});
