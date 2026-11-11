import test from "node:test";
import assert from "node:assert/strict";
import { compileManifest } from "../src/index.js";
test("includes precede local artifacts and paths are normalized", () => {
  const docs = {
    base: { artifacts: [{ id: "runtime", path: "lib/./runtime.js" }] },
    app: { includes: ["base"], artifacts: [{ id: "web", path: "${ROOT}/index.html" }] }
  };
  assert.deepEqual(compileManifest(docs, "app", { ROOT: "public" }), [
    { id: "runtime", path: "lib/runtime.js" },
    { id: "web", path: "public/index.html" }
  ]);
});
test("missing includes are explicit errors", () => {
  assert.throws(() => compileManifest({ app: { includes: ["absent"] } }, "app"), { message: "Unknown manifest: absent" });
});
