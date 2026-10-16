# Changelog

All notable changes to `lemon_control_plane` are documented here.

## [Unreleased]

### Added

- Admin-scoped target-bound provider capability/status listing, write-only API-key
  add/replace, local disconnect and explicit default selection for the controller
  and authenticated execution nodes. Credentials stay in the selected target's
  encrypted secret store and provider configuration through CLI onboarding
  persistence; local disconnect is not provider-side revocation.

### Fixed

- Generic node invocation cannot bypass provider-management administration scopes.
  Provider-management exceptions and node transport diagnostics omit raw request
  values; uncertain mutation failures explicitly prohibit automatic retry.
