# Plan: Encrypted Secrets Store as Preferred Secret Access Path

## Metadata
- **Plan ID**: PLN-20260302-secrets-store-preferred-path
- **Status**: in_progress
- **Created**: 2026-03-02
- **Author**: janitor
- **Workspace**: feature/pln-20260302-secrets-store-preferred-path
- **Change ID**: pending
- **Roadmap Ref**: ROADMAP.md - Encrypted secrets store as preferred secret access path
- **Idea Ref**: IDEA-20260224-openclaw-env-backed-secret-refs

## Summary

Make the encrypted secrets store (`LemonCore.Secrets`) the preferred path for API key resolution across all providers, with environment variables becoming a fallback-only mechanism. This closes the implementation gap where `api_key_secret` config paths currently return `nil` and unifies secret resolution patterns across the codebase.

## Scope

### In Scope

1. **Core Secret Resolution Enhancement**
   - Extend `LemonCore.Secrets` with `resolve/2` that returns source tracking (`:store` | `:env`)
   - Add `import_from_env/2` helper to migrate env vars to encrypted store
   - Add `prefer_store/1` config option for store-first resolution

2. **Provider Config Integration**
   - Fix `LemonCore.Config.Providers.get_api_key/2` to properly resolve `api_key_secret` paths
   - Add unified secret resolution that tries store first, then env fallback
   - Update all provider configs to use `api_key_secret` instead of `api_key`

3. **Tool Auth Integration**
   - Update `tool_auth` to persist credentials as secret refs, not plaintext
   - Add secret reference format (`secret://name`) for config values
   - Implement secret ref resolution in config layer

4. **Migration Path**
   - Add `mix lemon.secrets.migrate` task to import existing env vars to store
   - Create detection for plaintext keys in config files with warnings
   - Document migration workflow

5. **Testing**
   - Unit tests for new secret resolution paths
   - Integration tests for provider config resolution
   - Migration task tests

### Out of Scope

- Removing environment variable support entirely (fallback remains)
- Automatic scrubbing of plaintext from config files (detection + warnings only)
- Changes to secret encryption algorithms
- UI changes for secret management

## Success Criteria

- [ ] `LemonCore.Secrets.resolve/2` returns `{:ok, value, source}` with source tracking
- [ ] `LemonCore.Config.Providers.get_api_key/2` resolves `api_key_secret` correctly
- [ ] All AI providers can use `api_key_secret` config key
- [ ] `tool_auth` persists credentials as secret references
- [ ] `mix lemon.secrets.migrate` task imports env vars to store
- [ ] Plaintext key detection warns users in dev/test
- [ ] All tests pass (target: 50+ new tests)

## Milestones

### M1: Core Resolution Enhancement
- Extend `LemonCore.Secrets` with source tracking
- Add `import_from_env/2` helper
- Add `prefer_store` config option
- Tests for new functionality

### M2: Provider Config Integration  
- Fix `get_api_key/2` for `api_key_secret` paths
- Update provider configs to use secret refs
- Add secret reference format (`secret://name`)
- Integration tests

### M3: Tool Auth Integration
- Update `tool_auth` to persist secret refs
- Add secret ref resolution in config layer
- Tests for auth flow

### M4: Migration Tooling
- Create `mix lemon.secrets.migrate` task
- Add plaintext key detection
- Documentation updates

### M5: Review and Landing
- Code review
- Final integration tests
- Documentation complete

## Progress Log

| Timestamp | Who | What | Result | Links |
|-----------|-----|------|--------|-------|
| 2026-03-02 02:00 | janitor | Created plan | planned | - |

## Related

- Parent: ROADMAP.md "Now" section - Encrypted secrets store
- Related: IDEA-20260224-openclaw-env-backed-secret-refs
- Related: `MarketIntel.Secrets` existing implementation
- Related: `LemonCore.Secrets` core module
