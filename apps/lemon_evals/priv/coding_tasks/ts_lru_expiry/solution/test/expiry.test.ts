import test from 'node:test';
import assert from 'node:assert/strict';
import { ExpiringCache } from '../src/cache.ts';
test('expiration frees capacity before a live victim is selected', () => {
  let time=0; const c=new ExpiringCache<number>(2,()=>time);
  c.set('long',1,100); c.set('short',2,1); time=1; c.set('new',3,10);
  assert.equal(c.get('long'),1); assert.equal(c.size,2);
});
test('has sees undefined without refreshing LRU', () => {
  const c=new ExpiringCache<number|undefined>(2,()=>0);
  c.set('old',undefined,10);c.set('new',1,10);assert.equal(c.has('old'),true);
  c.set('latest',2,10);assert.equal(c.has('old'),false);
});
