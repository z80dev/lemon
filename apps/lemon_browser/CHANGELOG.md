# LemonBrowser changelog

## [Unreleased]

### Added

- Opt-in durable tracking for local browser-driver launches, with external-work
  uncertainty recorded before browser dispatch and retained on request errors.
  Authorization and unavailable-backend refusals remain pre-dispatch decisions.
