import test from 'node:test';
import assert from 'node:assert/strict';
import { mergeConfig, DELETE } from '../src/merge.ts';
import { resolveServiceConfig } from '../src/service.ts';

test('layers service connection settings without erasing sibling settings', () => {
  const source = { defaults: { database: { host: 'db', port: 5432 }, tags: ['base'] }, environments: { production: { database: { host: 'prod' }, tags: ['prod'] } } };
  assert.deepEqual(resolveServiceConfig(source, 'production', { database: { port: 6432 } }), { database: { host: 'prod', port: 6432 }, tags: ['prod'] });
});

test('deletes keys and ignores undefined', () => {
  assert.deepEqual(mergeConfig({ token: 'old', enabled: true }, { token: DELETE, enabled: undefined, missing: undefined }), { enabled: true });
});

test('returned branches are detached', () => {
  const base = { nested: { value: 1 }, list: [{ value: 2 }] };
  const result = mergeConfig(base);
  assert.deepEqual(result, base);
  assert.notEqual(result.nested, base.nested);
  assert.notEqual(result.list, base.list);
});
