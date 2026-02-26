---
id: IDEA-20260225-ironclaw-kind-aware-extension-registry
title: [Ironclaw] Kind-Aware Extension Registry to Prevent Tool/Channel Name Collisions
source: ironclaw
source_commit: e9f32eaebea2
discovered: 2026-02-25
status: proposed
---

# Description
Ironclaw fixed a production issue where tool and channel entries with the same name (e.g., `telegram`) collided during install/discovery and caused wrong install targets. Their fix added kind-aware lookup (`name + kind`) and dedupe, plus stricter install path validation (`e9f32eaebea2`).

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon separates channel registry (`LemonChannels.Registry`) and coding-agent tool registry (`CodingAgent.ToolRegistry`), which reduces direct collision risk.
  - However, extension/WASM discovery and auth lookups remain largely name-based in places (e.g., capability-file lookup by `<name>.capabilities.json`), and there is no explicit cross-kind collision policy artifact.
  - Opportunity: formalize `(name, kind)` identity and collision diagnostics for extension/tool/channel install + discovery paths.

# Investigation Notes
- Complexity estimate: **S**
- Value estimate: **M**
- Open questions:
  1. Which Lemon registries should adopt an explicit `(name, kind)` key contract?
  2. Should `extensions_status` report cross-kind name conflicts, not only tool shadowing?
  3. Do any existing workflows depend on name-only lookup semantics?

# Recommendation
**investigate** — Small-to-medium hardening task with good DX/security payoff, especially as Lemon expands extension and channel ecosystems.
