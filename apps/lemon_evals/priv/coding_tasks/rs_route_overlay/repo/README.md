# Layered deployment router

Public API (re-exported at crate root):
- `Change::Set { prefix: String, target: String }`, `Change::Remove { prefix: String }`.
- `RouteTable::new()`, `apply_layer(&mut self, changes: &[Change]) -> Result<(), RouteError>`,
  `resolve(&self, path: &str) -> Result<Option<Resolved>, RouteError>`,
  `depth(&self) -> usize`, `pop_layer(&mut self) -> bool`.
- `Resolved { prefix: String, target: String, remainder: String, layer: usize }`.
- `RouteError::InvalidPath(String)` holds the original input;
  `RouteError::EmptyTarget { index: usize }` holds the zero-based change index.

A path must start with `/`, contain no `?`, `#`, NUL, or `..` component.
Canonicalization removes empty and `.` components, including trailing slashes;
root is `/`. Other UTF-8 components, spaces and backslashes are literal and case-sensitive.
An empty Set target is invalid, but all other target strings are opaque. Validate changes
in input order, checking a change's path before its target. On any error the table is unchanged.
Every successful apply appends one layer, even an empty batch. Repeated canonical prefix keys
in a batch use its last change. Layers have zero-based indices; pop removes only the newest
layer and returns false only if none exists (subsequent appends reuse that index).

For resolution, each exact key uses its newest layer's Set or Remove. A Remove hides only
that exact key, not descendants or ancestors. From the surviving Sets choose the longest
component-prefix of the canonical request path: `/a` matches `/a/b`, not `/ab`.
Return canonical prefix, opaque target, layer index, and the canonical unmatched suffix
without a leading slash. Exact matches have empty remainder; root matched against `/a/b`
has `a/b`. Return None when nothing survives. Invalid request paths error even on an empty table.

Run `cargo test --offline`.
