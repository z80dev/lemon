# Changelog

All notable changes to Lemon are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versions follow [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Added

**M8 — Documentation and release**
- Condensed root README to 5-minute orientation
- New user-guide docs: `setup`, `skills`, `memory`, `adaptive`
- Architecture overview doc (`docs/architecture/overview.md`)
- CONTRIBUTING.md, SECURITY.md, LICENSE, CHANGELOG.md
- GitHub issue/PR templates
- `product-smoke.yml` CI: packaged runtime boot, `lemon.doctor`, skill lint, memory search, adaptive eval gates
- `release.yml` CI: CalVer tag validation, multi-profile artifact build, manifest.json, GitHub Release publication
- `scripts/bump_version.sh`: coordinated CalVer version bump across mix.exs and client package.json files
- VitePress docs site (`docs/.vitepress/config.js`, `docs/package.json`): optional generated site from repo markdown
- `docs-site.yml` CI: docs build, markdown link checking, and GitHub Pages deployment on push to main

**M7 — Adaptive routing and skill synthesis**
- Skill synthesis draft pipeline: candidate selector, draft generator, draft store, orchestration pipeline
- `mix lemon.skill draft` subcommands: `generate`, `list`, `review`, `publish`, `delete`
- Task fingerprinting for routing and synthesis (`LemonCore.TaskFingerprint`)
- Routing feedback store (`LemonCore.RoutingFeedbackStore`)
- Explicit run outcome model (`RunOutcome`: `:success`, `:partial`, `:failure`, `:aborted`)
- Offline evaluation and feedback reporting (`mix lemon.feedback`)

**M6 — Memory and feedback**
- Durable memory store and ingest pipeline (`LemonCore.MemoryStore`)
- Session search API and `search_memory` tool
- Memory management tasks and retention controls
- Memory performance and correctness guardrails

**M5 — Session memory**
- `LemonCore.SessionStore` — JSONL-backed session persistence
- `LemonCore.SessionSearch` — full-text search across past runs
- Memory management and pruning

**M4 — Skill quality**
- Skill audit engine with 5 rules (`LemonSkills.Audit.Engine`)
- Skill install policy with trust tiers
- Official registry namespace and trust policy
- `mix lemon.skill` expanded: `inspect`, `check`, `browse`, `update`

**M3 — Progressive skill loading**
- Unified skill prompt view and activation logic
- Stop inlining full skill bodies in prompts
- Upgrade `read_skill` to structured partial loads
- Prompt/token regression tests

**M2 — Skill installer and registry**
- Manifest v2 parser and validator
- Expanded `LemonSkills.Entry` with lockfile storage
- Source abstraction and source router
- Refactored installer and registry around inspect/fetch/provenance
- Legacy skill migration path

**M1 — Runtime and tooling**
- First-class OTP releases (`lemon_runtime_min`, `lemon_runtime_full`)
- `mix lemon.setup` with interactive subcommands
- `mix lemon.doctor` diagnostics framework
- Staged `mix lemon.update`
- Gateway setup adapters (Telegram, Discord)
- Release smoke tests and packaging docs

**M0 — Foundation**
- Ownership model and CODEOWNERS
- Feature flags and rollout config scaffolding (`LemonCore.Config.Features`)
- Frozen shared schemas and invariants

### Changed

- Root README condensed from 3127 lines to 184 lines (deep content moved to `docs/`)

---

## Release Channels

| Channel | Cadence | Stability |
|---|---|---|
| `stable` | Monthly | Fully tested, signed |
| `preview` | Weekly | Feature-complete, light testing |
| `nightly` | Daily | Automated, may be broken |

See [`docs/release/versioning_and_channels.md`](docs/release/versioning_and_channels.md).
