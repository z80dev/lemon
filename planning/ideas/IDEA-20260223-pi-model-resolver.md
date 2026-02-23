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
- Current state: **PARTIALLY IMPLEMENTED** - Different separator, may need enhancement
- Implementation details:

## Current Implementation
Lemon uses `:` as separator in `CodingAgent.SettingsManager.parse_model_spec/2`:
```elixir
case String.split(model, ":", parts: 2) do
  [p, model_id] -> %{provider: p, model_id: model_id}
  ...
end
```

## Gap Analysis
1. **Slash separator not supported** - `provider/model` format fails
2. **OpenRouter models** - Use `provider/model` format (e.g., `z-ai/glm-4-32b`)
3. **Gateway AI module** - Simple prefix matching, no split handling

## Affected Components
- `apps/coding_agent/lib/coding_agent/settings_manager.ex` - Only handles `:` separator
- `apps/lemon_gateway/lib/lemon_gateway/ai.ex` - Prefix-based provider detection
- OpenRouter models in `apps/ai/lib/ai/models/open_router.ex` use `/` in IDs

# Investigation Results

## 1. Settings Manager
- Uses `:` separator (line 223)
- Does NOT handle `/` separator
- Would fail to parse `zai/glm-5` correctly

## 2. Gateway AI Module
- Simple prefix matching (lines 34-39)
- `String.starts_with?(model, "gpt-")` for OpenAI
- No handling for `provider/model` format

## 3. OpenRouter Models
- Model IDs like `z-ai/glm-4-32b` in registry
- Would not be parsed correctly by current code

# Recommendation
**Implement** - Add slash separator support:

1. Update `parse_model_spec/2` to try both `:` and `/` separators
2. Add fallback logic like Pi's implementation
3. Test with OpenRouter model IDs
4. Consider updating gateway AI module

## Proposed Implementation
```elixir
defp parse_model_spec(provider, model) when is_binary(model) do
  # Try colon separator first (Lemon's current format)
  case String.split(model, ":", parts: 2) do
    [p, model_id] when provider in [nil, ""] and p != "" and model_id != "" ->
      %{provider: p, model_id: model_id, base_url: nil}
    
    _ ->
      # Try slash separator (OpenRouter/Pi format)
      case String.split(model, "/", parts: 2) do
        [p, model_id] when provider in [nil, ""] and p != "" and model_id != "" ->
          %{provider: p, model_id: model_id, base_url: nil}
        
        _ ->
          # Fall back to treating entire string as model_id
          %{provider: provider, model_id: model, base_url: nil}
      end
  end
end
```

# References
- Pi commit: 7364696a
- Lemon files:
  - `apps/coding_agent/lib/coding_agent/settings_manager.ex` (lines 220-247)
  - `apps/lemon_gateway/lib/lemon_gateway/ai.ex` (lines 33-39)
  - `apps/ai/lib/ai/models/open_router.ex`
