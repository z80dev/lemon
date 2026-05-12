# Changelog

All notable changes to Lemon are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versions follow [CalVer](https://calver.org/) — `YYYY.MM.PATCH`.

---

## [Unreleased]

No unreleased changes yet.

---

## [2026.05.0]

### Added

**M8 — Documentation and release**
- Condensed root README to 5-minute orientation
- New user-guide docs: `setup`, `skills`, `memory`, `adaptive`
- Architecture overview doc (`docs/architecture/overview.md`)
- CONTRIBUTING.md, SECURITY.md, LICENSE, CHANGELOG.md
- GitHub issue/PR templates
- `product-smoke.yml` CI: packaged runtime boot, control-plane HTTP/WebSocket health, full-profile web health, release support-bundle generation, skill lint, adaptive eval gates
- `release.yml` CI: CalVer tag validation, multi-profile artifact build, manifest.json, GitHub Release publication
- `scripts/bump_version.sh`: coordinated CalVer version bump across mix.exs and client package.json files
- VitePress docs site (`docs/.vitepress/config.js`, `docs/package.json`): optional generated site from repo markdown
- `docs-site.yml` CI: docs build, markdown link checking, and GitHub Pages deployment on push to main
- Lemon 1.0 mainstream readiness ledger, launch website scaffold, install/demo/support pages, comparison page, interface proof pack, fresh-install proof, and release-artifact proof docs
- Linux `x86_64` release support policy for `lemon_runtime_min` and `lemon_runtime_full`, including rollback and downloaded-artifact verification steps
- `scripts/verify_release_artifacts`: verifies release `manifest.json` file names, sizes, and SHA-256 checksums against downloaded or assembled artifacts
- Source and clean Docker install proof on Elixir 1.19.5 / Erlang/OTP 28 with `mix deps.get`, `mix compile`, and redacted doctor bundle generation
- Web operations UI proof for `/ops`, run detail pages, support-bundle download, runtime health, sessions, approvals, cron, skills, channels, memory/log activity, and core config controls
- Telegram source-runtime proof for `/cwd`, progress rendering, prompt round trip, bare `/cancel`, approval-button resolution, and concise invalid-model failures
- TUI source-runtime proof for deterministic echo, rendered tool failure, and real-run cancellation
- Launch-focused safety coverage for web fetch output, inbound email prompts, skill prompt rendering, and extension-style untrusted tool results

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
- `mix lemon.doctor` diagnostics framework with redacted source-dev and release-runtime support bundles
- Staged `mix lemon.update`
- Gateway setup adapters (Telegram, Discord)
- Release smoke tests and packaging docs

**M0 — Foundation**
- Ownership model and CODEOWNERS
- Feature flags and rollout config scaffolding (`LemonCore.Config.Features`)
- Frozen shared schemas and invariants

### Changed

- Root README condensed from 3127 lines to 184 lines (deep content moved to `docs/`)
- CI and docs now target Elixir 1.19.5, Erlang/OTP 28.5, and Node.js 24 LTS.
- Setup docs and config examples now include an OpenAI-compatible endpoint path.
- Public docs now clearly distinguish source install, local release proof, and the still-blocked public GitHub Release artifact proof.

### Fixed

- Untrusted tool output can no longer bypass the external-content wrapper simply by including both boundary markers.
- Inbound email prompts are wrapped as external untrusted content before router submission.
- Telegram bare `/cancel` now aborts active runs even when the command is not a reply to a progress message.
- Telegram invalid model/config errors now render concise failure text instead of exposing BEAM stack traces.

---

## Release Channels

| Channel | Cadence | Stability |
|---|---|---|
| `stable` | Monthly | Fully tested |
| `preview` | Weekly | Feature-complete, light testing |
| `nightly` | Daily | Automated, may be broken |

See [`docs/release/versioning_and_channels.md`](docs/release/versioning_and_channels.md).
