---
id: IDEA-20260224-ironclaw-skills-catalog
title: Skills catalog with ClawHub integration and search
source: ironclaw
source_commit: 4e2dd76
discovered: 2026-02-24
status: proposed
---

# Description
IronClaw significantly enhanced their skills system with a full catalog experience, ClawHub integration, and rich search capabilities. Skills are now enabled by default with proper registry connectivity.

Key features:
- Skills system enabled by default (no SKILLS_ENABLED required)
- ClawHub registry integration with Convex backend
- ZIP archive support for skill downloads (extracts SKILL.md from archive)
- Catalog search with error surfacing (yellow warning banner)
- Rich skill search results with metadata:
  - Stars, downloads, owner information
  - Relevance score
  - "Updated X ago" recency
  - Clickable skill names linking to clawhub.ai
- `/skills` command to list installed skills and search catalog
- Skill detail fetching with owner information
- Separate `installed_skills` directory with `Installed` trust level
- SSRF protection and ZIP bomb protection (size limits, overflow checks)

Security hardening:
- 10 MB download size cap
- 1 MB uncompressed size cap with read limits
- Checked arithmetic for ZIP header offsets
- IPv4-mapped IPv6 address handling in SSRF checks
- No internal registry URL leakage in error messages

# Lemon Status
- Current state: Lemon has skills system with local skill discovery
- Gap: No centralized skill catalog or search; no skill marketplace integration

# Investigation Notes
- Complexity estimate: L
- Value estimate: M (ecosystem growth)
- Open questions:
  - Should Lemon have a centralized skill registry/catalog?
  - Would this be hosted by Lemon or a third-party service?
  - How would skill trust levels work with downloaded skills?
  - Should skills be installable via the Web UI?

# Recommendation
defer - Nice-to-have for ecosystem growth, but Lemon's current local skill system works well. Could be revisited when there's a critical mass of community skills.

# References
- IronClaw commit: 4e2dd76
- Files affected: skills/catalog.rs, skills/registry.rs, tools/builtin/skill_tools.rs, channels/web/handlers/skills.rs
