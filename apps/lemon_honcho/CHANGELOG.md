# Changelog

## [Unreleased]

### Changed

- Remove unused tool `execute/4` wrappers and share excerpt rendering, client lookup, and session selection.
- Register Honcho tools with managed native-process ownership; application tests retain ownership in registry assertions.
- Track per-repository session-name Git lookups through the native-process ledger; unavailable provenance tracking skips Git and retains the directory-name fallback.
