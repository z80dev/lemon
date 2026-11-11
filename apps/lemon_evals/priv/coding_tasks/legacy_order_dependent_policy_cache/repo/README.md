# Policy checks that fail depending on test order
Run `python repro.py --seed 0` and compare other seeds or individual
test_policy.PolicyTests methods. Tests must remain enabled and their
assertions must not be weakened. Fix production code, not the runner.
Add regression tests for the actual causes.

Engine(config) snapshots a mapping of policy names to {allow: [roles],
deny: [roles]}; later caller mutation must not change that engine.
Engine.allows(policy, role, extra_roles=()) returns a bool. An unknown
policy denies everything. Extra roles grant access ONLY on that call,
and explicit deny always wins, including over extra_roles.
Policies with the same name in different engines must remain isolated.
Compilation may be cached, but its identity must include all semantic
policy inputs, and evaluation must never mutate compiled state. Do not
disable caching or clear global caches between calls/tests to hide leaks.
compile_policy(name, spec) remains public and must return the identical
cached object for semantically equivalent inputs (role ordering and
duplicate roles are irrelevant). No dependencies are needed.
