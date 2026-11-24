# LemonBrowser changelog

## [Unreleased]

### Added

- Opt-in durable tracking for local browser-driver launches, with external-work
  uncertainty recorded before browser dispatch and retained on request errors.
  Authorization and unavailable-backend refusals remain pre-dispatch decisions.
- `LocalServer.stop_driver/1` and the `LemonBrowser.stop_local_driver/0`
  facade stop the driver and the Chrome it launched on demand (#660).

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
- A failed browser start (slow Chrome launch, briefly unreachable relay or CDP
  endpoint) is retried on the next request instead of failing forever. Each
  request resolves its provider identity without mutating server state; an
  identity change recycles an idle driver and is refused while a request is in
  flight. `ProviderProbe.driver_options("local")` no longer forces
  `attach_only: false`, and `available?("local")` returns `:attach_only` when
  `LEMON_BROWSER_ATTACH_ONLY` is set, so Lemon never launches Chrome then (#660).
- **Breaking:** the bundled driver's default managed profile is
  `~/.lemon/browser/default/user-data` (no longer `~/.openclaw/...`). Managed
  Chrome runs on a free DevTools port and is never adopted from
  `LEMON_BROWSER_CDP_PORT`, which now only applies to attach-only mode. The
  driver stops its Chrome when stdin closes or stdout breaks, and reports a
  Chrome that cannot start as a request error (#689).
