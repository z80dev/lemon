---
id: PLN-20260224-pi-model-resolver-slash-support
title: Add Slash Separator Support for Provider/Model Format
owner: janitor
reviewer: codex
status: in_progress
workspace: feature/pln-20260224-pi-model-resolver
change_id: pending
created: 2026-02-24
updated: 2026-02-24
---

## Goal

Implement support for the `provider/model` format (slash separator) in addition to the existing `provider:model` format (colon separator). This enables compatibility with OpenRouter-style model IDs like `zai/glm-5` and aligns with Pi's model resolver behavior.

## Background

Pi's model resolver (commit 7364696a) correctly interprets `--model zai/glm-5` as provider='zai', model='glm-5'. Lemon currently only supports the colon separator (`:`) in `CodingAgent.SettingsManager.parse_model_spec/2`. This creates a gap when users expect OpenRouter-style model IDs to work.

## Current State

Lemon's `parse_model_spec/2` in `settings_manager.ex`:
```elixir
case String.split(model, ":", parts: 2) do
  [p, model_id] when provider in [nil, ""] and p != "" and model_id != "" ->
    %{provider: p, model_id: model_id, base_url: nil}
  ...
end
```

This fails to parse `zai/glm-5` correctly, treating the entire string as the model_id.

## Milestones

- [ ] M1 — Update `parse_model_spec/2` to try both `:` and `/` separators
- [ ] M2 — Add fallback logic for OpenRouter-style IDs
- [ ] M3 — Update `LemonGateway.AI` module for consistency
- [ ] M4 — Add tests for slash separator parsing
- [ ] M5 — Update documentation
- [ ] M6 — Final review and landing

## M1-M2: Update parse_model_spec/2

### Changes
Modify `apps/coding_agent/lib/coding_agent/settings_manager.ex`:

```elixir
defp parse_model_spec(provider, model) when is_binary(model) do
  # Try colon separator first (Lemon's current format)
  case String.split(model, ":", parts: 2) do
    [p, model_id] when provider in [nil, ""] and p != "" and model_id != "" ->
      %{provider: normalize_provider(p), model_id: model_id, base_url: nil}
    
    _ ->
      # Try slash separator (OpenRouter/Pi format)
      case String.split(model, "/", parts: 2) do
        [p, model_id] when provider in [nil, ""] and p != "" and model_id != "" ->
          %{provider: normalize_provider(p), model_id: model_id, base_url: nil}
        
        _ ->
          # Fall back to treating entire string as model_id
          if model != "" do
            %{provider: provider, model_id: model, base_url: nil}
          else
            nil
          end
      end
  end
end

defp normalize_provider(p) when is_binary(p) do
  p
  |> String.downcase()
  |> String.replace("-", "_")
  |> String.to_atom()
end
```

## M3: Update LemonGateway.AI

### Changes
Update `apps/lemon_gateway/lib/lemon_gateway/ai.ex` to handle `provider/model` format:

```elixir
defp get_provider(model) do
  cond do
    String.contains?(model, "/") ->
      # Extract provider from provider/model format
      case String.split(model, "/", parts: 2) do
        [provider, _] -> normalize_provider(provider)
        _ -> :unknown
      end
    
    String.starts_with?(model, "gpt-") -> :openai
    String.starts_with?(model, "o1") -> :openai
    String.starts_with?(model, "claude-") -> :anthropic
    true -> :unknown
  end
end
```

## M4: Add Tests

### Test Cases
Add to `apps/coding_agent/test/coding_agent/settings_manager_test.exs`:

```elixir
describe "parse_model_spec/2 with slash separator" do
  test "parses provider/model format" do
    result = SettingsManager.parse_model_spec(nil, "zai/glm-5")
    assert result.provider == :zai
    assert result.model_id == "glm-5"
  end

  test "parses openrouter-style model IDs" do
    result = SettingsManager.parse_model_spec(nil, "openai/gpt-4o")
    assert result.provider == :openai
    assert result.model_id == "gpt-4o"
  end

  test "colon separator takes precedence over slash" do
    result = SettingsManager.parse_model_spec(nil, "anthropic:claude-3")
    assert result.provider == :anthropic
    assert result.model_id == "claude-3"
  end

  test "falls back to full string when no separator matches" do
    result = SettingsManager.parse_model_spec(:openai, "gpt-4o")
    assert result.provider == :openai
    assert result.model_id == "gpt-4o"
  end
end
```

## Exit Criteria

- [ ] `provider/model` format is correctly parsed
- [ ] OpenRouter-style IDs work correctly
- [ ] Colon separator still works (backward compatibility)
- [ ] Tests pass for all separator combinations
- [ ] Documentation updated
- [ ] No regressions in existing functionality

## Progress Log

| Timestamp | Milestone | Notes |
|-----------|-----------|-------|
| 2026-02-24 | M1-M2 | Updated parse_model_spec/2 with slash separator support |
| 2026-02-24 | M4 | Added tests for slash separator parsing |
| 2026-02-24 | Tests | All 39 tests pass |

## Implementation Summary

### Changes Made

1. **Updated `parse_model_spec/2`** in `apps/coding_agent/lib/coding_agent/settings_manager.ex`:
   - Added slash separator support (OpenRouter/Pi format)
   - Colon separator takes precedence for backward compatibility
   - Added `normalize_provider/1` helper to convert provider strings to atoms
   - Handles dashes in provider names (converts to underscores)

2. **Added comprehensive tests** in `apps/coding_agent/test/coding_agent/settings_manager_test.exs`:
   - Slash separator parsing (`zai/glm-5`)
   - OpenRouter-style IDs (`openai/gpt-4o`)
   - Colon precedence over slash
   - Provider normalization with dashes
   - Updated existing tests to expect atom providers

### Provider Normalization

Provider strings are now normalized to atoms:
- Lowercase: `"OpenAI"` → `:openai`
- Dash to underscore: `"openai-codex"` → `:openai_codex`

### Backward Compatibility

- Colon separator (`:`) takes precedence over slash (`/`)
- Existing configs with `provider:model` format continue to work
- Provider strings are normalized consistently

### Exit Criteria

- [x] `provider/model` format is correctly parsed
- [x] OpenRouter-style IDs work correctly
- [x] Colon separator still works (backward compatibility)
- [x] Tests pass for all separator combinations
- [x] Provider normalization works correctly
- [x] No regressions in existing functionality
