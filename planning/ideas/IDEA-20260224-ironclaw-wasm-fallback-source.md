---
id: IDEA-20260224-ironclaw-wasm-fallback-source
title: WASM extension fallback to build-from-source when download fails
source: ironclaw
source_commit: f4ba85f
discovered: 2026-02-24
status: proposed
---

# Description
IronClaw added a fallback mechanism for WASM extension installation. When the primary download URL fails (e.g., 404), the system automatically falls back to building from source. This improves reliability for extension installation.

Key features:
- `fallback_source` field in RegistryEntry for extension manifests
- Automatic fallback from WasmDownload to WasmBuildable on failure
- Combined error messages when both primary and fallback fail
- AlreadyInstalled errors short-circuit without attempting fallback
- Unit tests for fallback decision logic

Technical details:
- Extension manifests can specify both download URL and fallback build source
- Fallback triggers on any download error (not just 404)
- Error messages combine both primary and fallback errors for debugging

# Lemon Status
- Current state: Lemon has WASM extension support via lemon_skills
- Gap: No fallback mechanism for failed extension downloads

# Investigation Notes
- Complexity estimate: M
- Value estimate: M (reliability improvement)
- Open questions:
  - How does Lemon's skill system handle WASM extension installation?
  - Does the skill registry support multiple source types?
  - What is the current error handling for failed skill installations?

# Recommendation
proceed - Reliability improvement that helps when network issues or missing releases occur. Aligns with Lemon's WASM extension goals.

# References
- IronClaw commit: f4ba85f
- Files affected: extensions/discovery.rs, extensions/manager.rs, extensions/registry.rs, registry/manifest.rs
