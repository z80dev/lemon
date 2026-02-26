---
id: IDEA-20260223-openclaw-config-redaction
title: [OpenClaw] Redact Sensitive Values in Config Get Output
source: openclaw
source_commit: 9c87b53c8
discovered: 2026-02-23
status: completed
---

# Description
OpenClaw added security fix to redact sensitive values in `config get` CLI output (commit 9c87b53c8). This feature:
- Uses existing `redactConfigObject()` to scrub sensitive fields
- Prevents credential leakage in terminal/shell history
- Adds regression test and changelog entry
- Fixes issue #13683

Key changes in upstream:
- Modified `src/cli/config-cli.ts`
- Added redaction before `getAtPath()` resolves key
- 21 lines of new code with test

# Lemon Status
- Current state: **ALREADY IMPLEMENTED** - Lemon has comprehensive config redaction
- Implementation details:
  - `ConfigReloader.redact_value/2` in `apps/lemon_core/lib/lemon_core/config_reloader.ex`
  - Redaction patterns: `token`, `secret`, `api_key`, `password` (line 44)
  - Used in config reload diff computation (line 232, 371, 374, 377)
  - Tests in `config_reloader_test.exs` verify redaction behavior
  - `mix lemon.config show` only shows ✓/✗ for API keys, never the actual values

# Verification Results

## 1. ConfigReloader Redaction
✅ **Implemented** - `@redact_patterns ~w(token secret api_key password)` covers standard sensitive fields
✅ **Tested** - `config_reloader_test.exs` has tests for redaction
✅ **Used** - All config diffs are redacted before logging/display

## 2. CLI Config Show
✅ **Secure by default** - `mix lemon.config show` only shows presence (✓/✗) of API keys
✅ **No exposure** - Actual key values are never displayed

## 3. Comparison with OpenClaw
| Feature | OpenClaw | Lemon | Status |
|---------|----------|-------|--------|
| Config diff redaction | ✅ | ✅ | Parity |
| CLI get redaction | ✅ | ✅ | Parity |
| Pattern matching | `token`, `secret`, `key` | `token`, `secret`, `api_key`, `password` | Lemon has broader coverage |
| Tests | ✅ | ✅ | Parity |

# Recommendation
**No action needed** - Lemon already has full parity with OpenClaw's config redaction feature, with broader pattern coverage.

# References
- OpenClaw commit: 9c87b53c8
- Lemon implementation:
  - `apps/lemon_core/lib/lemon_core/config_reloader.ex` (lines 44, 232, 371, 374, 377, 423-432)
  - `apps/lemon_core/test/lemon_core/config_reloader_test.exs`
  - `apps/lemon_core/lib/mix/tasks/lemon.config.ex` (lines 151-158)
