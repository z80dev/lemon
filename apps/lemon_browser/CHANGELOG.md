# LemonBrowser changelog

## [Unreleased]

### Removed

- **Breaking:** `LemonBrowser.Backends.Controller`, `LemonBrowser.ControllerBroker`,
  `LemonBrowser.Backends.Hybrid`, `LemonBrowser.HybridRouter` and the
  `LEMON_BROWSER_HYBRID_*` settings; neither backend was selectable (#702).

### Fixed

- `TernSession` monitors its Tern client and reconnects on the next request
  after the client dies, keeping its block; a failed reconnect is a `:connect`
  error so auto-selected panes can fall back (#661).

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
