# Changelog

## [Unreleased]

### Changed

- Remove unused tool `execute/4` wrappers and share excerpt rendering, client lookup, and session selection.
- Register Honcho tools with managed native-process ownership; application tests retain ownership in registry assertions.
- Track per-repository session-name Git lookups through the native-process ledger; unavailable provenance tracking skips Git and retains the directory-name fallback.

### Fixed

- `LemonHoncho.Client` sends `chat/4`, `add_messages/3`, `create_conclusions/2` and the conclusion delete exactly once: a 5xx is one request and one error, and a timeout or dropped connection after sending returns `{:error, :outcome_unknown}` instead of a retryable transport error. Only GET reads and POST/PUT calls declared idempotent (get-or-create, search, replace) retry, and a server's `Retry-After` is capped at one second per pause and two seconds per call. The reasoning and conclude tools tell the model an unanswered request may still have been applied (#622).
- **Breaking:** `LemonHoncho.MemoryProvider.search/2` is removed; the provider is a `put/2` write target only and `recall` never searches Honcho (#656).
