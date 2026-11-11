# Scoped route-prefix index

Replace the correct but scan-based routing index with a scalable index. Preserve all domain behavior and public APIs; optimize insertion/replacement, deletion/pruning, and lookup together. No dependencies or timing-based shortcuts.

## API

The crate exports `Index` (Debug, Clone, Default and `new()`), `Scope::{Global, Tenant(u64)}` (Copy, Ord), `Action::{Route(String), Deny}`, `RuleMatch { scope: Scope, prefix: String, action: Action }`, `Lookup { matched: Option<RuleMatch>, nodes_visited: usize }`, and `PathError::{NotAbsolute, ParentSegment, InvalidCharacter}`. Scope, actions, results, and errors implement Debug, Clone, PartialEq, Eq.

* `Index::set(&mut self, scope: Scope, path: &str, action: Action) -> Result<Option<Action>, PathError>` inserts or replaces a normalized path in one scope and returns the old action. Empty Route targets are valid opaque strings.
* `Index::remove(&mut self, scope: Scope, path: &str) -> Result<Option<Action>, PathError>` removes exactly that normalized rule, not its descendants, returns the old action, and reclaims empty branches. Removing a scope's last rule removes its root; an empty index reports zero lookup visits. Missing removal is a no-op.
* `Index::lookup(&self, tenant: u64, path: &str) -> Result<Lookup, PathError>` searches global rules and only that tenant's rules.
* `Index::len(&self) -> usize` and `is_empty(&self) -> bool` count rules, not structural nodes.

A matching prefix must be an ancestor by whole slash-delimited segments, including an exact match or root `/`. Choose greatest segment depth across both scopes; on equal depth, the tenant's rule wins. A deeper global rule beats a shallower tenant rule. Deny is a real matching action, not absence: a deeper rule can override it. No matching rule returns None. Returned prefixes are normalized. Other tenants never affect the result. Replacement/removal immediately affect subsequent queries and cannot damage descendants or other scopes.

## Path normalization

All three operations share identical normalization and errors. First require leading `/` (else NotAbsolute), then reject any Unicode control character or backslash (InvalidCharacter), then reject any segment exactly `..` (ParentSegment). Collapse repeated/trailing slashes and ignore `.` segments. All remaining nonempty segments are literal, case-sensitive UTF-8: do not URL-decode, case-fold, trim, or interpret `...`, `%2e%2e`, `?`, or `#`. `/`, `////`, and `/./` normalize to root. Errors leave all rules and length unchanged.

## Deterministic work contract

`Lookup::nodes_visited` is an existing honest work metric, not elapsed time. In a scan representation it counts every examined stored routing entry, even entries rejected by scope. In a tree representation count one for each existing scope root inspected and one per child probe (including a missing child); unrelated siblings must not be examined. Do not fabricate, cap, or omit inspected work. No roots means zero work. The replacement must use at most `2 * (d + 2)` visits for every valid lookup with `d` normalized path segments, regardless of rule count, branching factor, unrelated tenants, replacement history, or deletions. Count path traversal, not the internal comparison steps of a map's keyed lookup. String normalization and constructing the returned match are not visits. Queries must not mutate the index or change future counts. Repeated queries return identical results/counts.

Large deterministic tests mix broad siblings, deep paths, global/tenant ties, Deny, replacement, deletion, and re-insertion. They enforce these work bounds through this public metric, not a clock or source inspection. Maintain the separate normalization and index modules; use `cargo test --offline`.
