# Changelog

## [Unreleased]

### Changed

- `CronManager` releases claims whose `submission_started` was never recorded
  (restart, worker crash, startup reconcile, abort) as retryable failures;
  `RunSubmitter` maps a pre-router `:exception`/`:exit` to a definite failure.
  `:outcome_unknown` is kept only once submission started (#624).
- `CronStore` is the sole owner of cron retention: `cleanup_old_runs/1` keeps
  active and outcome-unknown runs, new `cleanup_audit_events/1` caps the audit
  log (default `audit_retention_max/0`, 10,000 events) on the hourly tick, and
  `list_audit_events/1` accepts a `:before_ts_ms` page cursor (#675).
- Curator and synthesis schedulers share interval execution and runner config
  handling. A missing task supervisor defers a pass instead of crashing the manager.
- Cron admission rejects invalid callback URLs, remote HTTP callbacks and
  non-allowlisted origins distinctly, returning only a canonical origin for
  origin rejection. Cron RPCs and tool errors preserve these safe classifications.
- The `automation.cron_paused` doctor check skips from a standalone CLI without a
  local `CronManager` instead of reporting held-back runs; inside the runtime an
  unreadable pause state still warns.
- Register the platform cron tool with managed native-process ownership and assert its ownership-bearing registry entry.
- Fence command cron launches through the native-process ledger before shell effects, failing closed when the configured ledger is unavailable.

### Removed

- Unused top-level `LemonAutomation` delegates and the `LemonAutomation.Wake`
  wrapper/batch API. Call `LemonAutomation.CronManager` directly.
- The ignored third argument to `CronCommandRunner.submit`; use `submit/2`.
- The `[automation] daily_brief` boot sync and `LemonAutomation.Heartbeat`'s
  `sync_daily_brief`, `daily_brief_params` and `daily_brief_id`. A brief is now an
  ordinary user-created cron job.
