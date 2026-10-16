# Changelog

All notable changes to `lemon_cli` are documented here.

## [Unreleased]

### Added

- Destination-local `LemonCli.Setup.ProviderManagement` for authorized transports:
  list provider capabilities/readiness, add or replace an encrypted API key,
  disconnect a local credential, and deliberately change the machine's default
  provider/model. All operations return the same bounded write-only projection;
  keys, secret references, config paths and upstream error text are never returned.
  The transport owns machine-owner authorization and exact target-ID validation.
  The CLI application registers this optional implementation at runtime for
  controller and named worker startup; core-only consumers fail closed when
  setup support is absent.
- Provider metadata covers the canonical runtime catalog, including unsupported
  provisioning methods. Phone-compatible device-code metadata reflects the real
  Codex, GitHub Copilot, Kimi Code and xAI device grants; browser-callback OAuth
  entry points are not advertised as device-code sign-in.
- Static readiness decodes encrypted credentials locally without OAuth refresh,
  ambient vendor-login imports, external-source execution or provider requests.
  Expired logins report `expired`; refresh-due and Google discovery-dependent
  logins remain `configured` without a fabricated resolver validation timestamp.
  Process-environment and encrypted import-env names are reported without values.
  Project/pool precedence and `external_secret_source` reasons conservatively
  suppress a ready attestation for the saved global credential. Resolver readiness
  is local usability, not upstream acceptance of an API key.
  The default projection resolves actual project/environment precedence through
  the existing runtime config resolver; default mutations still change only the
  target's global configuration.

### Changed

- Terminal onboarding, logout and provider-management writes share per-config
  serialization and compensated encrypted-secret/config persistence. Config is
  bounded, TOML-validated and atomically replaced with private permissions in the
  same directory; runtime configuration reloads when its global or project file
  changes. Explicit onboarding files outside those paths are persisted and
  verified independently, without rolling back valid credentials because an
  unrelated runtime configuration cannot reload. Failed config
  saves or reloads restore credential values, original expiry and security
  metadata through the encrypted-store owner, plus config; a failed rollback
  returns a distinct failure. This does not promise crash-atomicity across the
  encrypted store and TOML file.
- API-key writes remove stale auth-source/inline credential selectors from the
  selected provider only. Disconnect is local removal, not provider revocation;
  environment, project settings, pools, unrelated providers and Bot/profile
  overrides remain untouched. Referenced shared secrets fail closed rather than
  silently breaking another consumer, including references from the destination
  project's providers and credential pools. Default selection is a separate operation.

### Fixed

- Share canonical provider ids and runtime aliases with
  `LemonAgent.ModelRuntime.ProviderNames`, including `gemini_cli`. Preserve
  onboarding-only inputs such as `zhipu`, `kimi-k2`, `chatgpt` and `gemini-api`
  by writing canonical config ids, without adding runtime aliases that could
  claim existing custom provider endpoints, model selectors or credentials.
  Onboarding prompts, OAuth flows and presentation defaults remain local.
