# Changelog

## [Unreleased]

### Changed

- Share SSE event parsing between HTTP transports.
- Remove unused `LemonMCP` protocol wrappers; call `LemonMCP.Protocol` directly.

### Added

- Allow hosts to inject an arity-two `:port_open` callback into stdio clients and transports, defaulting to `Port.open/2`. Reject invalid callbacks/results and preserve host launch refusals without fallback; the library remains independent of umbrella applications.

### Removed

- **Breaking:** `LemonMCP.Sampling` and the stdio client's `:sampling_policy` / `:sampling_handler` options. No production caller supplied the required delegate, so sampling could never produce a result. Every server-to-client request, `sampling/createMessage` included, now receives method-not-found, and `LemonMCP.Protocol.client_capabilities/1` drops a caller-supplied `sampling` capability from every stdio, HTTP and SSE handshake.

### Fixed

- Reject out-of-range HTTP destination ports that Elixir 1.20's URI parser discards instead of authorizing the default origin.
- Run Streamable HTTP and legacy SSE requests in supervised workers answered with `GenServer.reply/2`: `state/1` and concurrent requests no longer wait for a slow server, a deadline (the shorter of the call timeout and `:timeout_ms`) kills the worker before returning `{:error, :outcome_unknown}`, a caller exit stops its request, and the no-policy `httpc` path gives each request its own connection under one total deadline instead of separate connect and response timeouts. A 401 refreshes the grant once for every affected request and retries each once; interactive re-authorization runs in the background while the request fails fast with the auth-required error. OAuth moved to `LemonMCP.HTTP.OAuth` and the HTTP exchange to `LemonMCP.HTTP.Transport`.
- Deliver legacy SSE endpoint events immediately even when the HTTP headers and first chunk arrive together, avoiding an intermittent handshake deadlock in OTP's `httpc` streaming. Preserve SSE fields split across chunks and restore the legacy SSE tests to the gating suite.
- Preserve legacy SSE disconnect handling with Mint socket events, and log and ignore stray client messages without exposing their contents.
