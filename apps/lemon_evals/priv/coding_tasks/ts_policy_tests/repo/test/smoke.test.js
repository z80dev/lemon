import test from "node:test";
import assert from "node:assert/strict";
import { canAccess } from "../src/policy.js";
test("same-organization viewer can read a team document", () => {
  assert.equal(canAccess({ id: "reader", orgId: "acme", role: "viewer" }, { id: "doc", orgId: "acme", ownerId: "writer", visibility: "team" }, "read"), true);
});
