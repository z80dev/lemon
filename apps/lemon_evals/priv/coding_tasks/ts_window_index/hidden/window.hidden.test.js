import test from "node:test";
import assert from "node:assert/strict";
import { WindowIndex } from "../src/index.js";
test("zero sums, repeated timestamps, detached records and key ordering", () => {
  const index = new WindowIndex(4);
  index.append(0, "z", 2);
  index.append(0, "z", -2);
  index.append(0, "A", 0);
  index.append(1, "__proto__", 5);
  const expected = [{ key: "A", count: 1, sum: 0 }, { key: "__proto__", count: 1, sum: 5 }, { key: "z", count: 2, sum: 0 }];
  assert.deepEqual(index.snapshot(), expected);
  const got = index.get("z");
  got.sum = 900;
  got.key = "changed";
  const snapshot = index.snapshot();
  snapshot[0].count = 100;
  snapshot.pop();
  assert.deepEqual(index.snapshot(), expected);
  index.advance(4);
  assert.equal(index.get("z"), undefined);
  assert.deepEqual(index.snapshot(), [{ key: "__proto__", count: 1, sum: 5 }]);
  index.append(4, "z", 9);
  index.advance(5);
  assert.deepEqual(index.snapshot(), [{ key: "z", count: 1, sum: 9 }]);
  assert.equal(index.now, 5);
});
test("validation is typed, ordered, and atomic", () => {
  for (const size of [0, -1, 1.5, NaN, 1 / 0, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => new WindowIndex(size), RangeError);
  }
  const index = new WindowIndex(10);
  index.append(5, "x", 2);
  for (const at of [-1, 4, 5.5, NaN, 1 / 0, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => index.advance(at), RangeError);
    assert.throws(() => index.append(at, "", NaN), RangeError);
  }
  for (const key of ["", null, 42]) {
    assert.throws(() => index.append(100, key, 1), TypeError);
    assert.throws(() => index.get(key), TypeError);
  }
  for (const value of [1.5, NaN, 1 / 0, Number.MAX_SAFE_INTEGER + 1, "3"]) {
    assert.throws(() => index.append(100, "x", value), TypeError);
  }
  assert.equal(index.now, 5);
  assert.deepEqual(index.snapshot(), [{ key: "x", count: 1, sum: 2 }]);
  index.advance(5);
  index.advance(15);
  assert.equal(index.get("x"), undefined);
});
test("incremental state agrees with an independent event model", () => {
  const index = new WindowIndex(17);
  let events = [];
  let now = 0;
  for (let i = 0;i < 600; i++) {
    now += i % 4;
    events = events.filter((event) => event.at > now - 17);
    if (i % 7 === 0)
      index.advance(now);
    else {
      const event = { at: now, key: ["b", "a", "中", "0", "__proto__"][i % 5], value: i % 19 - 9 };
      events.push(event);
      index.append(event.at, event.key, event.value);
    }
    const totals = new Map;
    for (const event of events) {
      const value = totals.get(event.key) ?? { key: event.key, count: 0, sum: 0 };
      value.count++;
      value.sum += event.value;
      totals.set(event.key, value);
    }
    const expected = [...totals.values()].sort((a, b) => a.key < b.key ? -1 : a.key > b.key ? 1 : 0);
    assert.deepEqual(index.snapshot(), expected);
    for (const value of expected)
      assert.deepEqual(index.get(value.key), value);
  }
});
test("long-lived windows do not rescan on append or query", () => {
  let visits = 0;
  const index = new WindowIndex(1e5, () => {
    visits++;
  });
  const E = 3500;
  for (let i = 0;i < E; i++) {
    index.append(i, `key-${i % 31}`, i % 7 - 3);
    index.get(`key-${i % 31}`);
    if (i % 70 === 0)
      index.snapshot();
  }
  assert.ok(visits > 0, "the visit observer must remain enabled");
  assert.ok(visits <= 2 * E, `append/query visit bound exceeded: ${visits}`);
  const before = visits;
  for (let i = 0;i < 100; i++) {
    index.get("key-1");
    index.snapshot();
  }
  assert.equal(visits, before, "queries must use aggregates");
  index.advance(103499);
  assert.deepEqual(index.snapshot(), []);
  assert.ok(visits <= 2 * E + 1, `expiry visit bound exceeded: ${visits}`);
});
test("many expirations and compactions preserve global visit budget", () => {
  let visits = 0, E = 0, A = 0;
  const index = new WindowIndex(13, () => {
    visits++;
  });
  for (let i = 0;i < 8000; i++) {
    index.append(i, `k${i % 8}`, i % 11 - 5);
    E++;
    if (i % 9 === 0) {
      index.advance(i);
      A++;
    }
    if (i % 41 === 0)
      index.snapshot();
  }
  index.advance(9000);
  A++;
  assert.deepEqual(index.snapshot(), []);
  index.append(9000, "new", 7);
  E++;
  assert.deepEqual(index.get("new"), { key: "new", count: 1, sum: 7 });
  assert.ok(visits <= 2 * E + A, `visit budget exceeded: ${visits} > ${2 * E + A}`);
});
