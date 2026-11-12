import test from "node:test";
import assert from "node:assert/strict";
import { WindowIndex } from "../src/index.js";
test("tracks key counts and expires the left boundary", () => {
  const index = new WindowIndex(10);
  index.append(0, "api", 3);
  index.append(5, "api", -1);
  index.append(5, "db", 8);
  assert.deepEqual(index.snapshot(), [{ key: "api", count: 2, sum: 2 }, { key: "db", count: 1, sum: 8 }]);
  index.advance(10);
  assert.deepEqual(index.get("api"), { key: "api", count: 1, sum: -1 });
  index.advance(15);
  assert.deepEqual(index.snapshot(), []);
});
