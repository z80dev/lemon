# Changelog

All notable changes to `lemon_media` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release as a standalone package. `lemon_media` began as a capability
driver extracted from `lemon_core` and was not originally on the publish list;
it is published because two published packages depend on it (see D13 in
`docs/platform-split.md`).

### Added

- `LemonMedia.MediaJobs` — the job record store: `record/2` for a single
  transition, `recent/1` and `summary/1` for reading back, and `cleanup/1` for
  retention.
- `LemonMedia.MediaJobSupervisor` — a dynamic supervisor with `start_job/2`,
  which records the job as `:queued`, starts a temporary worker for it and
  returns immediately, and `status/0`, which answers with a zeroed shape rather
  than raising when the supervisor is not running.
- `LemonMedia.MediaJobWorker` — runs one job through
  `queued → running → completed`/`failed`, recording each transition and
  broadcasting `{:media_job, event, job}` on the `"media_jobs"` topic of
  `LemonCore.PubSub`. A runner that raises, exits or returns an unrecognised
  value is recorded as a failure rather than taking the caller down.
- `mix lemon.media` for inspecting jobs and artifacts from the shell.

### Notes on what is stored

- **Records are redacted by construction.** Free text never reaches disk: a
  prompt becomes `prompt_hash` plus `prompt_chars`, an error becomes
  `error_hash` plus a coarse `error_kind`, and provider, model, channel and
  artifact names go through label redaction. That is the reason media jobs are
  a store of their own rather than log lines.
- Jobs default to `<project_dir>/.lemon/media-jobs` and artifacts to
  `<project_dir>/.lemon/media-artifacts`. Both are per-call options
  (`:dir`, `:artifacts_dir`, `:project_dir`), so an embedding application is
  not tied to Lemon's filesystem layout.
- `cleanup/1` prunes by age and count, defaulting to 30 days, 500 jobs and 250
  artifacts; `summary/1` reports the policy in force alongside the counts.

### Changed

- `mix lemon.media` dropped its unreachable non-map `safe_worker_status/1`
  clause (`MediaJobSupervisor.status/0` answers a map on every path, including
  its own `rescue`), keeping the app Dialyzer-clean for
  `scripts/dialyzer_gate.sh`.
