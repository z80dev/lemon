# Plan: AI App Test Expansion

## Metadata
- **Plan ID**: PLN-20260223-ai-test-expansion
- **Status**: in_review
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
| 2026-02-23 20:14 | zeebot | Added AI.Models tests | 61 tests, 0 failures | `apps/ai/test/ai/models_test.exs` |
| 2026-02-23 20:15 | zeebot | Added AI.Providers.Anthropic tests | 36 tests, 0 failures | `apps/ai/test/ai/providers/anthropic_test.exs` |
| 2026-02-23 20:17 | zeebot | Added AI.Providers.Google tests | 34 tests, 0 failures | `apps/ai/test/ai/providers/google_test.exs` |
| 2026-02-23 20:17 | zeebot | Added AI.Providers.Bedrock tests | 24 tests, 0 failures | `apps/ai/test/ai/providers/bedrock_test.exs` |
| 2026-02-23 20:18 | zeebot | Full test suite verification | 155 tests, 0 failures | All new test files |

## Results
- **Total new tests**: 155 tests added across 4 modules
- **AI.Models**: 61 tests covering model retrieval, capabilities, token limits, reasoning levels
- **AI.Providers.Anthropic**: 36 tests covering requests, responses, authentication
- **AI.Providers.Google**: 34 tests covering Gemini API integration
- **AI.Providers.Bedrock**: 24 tests covering AWS SigV4 signing and responses

## Related
- Parent: ROADMAP.md "Deterministic CI and test signal hardening"
