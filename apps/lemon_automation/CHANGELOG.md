# Changelog

## [Unreleased]

### Changed

- `CronManager` matches every `CronStore` write and delete result: a failed
  write emits no event, leaves in-memory state unchanged and replies
  `{:error, :store_unavailable}`, or `{:error, :outcome_unknown}` when the
  write may have landed (`add`, `update`, `refresh_captured_model`, `remove`,
  `run_now`, `wake`, `abort_run`). A run starts with one write and is
  submitted only once it is confirmed. An unpersisted terminal is not
  announced, delivered or retried, and `abort_run` replies
  `{:error, :outcome_unknown}` for it; recovery finishes the run (#87).
- **Breaking:** cron numeric fields are validated by the new shared
  `CronJob.numeric_bounds/0` / `CronJob.validate_numeric/2` (add, update, the
  `cron` tool and blueprints); out-of-range or non-integer values return
  `{:error, {:invalid_target, reason}}`. Blueprint `retryBackoffMs` now allows
  0. Timers derived from job data are capped at 300,000 ms (#657).
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

### Fixed

- `CronManager.run_now_with_id/2` runs a job under a caller-fixed cron run ID,
  claimed durably before it is announced; a reused ID is `{:error, :exists}`
  and never overwrites the earlier run; an earlier unresolved run refuses it
  with `{:prior_run_unresolved, prior_run_id}` before the ID is claimed.
  `cron.run` uses it so a lost reply still names the run (#620).
- `KanbanDispatcher` `control_revision` ignores lease renewals and other
  heartbeat-only task metadata, so it stays stable between ticks and an
  operator stop bound to it succeeds (#658).

### Removed

- `LemonAutomation.GoalContinuationManager`. One-shot continuations call
  `GoalLoopManager.run_once(session_key, verdict: :continue)` (#659).
- Unused top-level `LemonAutomation` delegates and the `LemonAutomation.Wake`
  wrapper/batch API. Call `LemonAutomation.CronManager` directly.
- The ignored third argument to `CronCommandRunner.submit`; use `submit/2`.
- The `[automation] daily_brief` boot sync and `LemonAutomation.Heartbeat`'s
  `sync_daily_brief`, `daily_brief_params` and `daily_brief_id`. A brief is now an
  ordinary user-created cron job.
