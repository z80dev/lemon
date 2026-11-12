# Changelog

## [Unreleased]

### Changed

- Cron admission rejects invalid callback URLs, remote HTTP callbacks and
  non-allowlisted origins distinctly, returning only a canonical origin for
  origin rejection. Cron RPCs and tool errors preserve these safe classifications.
- The `automation.cron_paused` doctor check skips from a standalone CLI without a
  local `CronManager` instead of reporting held-back runs; inside the runtime an
  unreadable pause state still warns.
- Register the platform cron tool with managed native-process ownership and assert its ownership-bearing registry entry.
- Fence command cron launches through the native-process ledger before shell effects, failing closed when the configured ledger is unavailable.

### Removed

- The `[automation] daily_brief` boot sync and `LemonAutomation.Heartbeat`'s
  `sync_daily_brief`, `daily_brief_params` and `daily_brief_id`. A brief is now an
  ordinary user-created cron job.
