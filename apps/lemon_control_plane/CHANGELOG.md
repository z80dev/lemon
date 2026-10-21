# Changelog

All notable changes to `lemon_control_plane` are documented here.

## [Unreleased]

### Added

- Admin-only controller and named-node Codex device login start/poll/cancel plus
  internal challenge/completion/settlement RPCs, with complete binding schemas and
  fixed identities. Completion carries the exact destination-generated nonce,
  never a cross-machine wall-clock deadline. The target enforces its own
  five-second monotonic nonce lifetime; new completions inspect and pin the
  current node connection and generation. Non-writing fixed-ID settlement uses
  the current connection even after token expiry, session replacement or restart.
  Revocation/re-pairing never waits for unresolved provider work. Only exact
  destination `provider_binding_rejected` errors attest that request's login
  binding was rejected without writing; generic denial and later pre-dispatch
  rejection do not resolve an earlier uncertain completion. Public results remain
  allowlisted; challenges, OAuth tokens and upstream failures never reach clients.

- Admin-scoped target-bound provider capability/status listing, write-only API-key
  add/replace, local disconnect and explicit default selection for the controller
  and authenticated execution nodes. Credentials stay in the selected target's
  encrypted secret store and provider configuration through CLI onboarding
  persistence; local disconnect is not provider-side revocation.

### Fixed

- Honor the configured HTTP/WebSocket listener IP so isolated benchmark runtimes
  can bind to loopback without changing the default or existing services.

- Generic node invocation cannot bypass provider-management administration scopes.
  Provider-management exceptions and node transport diagnostics omit raw request
  values; uncertain mutation failures explicitly prohibit automatic retry.
