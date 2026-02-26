---
id: IDEA-20260223-oh-my-pi-strict-mode
title: [Oh-My-Pi] Tool Schema Strict Mode for OpenAI Providers
source: oh-my-pi
source_commit: 6c52f8cf
discovered: 2026-02-23
status: proposed
---

# Description
Oh-My-Pi introduced "strict mode" for OpenAI tool schemas (commit 6c52f8cf). This feature:
- Adds `strict: true/false` option to tool schema generation for OpenAI providers
- Enforces stricter validation of tool arguments at the API level
- Helps catch malformed tool calls earlier in the pipeline
- Includes comprehensive test coverage (107+ tests)

Key changes in upstream:
- Modified `packages/ai/src/providers/openai-*.ts` files
- Added `strict` field to tool conversion logic
- Added validation utilities in `packages/ai/src/utils/validation.ts`
- Tests in `packages/ai/test/openai-tool-strict-mode.test.ts`

# Lemon Status
- Current state: **Partial** - Lemon has basic strict mode support in OpenAI providers
- Gap analysis:
  - `apps/ai/lib/ai/providers/openai_responses_shared.ex` has `strict` option (line 578)
  - Tests exist in `openai_responses_shared_test.exs` for strict mode
  - However, may not have full validation utilities like upstream
  - Need to verify if strict mode is properly propagated through all OpenAI provider variants

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **M** - Better error handling, catches tool schema issues early
- Open questions:
  1. Does Lemon's strict mode cover all OpenAI provider variants (Codex, Responses, Completions)?
  2. Are we missing validation utilities that upstream has?
  3. Should strict mode be configurable per-provider or global?
  4. What's the performance impact of strict validation?

# Recommendation
**Defer** - Lemon appears to have basic strict mode support. Needs deeper audit to determine if full upstream parity is needed. Not a high-priority feature gap.

# References
- Oh-My-Pi commit: 6c52f8cf
- Lemon file: `apps/ai/lib/ai/providers/openai_responses_shared.ex`
- Lemon tests: `apps/ai/test/providers/openai_responses_shared_test.exs`
