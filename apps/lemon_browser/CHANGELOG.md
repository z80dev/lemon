# Changelog

All notable changes to `lemon_browser` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release as a standalone package. `lemon_browser` is the browser
capability driver that was extracted from `lemon_core` in July 2026 together
with the media and LSP drivers; it is published as a clean leaf on
`lemon_core` (see D14 in `docs/platform-split.md`).

### Added

- `LemonBrowser.LocalServer` — a supervised `GenServer` that owns a Node +
  Playwright helper process and speaks a line-delimited JSON protocol over its
  stdin/stdout. `request/3` (or `request/4` against a named server) sends one
  `{method, args}` pair and answers `{:ok, result}` / `{:error, reason}`;
  `status/0` reports availability, the live port, pending and completed and
  failed counts, and the resolved driver configuration; `stop/1` shuts the
  helper down. The port is opened lazily on the first request, so nothing is
  spawned in applications that never drive a browser.
- `LemonBrowser.RoutePolicy` — navigation classification and guardrails shared
  by every caller. `validate_navigation/2` classifies a URL as a local
  document, a private-network address or a public address, enforces the
  requested `"auto" | "public" | "local"` route against that classification,
  and refuses cloud metadata endpoints (`169.254.169.254`,
  `metadata.google.internal`, `metadata`) on every route. `safe/1` reduces a
  policy to the subset that is safe to hand back to a caller or a log.
- `LemonBrowser.Artifacts` — a metadata view over the files a browser session
  leaves on disk: `recent/1`, `summary/1` and `cleanup/1`, plus `default_dir/1`
  (`<project_dir>/.lemon/browser-artifacts`). `cleanup/1` prunes by age and
  count, defaulting to 14 days and 100 files, and reports the policy it
  applied.
- `LemonBrowser.Env` — the app's environment-variable registry, aggregated by
  `LemonCore.Env`: `LEMON_BROWSER_DRIVER_PATH`, `LEMON_BROWSER_CDP_ENDPOINT`,
  `LEMON_BROWSER_ATTACH_ONLY` and `LEMON_BROWSER_CDP_PORT` (default `18800`).
- `LemonBrowser.Application` — a one-child supervision tree starting
  `LemonBrowser.LocalServer`, so adding the dependency is all the wiring an
  embedding application needs.

### Notes for consumers

- **The Node driver is not shipped in this package.** `LocalServer` resolves it
  from `LEMON_BROWSER_DRIVER_PATH`, and otherwise from
  `clients/lemon-browser-node/dist/local-driver.js` relative to the current
  working directory — the layout of the Lemon monorepo. Outside that
  monorepo, set `LEMON_BROWSER_DRIVER_PATH` to a driver that speaks the
  protocol documented on `LemonBrowser.LocalServer`.
- **A missing driver or a missing `node` degrades, it does not crash.**
  `request/3` answers `{:error, "node executable not found on PATH"}` or
  `{:error, "Local browser driver not built..."}`, the error is remembered in
  `status/0`, and the supervision tree stays up. A helper that exits fails only
  the requests in flight; the next request spawns a fresh one. Requests that
  outlive their `timeout_ms` answer `{:error, "Browser request timed out"}`
  rather than leaking a pending caller.
- `RoutePolicy` is pure and has no dependency on the driver, so it can be used
  on its own to vet URLs before handing them to any browser automation.

### Changed before packaging

- Configuration reads moved onto `LemonCore.Env`, then onto a per-app
  `LemonBrowser.Env` registry, so the app declares its own variables instead of
  having them listed centrally in `lemon_core`.
- Dead defensive `receive` and branch clauses were removed from `LocalServer`;
  the protocol handling covers the cases the driver can actually produce.
- `LocalServer.signal_os_process/1` binds the discarded `System.cmd("kill", …)`
  result (`:unmatched_returns` Dialyzer flag), so the app stays on the hard-green
  Dialyzer allowlist (`scripts/dialyzer_gate.sh`). Behaviour is unchanged: the
  `SIGTERM` was and stays fire-and-forget.
