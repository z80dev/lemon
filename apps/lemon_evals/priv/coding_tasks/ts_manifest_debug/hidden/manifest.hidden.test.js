import test from "node:test";
import assert from "node:assert/strict";
import { compileManifest } from "../src/index.js";
test("diamond traversal replays shared overrides without moving first slots", () => {
  const docs = {
    common: { artifacts: [{ id: "a", path: "common" }, { id: "b", path: "b" }] },
    left: { includes: ["common"], artifacts: [{ id: "a", path: "left" }, { id: "c", path: "c" }] },
    right: { includes: ["common"], artifacts: [{ id: "d", path: "d" }] },
    root: { includes: ["left", "right"], artifacts: [{ id: "b", path: "final" }] }
  };
  const before = structuredClone(docs);
  assert.deepEqual(compileManifest(docs, "root"), [
    { id: "a", path: "common" },
    { id: "b", path: "final" },
    { id: "c", path: "c" },
    { id: "d", path: "d" }
  ]);
  assert.deepEqual(docs, before);
  assert.deepEqual(compileManifest({ x: { includes: ["y", "y"] }, y: { artifacts: [{ id: "q", path: "q" }] } }, "x"), [{ id: "q", path: "q" }]);
});
test("tombstones and shadowed paths never resolve, restoration keeps original slot", () => {
  assert.deepEqual(compileManifest({ r: { artifacts: [
    { id: "a", path: "${MISSING}" },
    { id: "b", path: "b" },
    { id: "a", disabled: true },
    { id: "c", disabled: true },
    { id: "a", path: "a" },
    { id: "z", path: "/bad" },
    { id: "z", disabled: true },
    { id: "c", path: "c" },
    { id: "gone", disabled: true }
  ] } }, "r"), [{ id: "a", path: "a" }, { id: "b", path: "b" }, { id: "c", path: "c" }]);
  assert.deepEqual(compileManifest({ r: { artifacts: [{ id: "a" }, { id: "a", path: "valid" }] } }, "r"), [{ id: "a", path: "valid" }]);
});
test("only recursion-stack repeats are cycles and document lookup is own-only", () => {
  assert.throws(() => compileManifest({ a: { includes: ["b"] }, b: { includes: ["c"] }, c: { includes: ["b"] } }, "a"), { message: "Manifest cycle: a -> b -> c -> b" });
  assert.throws(() => compileManifest({ a: { includes: ["a"] } }, "a"), { message: "Manifest cycle: a -> a" });
  assert.throws(() => compileManifest({}, "toString"), { message: "Unknown manifest: toString" });
  const inherited = Object.create({ base: {} });
  inherited.root = { includes: ["base"] };
  assert.throws(() => compileManifest(inherited, "root"), { message: "Unknown manifest: base" });
});
test("expansion is own-property, global, single-pass, and accepts empty values", () => {
  const env = Object.assign(Object.create({ HIDDEN: "secret" }), { A: "", B: "dir", C: "${B}" });
  const docs = { r: { artifacts: [{ id: "x", path: "${A}${B}/${B}/${C}" }] } };
  assert.deepEqual(compileManifest(docs, "r", env), [{ id: "x", path: "dir/dir/${B}" }]);
  assert.equal(env.C, "${B}");
  assert.throws(() => compileManifest({ r: { artifacts: [{ id: "x", path: "${HIDDEN}" }] } }, "r", env), { message: "Missing variable: HIDDEN" });
  assert.throws(() => compileManifest({ r: { artifacts: [{ id: "x", path: "${MISSING}" }] } }, "r"), { message: "Missing variable: MISSING" });
});
test("normalization and all specified final-path failures", () => {
  for (const path of ["", "/etc/config", "..", "../x", "a/../../x", "${ROOT}/x"]) {
    assert.throws(() => compileManifest({ r: { artifacts: [{ id: "x", path }] } }, "r", { ROOT: "/tmp" }), { message: "Unsafe path: x" });
  }
  assert.throws(() => compileManifest({ r: { artifacts: [{ id: "x" }] } }, "r"), { message: "Missing path: x" });
  assert.deepEqual(compileManifest({ r: { artifacts: [{ id: "x", path: "a/../b//c" }, { id: "dot", path: "a/.." }] } }, "r"), [{ id: "x", path: "b/c" }, { id: "dot", path: "." }]);
  assert.deepEqual(compileManifest({ empty: {} }, "empty"), []);
});
