---
plan_id: PLN-20260302-tool-call-name-normalization
branch: feature/pln-20260302-tool-call-name-normalization
target: main
review_doc: planning/reviews/RVW-PLN-20260302-tool-call-name-normalization.md
---

# Merge: Tool Call Name Normalization

## Landing Commands

```bash
cd ~/dev/lemon
git checkout main
git pull origin main
git merge --no-ff feature/pln-20260302-tool-call-name-normalization -m "feat: tool call name normalization for provider formatting drift

Implements dispatch hardening that normalizes tool call names before lookup,
preventing 'tool not found' failures when providers emit whitespace-padded names.

- Add normalize_tool_name/1 with Unicode whitespace support
- Update find_tool/2 to use normalized matching
- Emit telemetry when normalization occurs for diagnostics
- Add comprehensive tests for edge cases

Closes: IDEA-20260227-openclaw-tool-call-name-normalization"
git push origin main
```

## Pre-Landing Checklist

- [x] All tests pass (`mix test apps/agent_core/test/agent_core/loop/tool_calls_test.exs`)
- [x] Review completed (see RVW-PLN-20260302-tool-call-name-normalization.md)
- [x] Code follows project conventions
- [x] No breaking changes
- [x] Documentation updated (inline docs)

## Post-Landing

- [ ] Update plan status to `landed`
- [ ] Update INDEX.md
- [ ] Update JANITOR.md with summary

## Files Changed

- `apps/agent_core/lib/agent_core/loop/tool_calls.ex` - Normalization logic
- `apps/agent_core/test/agent_core/loop/tool_calls_test.exs` - Tests
- `planning/plans/PLN-20260302-tool-call-name-normalization.md` - Plan
- `planning/INDEX.md` - Added active plan entry
- `planning/reviews/RVW-PLN-20260302-tool-call-name-normalization.md` - Review
- `planning/merges/MRG-PLN-20260302-tool-call-name-normalization.md` - This file
