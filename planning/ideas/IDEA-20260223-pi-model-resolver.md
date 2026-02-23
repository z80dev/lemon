---
id: IDEA-20260223-pi-model-resolver
title: [Pi] Provider/Model Split Resolution for Gateway Model IDs
source: pi
source_commit: 7364696a
discovered: 2026-02-23
status: proposed
---

# Description
Pi improved model resolution to correctly handle provider/model split (commit 7364696a). This feature:
- Correctly interprets `--model zai/glm-5` as provider='zai', model='glm-5'
- Falls back to raw ID matching for OpenRouter-style IDs like `openai/gpt-4o:extended`
- Fixes issue where gateway model ID matching was too greedy

Key changes in upstream:
- Modified `packages/coding-agent/src/core/model-resolver.ts`
- Added 98 lines of new code with 41 lines of tests
- Implements split-then-match logic with fallback

# Lemon Status
- Current state: **Unknown** - Need to verify Lemon's model resolution
- Gap analysis:
  - Lemon has model routing in `apps/lemon_router/` and `apps/ai/`
  - Has `Ai.ProviderRegistry` for provider lookup
  - Unclear if Lemon has same provider/model split issue
  - May affect `apps/ai/lib/ai/model_resolver.ex` if it exists

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **M** - Fixes potential model routing bugs
- Open questions:
  1. Does Lemon have a model resolver that handles provider/model splits?
  2. How does Lemon handle gateway model IDs with slashes?
  3. Is there a similar greedy matching issue in Lemon's codebase?
  4. What model ID formats does Lemon currently support?

# Recommendation
**Investigate** - Check if Lemon has this issue:
1. Search for model resolution logic in `apps/ai/` and `apps/lemon_router/`
2. Test model routing with `provider/model` format
3. Verify OpenRouter-style IDs work correctly
4. Implement fix if needed

# References
- Pi commit: 7364696a
- Lemon files to investigate:
  - `apps/ai/lib/ai/` - Model resolution logic
  - `apps/lemon_router/lib/lemon_router/` - Routing logic
