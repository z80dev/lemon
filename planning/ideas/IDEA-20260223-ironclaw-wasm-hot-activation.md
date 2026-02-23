---
id: IDEA-20260223-ironclaw-wasm-hot-activation
title: [IronClaw] Hot-Activate WASM Channels with Channel-First Prompts
source: ironclaw
source_commit: ea57447
discovered: 2026-02-23
status: proposed
---

# Description
IronClaw added hot-activation for WASM channels and channel-first prompts (commit ea57447). This feature:
- Hot-activates WASM channels without restart
- Adds channel-first prompts for better UX
- Unifies artifact resolution into registry module
- Fixes multiple bugs with CARGO_TARGET_DIR and WASM triples
- 1,411 lines of changes across 29 files

Key changes in upstream:
- New `src/registry/artifacts.rs` module
- Modified `src/extensions/manager.rs` for hot-activation
- Added channel runtime wiring in `main.rs`
- Fixed bundled.rs to search all WASM triples

# Lemon Status
- Current state: **Unknown** - Need to verify Lemon's WASM channel support
- Gap analysis:
  - Lemon has WASM extension support in `apps/coding_agent/`
  - Has `CodingAgent.WasmTool` for WASM tools
  - Unclear if hot-activation is supported
  - May not have channel-first prompts

# Investigation Notes
- Complexity estimate: **L**
- Value estimate: **M** - Operational improvement
- Open questions:
  1. Does Lemon support WASM channel hot-activation?
  2. How does Lemon handle WASM extension lifecycle?
  3. Are channel-first prompts relevant to Lemon's architecture?
  4. What's the operational impact of requiring restarts?

# Recommendation
**Investigate** - Check WASM extension management:
1. Review `apps/coding_agent/lib/coding_agent/wasm_tool.ex`
2. Check if WASM extensions require restart to activate
3. Determine if hot-activation would improve operations
4. Consider implementing if operational benefit is high

# References
- IronClaw commit: ea57447
- Lemon files to investigate:
  - `apps/coding_agent/lib/coding_agent/wasm_tool.ex`
  - `apps/coding_agent/lib/coding_agent/extension_tools.ex`
