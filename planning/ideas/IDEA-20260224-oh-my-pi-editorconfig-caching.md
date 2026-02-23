---
id: IDEA-20260224-oh-my-pi-editorconfig-caching
title: EditorConfig caching and configurable tab width
source: oh-my-pi
source_commit: 8d112ebb, c728b79b
discovered: 2026-02-24
status: proposed
---

# Description

Oh-My-Pi implemented performance improvements for editorconfig resolution and added configurable tab width support.

Key features:
- Caching for editorconfig file chains to avoid redundant file system traversal and parsing
- Caching for resolved indentation strings per file path
- `display.tabWidth` setting to control default tab rendering
- `.editorconfig` resolution for context-aware tab indentation
- Improved tab visualization in diffs and UI elements

# Lemon Status

- Current state: No editorconfig support found in Lemon
- Gap: No editorconfig parsing, no tab width configuration
- Location: Would need new module in coding_agent

# Investigation Notes

- Complexity estimate: M
- Value estimate: M
- Open questions:
  - Does Lemon handle indentation detection currently?
  - How are diffs formatted in Lemon?
  - Would this require a new Elixir library for editorconfig parsing?

# Recommendation

**defer** - Nice-to-have feature but not critical. Could improve UX for code formatting but requires new dependencies.

# References

- Oh-My-Pi commits: 8d112ebb70c12aa571665177ff7ca43a6679bedb, c728b79bf4f2e87cb5c38ab342c836c7fa0d38
