# Lemon Runtime — Product Plan

This document describes the product-facing goals and delivery plan for the
**M1 runtime** milestone. It is the companion to the engineering tasks in the
milestone tracker.

## Goals

1. **First-class releases** — distribute Lemon as a self-contained binary
   release, independently of the Elixir toolchain.
2. **Unified setup command** — `mix lemon.setup` (and eventually `lemon setup`)
   orchestrates all first-run tasks: dependencies, secrets, provider onboarding,
   gateway config, and health check.
3. **Health and diagnostics** — `mix lemon.doctor` provides actionable output
   when something is wrong (missing secrets, bad config, unavailable providers).
4. **Staged updates** — `mix lemon.update` downloads and verifies a new release
   tarball, then performs a hot or cold swap depending on runtime state.

## Milestone dependency

All M1 runtime work is gated behind the `product_runtime` feature flag:

```toml
[features]
product_runtime = "off"   # change to "opt-in" to try M1 features early
```

## Delivery phases

### Phase 1 — Foundation (M0)

- [x] Ownership model and CODEOWNERS (`M0-01`)
- [x] Feature flag scaffolding (`M0-02`)
- [x] Shared schema invariants (`M0-03`)

### Phase 2 — Runtime modules (M1)

- [ ] Extract `LemonCore.Runtime.Boot`, `Profile`, `Health` from ad-hoc scripts (`M1-01`)
- [ ] Build release packaging and channel model (`M1-02`)
- [ ] `mix lemon.setup` with subcommand orchestration (`M1-03`)
- [ ] `mix lemon.doctor` diagnostics framework (`M1-04`)
- [ ] `mix lemon.update` staged update flow (`M1-05`)
- [ ] Gateway setup adapters under `mix lemon.setup gateway` (`M1-06`)
- [ ] Release smoke tests and packaging docs (`M1-07`)

## Flag progression

| State | When |
|---|---|
| `"off"` | Before M1-01 lands |
| `"opt-in"` | During M1 development — safe for testers |
| `"default-on"` | After M1-07 and smoke tests pass |
