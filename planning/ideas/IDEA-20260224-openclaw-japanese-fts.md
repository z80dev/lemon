---
id: IDEA-20260224-openclaw-japanese-fts
title: Japanese query expansion support for full-text search
source: openclaw
source_commit: 21cbf5950
discovered: 2026-02-24
status: proposed
---

# Description

OpenClaw added Japanese query expansion support for their memory full-text search (FTS) feature. This improves search quality for Japanese language queries by expanding them with relevant variations.

Key features:
- Japanese query expansion for FTS
- Test coverage for Japanese query patterns
- Improves memory search quality for Japanese users

# Lemon Status

- Current state: Lemon has basic Japanese character handling in mentions
- Gap: No Japanese-specific query expansion for memory/FTS
- Location: No dedicated FTS query expansion found

# Investigation Notes

- Complexity estimate: S
- Value estimate: M
- Open questions:
  - Does Lemon have a memory search feature that uses FTS?
  - What search infrastructure does Lemon use?
  - Is there existing query expansion infrastructure?

# Recommendation

**investigating** - Need to understand Lemon's current search infrastructure before determining if this is applicable.

# References

- OpenClaw PR: #23156
- Commit: 21cbf59509fd1e50eafa65f35d17c6a331ab30fe
