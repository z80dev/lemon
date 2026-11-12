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

## Cache isolation fix

The original cache used only policy names, so whichever engine compiled a
name first supplied every later engine's rules. Evaluation also updated the
cached allow set with temporary grants, leaking access into subsequent calls.
The cache key now includes the name and separate frozensets of allow and deny
roles. Cached mappings and role sets are immutable, and evaluation tests the
per-call grants without updating compiled state. Explicit denial is checked
before either source of permission. Engine configuration still uses a deep
snapshot of the caller's mapping.

`test_policy_regressions.py` adds semantic cache identity, all engine evaluation
orders, nonpersistent grants, deny precedence, immutable compilation, and
caller-mutation regressions without changing the original assertions or runner.
Use `python -m unittest discover -v` for discovery, and compare, for example,
`python repro.py --seed 0`, `python repro.py --seed 1`, and
`python repro.py --seed 7` for shuffled order coverage.
