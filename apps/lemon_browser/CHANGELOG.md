# LemonBrowser changelog

## [Unreleased]

### Added

- Opt-in durable tracking for local browser-driver launches, with external-work
  uncertainty recorded before browser dispatch and retained on request errors.
  Authorization and unavailable-backend refusals remain pre-dispatch decisions.

### Changed

- `LocalServer` resolves the driver from `LEMON_BROWSER_DRIVER_PATH`, then the
  copy runtime releases bundle under `priv/driver`, then a source checkout's
  `clients/lemon-browser-node/dist` under `LEMON_PATH`; the cwd is not searched.
- `ProviderProbe.available?("local")` returns fixed reasons (`:node_missing`,
  `:driver_missing`, `:driver_incompatible`, `:browser_missing`), and the
  inspection helper reports driver builds lacking its exports distinctly.

### Fixed

- The local driver never starts a request after its deadline (requests carry
  `deadlineAtMs`; a queued one answers "timed out before it started"), runs
  one request at a time without overlapping an abandoned one, and re-runs only
  read-only methods after a closed target. An unfinished side-effecting request
  (click, type, navigate, ...) answers `{:error, :outcome_unknown}` from
  `LocalServer.request/4,5` and is never retried; `LocalServer.read_only_method?/2`
  names the read-only set (#625).
