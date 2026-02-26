---
id: PLN-20260222-debt-phase-05-m2-submodule-extraction
title: "Debt Phase 5 M2: Ai.Models submodule extraction"
created: 2026-02-22
updated: 2026-02-25
owner: janitor
reviewer: janitor
workspace: feature/pln-20260222-debt-phase-05-m2-submodule-extraction
change_id: pending
status: ready_to_land
roadmap_ref: ROADMAP.md
depends_on: []
---

# Summary

Refactor `Ai.Models` (11,203 lines) to delegate model data to 23 per-provider
submodules under `Ai.Models.*`, reducing the orchestration module to ~550 lines.
All public API functions and compile-time behavior are preserved unchanged.

## Scope

- In scope:
  - Remove ~10,650 lines of inline provider model data from `apps/ai/lib/ai/models.ex`
  - Import model maps from 23 per-provider submodules at compile time
  - Derive `openai-codex` models from `Ai.Models.OpenAI.models()` at compile time
  - Derive `google_antigravity` models from `Ai.Models.Google.antigravity_models()`
  - Keep `@providers` list and all public API functions byte-identical
  - Add `antigravity_models/0` to `Ai.Models.Google` for antigravity-only subset

- Out of scope:
  - Changing any public API behavior or signatures
  - Adding/removing/modifying model data
  - Restructuring the per-provider submodule format
  - Runtime provider registration

## Design

### Before

`Ai.Models` contained 25 `@xxx_models` module attributes defined inline with
full model data, merged via `Map.merge/2` in some cases. The module was
11,203 lines with ~10,650 lines of static model data.

### After

23 submodules under `Ai.Models.*` each expose a `models/0` function returning
`%{model_id => %Model{}}`. The main `Ai.Models` module:

1. Calls each submodule's `models/0` at compile time
2. Derives `openai-codex` by transforming `Ai.Models.OpenAI.models()`
3. Derives `google_antigravity` via `Ai.Models.Google.antigravity_models()`
4. Assembles the `@models` registry map keyed by provider atom
5. Preserves the `@providers` ordered list for deterministic iteration

### Provider-to-Submodule Mapping

| Provider atom            | Submodule                       |
|--------------------------|---------------------------------|
| `:anthropic`             | `Ai.Models.Anthropic`           |
| `:openai`                | `Ai.Models.OpenAI`              |
| `:"openai-codex"`        | Derived from `Ai.Models.OpenAI` |
| `:amazon_bedrock`        | `Ai.Models.AmazonBedrock`       |
| `:google`                | `Ai.Models.Google`              |
| `:google_antigravity`    | `Ai.Models.Google` (antigravity) |
| `:kimi`                  | `Ai.Models.Kimi`                |
| `:kimi_coding`           | `Ai.Models.KimiCoding`          |
| `:opencode`              | `Ai.Models.OpenCode`            |
| `:xai`                   | `Ai.Models.XAI`                 |
| `:mistral`               | `Ai.Models.Mistral`             |
| `:cerebras`              | `Ai.Models.Cerebras`            |
| `:deepseek`              | `Ai.Models.DeepSeek`            |
| `:qwen`                  | `Ai.Models.Qwen`                |
| `:minimax`               | `Ai.Models.MiniMax`             |
| `:zai`                   | `Ai.Models.ZAI`                 |
| `:azure_openai_responses`| `Ai.Models.AzureOpenAI`         |
| `:github_copilot`        | `Ai.Models.GitHubCopilot`       |
| `:google_gemini_cli`     | `Ai.Models.GoogleGeminiCLI`     |
| `:google_vertex`         | `Ai.Models.GoogleVertex`        |
| `:groq`                  | `Ai.Models.Groq`                |
| `:huggingface`           | `Ai.Models.HuggingFace`         |
| `:minimax_cn`            | `Ai.Models.MiniMaxCN`           |
| `:openrouter`            | `Ai.Models.OpenRouter`          |
| `:vercel_ai_gateway`     | `Ai.Models.VercelAIGateway`     |

## Verification

- `mix compile --no-optional-deps` passes
- `mix test apps/ai` passes (1952 tests, 0 failures)
- File reduced from 11,203 lines to 551 lines
- All public API functions preserved unchanged

## Files Changed

- `apps/ai/lib/ai/models.ex` — replaced inline data with submodule imports (11,203 -> 551 lines)
- `apps/ai/lib/ai/models/google.ex` — added `antigravity_models/0` and 6 missing antigravity model entries

## Progress Log

| Timestamp | Milestone | Notes |
|-----------|-----------|-------|
| 2026-02-22 | Implementation | Extracted provider model catalogs into `Ai.Models.*` submodules and reduced `Ai.Models` orchestration surface |
| 2026-02-22 | Validation | `mix compile --no-optional-deps` and `mix test apps/ai` green at implementation time |
| 2026-02-25 | Close-out alignment | Normalized plan metadata/status to planning-system semantics and re-ran AI test suite |
