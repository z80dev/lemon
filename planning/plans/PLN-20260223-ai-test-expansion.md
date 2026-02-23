# Plan: AI App Test Expansion

## Metadata
- **Plan ID**: PLN-20260223-ai-test-expansion
- **Status**: in_progress
- **Created**: 2026-02-23
- **Author**: zeebot

## Summary
Add comprehensive tests for untested modules in the `ai` app. The AI app has 11 untested modules out of 28 total, representing the lowest test coverage in the core apps.

## Scope
### In Scope
- Add tests for `AI.Models` module
- Add tests for `AI.Providers.Google` module
- Add tests for `AI.Providers.Anthropic` module
- Add tests for `AI.Providers.Bedrock` module
- Add tests for `AI.Providers.GoogleVertex` module

### Out of Scope
- Provider modules requiring external API calls (will use mocks)
- Integration tests (tagged as `:integration`)

## Success Criteria
- [ ] AI.Models has comprehensive tests
- [ ] AI.Providers.Google has comprehensive tests
- [ ] AI.Providers.Anthropic has comprehensive tests
- [ ] AI.Providers.Bedrock has comprehensive tests
- [ ] AI.Providers.GoogleVertex has comprehensive tests
- [ ] All tests pass (`mix test apps/ai/test`)
- [ ] No regressions in existing tests

## Progress Log
| Timestamp | Who | What | Result | Links |
|-----------|-----|------|--------|-------|
| 2026-02-23 18:40 | zeebot | Created plan | - | - |
| 2026-02-23 18:41 | zeebot | Scanned untested modules | Found 11 untested in ai app | - |

## Related
- Parent: ROADMAP.md "Deterministic CI and test signal hardening"
