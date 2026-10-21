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
