# Changelog

## [Unreleased]

### Added

- Allow hosts to inject an arity-two `:port_open` callback into stdio clients and transports, defaulting to `Port.open/2`. Reject invalid callbacks/results and preserve host launch refusals without fallback; the library remains independent of umbrella applications.
