---
plan_id: PLN-20260302-tool-call-name-normalization
reviewer: janitor
completed_at: 2026-03-02
---

# Review: Tool Call Name Normalization

## Summary

Implementation of tool call name normalization to handle provider formatting drift, preventing "tool not found" failures when providers emit whitespace-padded names.

## Changes Reviewed

### 1. `apps/agent_core/lib/agent_core/loop/tool_calls.ex`

**Changes:**
- Modified `find_tool/2` to use normalized name matching
- Added `normalize_tool_name/1` public function with `@doc` and `@spec`
- Added `normalize_unicode_whitespace/1` private helper
- Added telemetry emission `[:agent_core, :tool_call, :name_normalized]` when normalization is needed

**Review Notes:**
- ✅ Normalization handles leading/trailing whitespace
- ✅ Unicode whitespace characters are normalized (non-breaking space, en/em spaces, etc.)
- ✅ Internal whitespace is collapsed to single space
- ✅ Telemetry provides original_name and matched_tool_name for diagnostics
- ✅ Function is public and documented for testing/reuse
- ✅ No breaking changes - exact matches still work

### 2. `apps/agent_core/test/agent_core/loop/tool_calls_test.exs`

**Changes:**
- Added test: "finds tool with whitespace-padded name via normalization"
- Added test: "finds tool with internal whitespace via normalization"
- Added test: "returns error for tool not found after normalization"
- Added test: "normalize_tool_name/1 trims whitespace and normalizes Unicode"

**Review Notes:**
- ✅ Tests cover leading/trailing whitespace
- ✅ Tests cover internal tab/space normalization
- ✅ Tests cover Unicode whitespace (non-breaking space)
- ✅ Tests verify "not found" behavior is preserved
- ✅ All 8 tests pass (4 existing + 4 new)

## Success Criteria Verification

| Criterion | Status | Evidence |
|-----------|--------|----------|
| Tool calls with leading/trailing whitespace matched | ✅ | Test: "finds tool with whitespace-padded name via normalization" |
| Tool calls with Unicode whitespace normalized | ✅ | Test: "normalize_tool_name/1 trims whitespace and normalizes Unicode" |
| Telemetry emitted on normalization | ✅ | Code review: `LemonCore.Telemetry.emit` in `find_tool/2` |
| Existing tests pass | ✅ | 8 tests, 0 failures |
| New tests cover edge cases | ✅ | 4 new tests added |

## Risk Assessment

- **Low Risk**: Changes are additive (normalization layer on top of existing matching)
- **Backward Compatible**: Exact matches still work; normalization only helps when exact match would fail
- **Observable**: Telemetry provides visibility into when normalization occurs
- **Well-Tested**: Comprehensive test coverage for edge cases

## Recommendations

1. **Proceed to land** - Implementation is complete, tested, and low-risk
2. **Future Enhancement** (optional): Consider defense-in-depth by adding normalization at provider adapter level
3. **Monitoring**: Watch telemetry for `[:agent_core, :tool_call, :name_normalized]` to identify provider quality issues

## Checklist

- [x] Code changes reviewed
- [x] Tests reviewed and passing
- [x] Documentation reviewed (inline `@doc` and `@spec`)
- [x] No breaking changes identified
- [x] Telemetry events appropriate
- [x] Success criteria met
