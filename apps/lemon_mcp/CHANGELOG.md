# Changelog

## [Unreleased]

### Added

- Allow hosts to inject an arity-two `:port_open` callback into stdio clients and transports, defaulting to `Port.open/2`. Reject invalid callbacks/results and preserve host launch refusals without fallback; the library remains independent of umbrella applications.

### Fixed

- Reject out-of-range HTTP destination ports that Elixir 1.20's URI parser discards instead of authorizing the default origin.
- Deliver legacy SSE endpoint events immediately even when the HTTP headers and first chunk arrive together, avoiding an intermittent handshake deadlock in OTP's `httpc` streaming. Preserve SSE fields split across chunks and restore the legacy SSE tests to the gating suite.
- Preserve legacy SSE disconnect handling with Mint socket events, and log and ignore stray client messages without exposing their contents.
