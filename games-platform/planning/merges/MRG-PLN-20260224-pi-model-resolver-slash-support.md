---
plan_id: PLN-20260224-pi-model-resolver-slash-support
landed_at: 2026-02-24
landed_by: janitor
---

# Merge Record: Pi Model Resolver - Slash Separator Support

## Summary

Successfully implemented slash separator support for provider/model format, achieving parity with Pi's model resolver.

## Changes Landed

### Code Changes
- `apps/coding_agent/lib/coding_agent/settings_manager.ex`
  - Updated `parse_model_spec/2` to try both `:` and `/` separators
  - Added `normalize_provider/1` helper for consistent provider atom conversion
  - Colon separator takes precedence for backward compatibility

- `apps/coding_agent/test/coding_agent/settings_manager_test.exs`
  - Added 5 new tests for slash separator parsing
  - Updated existing tests for atom provider expectations

### New Supported Formats
- `openai:gpt-4` (existing colon format)
- `zai/glm-5` (new slash format - Pi style)
- `openai/gpt-4o` (OpenRouter-style)

### Provider Normalization
- Lowercase: `"OpenAI"` → `:openai`
- Dash to underscore: `"openai-codex"` → `:openai_codex`

## Test Results

- All 39 settings_manager tests pass
- 5 new tests for slash separator functionality
- No regressions in existing functionality

## Verification

```elixir
# Colon separator (existing)
parse_model_spec(nil, "openai:gpt-4")
# => %{provider: :openai, model_id: "gpt-4", base_url: nil}

# Slash separator (new)
parse_model_spec(nil, "zai/glm-5")
# => %{provider: :zai, model_id: "glm-5", base_url: nil}

# OpenRouter-style
parse_model_spec(nil, "openai/gpt-4o")
# => %{provider: :openai, model_id: "gpt-4o", base_url: nil}
```

## Exit Criteria

- [x] `provider/model` format is correctly parsed
- [x] OpenRouter-style IDs work correctly
- [x] Colon separator still works (backward compatibility)
- [x] Tests pass for all separator combinations
- [x] Provider normalization works correctly
- [x] No regressions in existing functionality

## Related

- Idea: IDEA-20260223-pi-model-resolver
- Upstream: Pi commit 7364696a
