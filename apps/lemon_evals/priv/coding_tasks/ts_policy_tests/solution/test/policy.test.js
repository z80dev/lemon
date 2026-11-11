import test from "node:test";
import assert from "node:assert/strict";
import { canAccess } from "../src/policy.js";
function subject(changes = {}) {
  return { id: "reader", orgId: "acme", role: "viewer", ...changes };
}
function resource(changes = {}) {
  return { id: "doc", orgId: "acme", ownerId: "owner", visibility: "team", ...changes };
}
const actions = ["read", "write", "delete"];
test("anonymous access is denied for every visibility and action", () => {
  for (const visibility of ["private", "team", "public"]) {
    for (const action of actions)
      assert.equal(canAccess(null, resource({ visibility }), action), false);
  }
});
test("mandatory gates override administrators and ownership", () => {
  for (const role of ["admin", "editor", "viewer"]) {
    for (const action of actions) {
      const user = subject({ id: "owner", role });
      assert.equal(canAccess({ ...user, suspended: true }, resource(), action), false, `suspended ${role} ${action}`);
      assert.equal(canAccess({ ...user, orgId: "other" }, resource(), action), false, `cross-organization ${role} ${action}`);
      assert.equal(canAccess(user, resource({ deniedUserIds: ["someone", "owner"] }), action), false, `explicitly denied ${role} ${action}`);
    }
  }
});
test("unknown actions are denied even for privileged users", () => {
  for (const user of [subject({ role: "admin" }), subject({ id: "owner" }), subject({ role: "editor" })]) {
    for (const action of ["", "share", "READ", "constructor"])
      assert.equal(canAccess(user, resource(), action), false);
  }
});
test("administrators and owners may access every active visibility", () => {
  for (const visibility of ["private", "team", "public"]) {
    for (const user of [subject({ role: "admin" }), subject({ id: "owner" })]) {
      for (const action of actions)
        assert.equal(canAccess(user, resource({ visibility }), action), true, `${visibility} ${action}`);
    }
  }
});
test("nonowner role and visibility access matrix", () => {
  for (const role of ["editor", "viewer"]) {
    for (const visibility of ["private", "team", "public"]) {
      for (const action of actions) {
        const expected = visibility !== "private" && (action === "read" || action === "write" && role === "editor");
        assert.equal(canAccess(subject({ role }), resource({ visibility }), action), expected, `${role} ${visibility} ${action}`);
      }
    }
  }
});
test("archives preserve authorized reads and prohibit every write/delete", () => {
  for (const user of [subject({ role: "admin" }), subject({ id: "owner" }), subject({ role: "editor" }), subject()]) {
    for (const visibility of ["private", "team", "public"]) {
      const doc = resource({ visibility, archived: true });
      const canRead = user.role === "admin" || user.id === "owner" || visibility !== "private";
      assert.equal(canAccess(user, doc, "read"), canRead);
      assert.equal(canAccess(user, doc, "write"), false);
      assert.equal(canAccess(user, doc, "delete"), false);
    }
  }
  assert.equal(canAccess(subject({ suspended: true }), resource({ archived: true }), "read"), false);
  assert.equal(canAccess(subject(), resource({ archived: true, deniedUserIds: ["reader"] }), "read"), false);
});
test("optional flags default to false/empty and calls do not mutate input", () => {
  const user = subject({ role: "editor", suspended: false });
  const doc = resource({ archived: false, deniedUserIds: ["someone-else"] });
  const original = structuredClone({ user, doc });
  Object.freeze(user);
  Object.freeze(doc.deniedUserIds);
  Object.freeze(doc);
  assert.equal(canAccess(user, doc, "write"), true);
  assert.equal(canAccess(subject({ role: "editor" }), resource(), "write"), true);
  assert.deepEqual({ user, doc }, original);
});
