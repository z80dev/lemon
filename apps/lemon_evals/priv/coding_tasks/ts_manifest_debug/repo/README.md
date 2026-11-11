# Release manifests

This library combines layered deployment manifests into an ordered artifact list.
`compileManifest(documents, entry, env)` consumes in-memory documents and returns
normalized relative artifact paths. Includes are applied before local overrides.
Artifact ids retain the position of their first appearance, including when disabled
and restored. Only final enabled artifact paths are expanded and validated.

Run `node --test test/*.test.js` with Node 22.
