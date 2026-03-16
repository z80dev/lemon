# Lemon milestone-by-milestone issue breakdown

Proposed CODEOWNERS model (the repo snapshot has no CODEOWNERS today; `@z80` is the only explicit owner visible in `docs/catalog.exs`):

```gitignore
/mix.exs                                                     @lemon/runtime @lemon/release
/bin/**                                                      @lemon/runtime
/config/**                                                   @lemon/runtime
/apps/lemon_core/lib/lemon_core/{runtime/**,config/**,onboarding/**,doctor/**,update/**}   @lemon/runtime
/apps/lemon_core/lib/lemon_core/{store.ex,run_store.ex,run_history_store.ex,memory*,session_search*,outcome*,routing_feedback*} @lemon/memory
/apps/lemon_skills/**                                        @lemon/skills
/apps/coding_agent/**                                        @lemon/agent
/apps/agent_core/**                                          @lemon/agent
/apps/ai/**                                                  @lemon/agent
/apps/lemon_router/lib/lemon_router/model_selection.ex       @lemon/agent @lemon/memory
/clients/lemon-tui/**                                        @lemon/client
/clients/lemon-web/**                                        @lemon/client
/README.md                                                   @z80 @lemon/docs
/docs/**                                                     @z80 @lemon/docs
/.github/workflows/**                                        @lemon/release @lemon/runtime
/scripts/**                                                  @lemon/release
```

If the repo stays single-maintainer for now, collapse every alias above to `@z80`.

Critical dependency chains:

```text
Runtime/product path
M0-01 -> M0-02 -> M1-01 -> M1-02 -> M1-03 -> M1-07 -> M8-03

Skills/progressive-loading path
M0-03 -> M2-01 -> M2-02 -> M2-03 -> M2-04 -> M3-01 -> M3-02 -> M3-03 -> M4-01 -> M4-02 -> M4-03 -> M4-04

Memory/learning path
M0-02 -> M0-03 -> M5-01 -> M5-02 -> M6-01 -> M6-02 -> M6-03 -> M7-01

Procedural learning path
M2-01 -> M3-03 -> M4-02 -> M5-01 -> M6-01 -> M7-02 -> M7-03
```

## M0
### M0-01 — Add ownership model and CODEOWNERS [M]
**Primary owner:** @lemon/release
**Required reviewers:** @z80, @lemon/runtime
**Depends on:** None
**Blocks:** M0-02, M0-03, M8-02, M8-03

**Files to modify**
- `docs/catalog.exs`

**Files to add**
- `.github/CODEOWNERS`
- `docs/contributor/ownership.md`

**Work items**
1. Create CODEOWNERS with exact ownership lanes for runtime, skills, agent, memory, docs, release, and client surfaces.
2. Document directory-to-owner mapping, escalation rules, and required reviewer matrix for cross-cutting changes.
3. Keep docs freshness owner as `@z80` in `docs/catalog.exs` until a broader docs ownership process exists.
4. Define a policy that new files inherit the owner of their nearest directory unless explicitly overridden.

**Definition of done**
- Every directory touched by this initiative has an explicit owner.
- Cross-cutting files (`mix.exs`, `.github/workflows/**`, `README.md`) have explicit multi-owner review rules.
- There is a written rule for ownership of future files.

### M0-02 — Add feature flags and rollout config scaffolding [L]
**Primary owner:** @lemon/runtime
**Required reviewers:** @lemon/skills, @lemon/memory, @z80
**Depends on:** M0-01
**Blocks:** M1-03, M1-04, M5-01, M6-01, M7-01, M7-02, M8-01

**Files to modify**
- `apps/lemon_core/lib/lemon_core/config/modular.ex`
- `apps/lemon_core/lib/lemon_core/config.ex`
- `docs/config.md`
- `examples/config.example.toml`

**Files to add**
- `docs/product/runtime_plan.md`
- `docs/skills_v2.md`
- `docs/memory/session_search_and_feedback.md`
- `docs/release/versioning_and_channels.md`
- `docs/contributor/public_repo_basics.md`

**Work items**
1. Add feature toggles for `product_runtime`, `skills_hub_v2`, `skill_manifest_v2`, `progressive_skill_loading_v2`, `session_search`, `routing_feedback`, and `skill_synthesis_drafts`.
2. Document default values, rollout states (`read-only`, `opt-in`, `default-on`), and kill-switch behavior.
3. Extend modular config parsing so the new feature block is typed, validated, and surfaced through the existing config facade.
4. Update config docs and example TOML with the new feature section.

**Definition of done**
- All later behavior changes can be gated behind config without ad hoc env vars.
- Config validation fails cleanly on malformed feature settings.
- Every new feature flag is documented in `docs/config.md` and `examples/config.example.toml`.

### M0-03 — Freeze shared schemas and invariants [M]
**Primary owner:** @lemon/runtime
**Required reviewers:** @lemon/skills, @lemon/memory, @lemon/agent, @z80
**Depends on:** M0-01
**Blocks:** M1-01, M2-01, M5-01

**Files to modify**
- `docs/architecture_boundaries.md`
- `docs/assistant_bootstrap_contract.md`
- `docs/context.md`

**Files to add**
- _(none)_

**Work items**
1. Write down the exact execution modes: `source_dev`, `release_runtime`, and `attached_client`.
2. Freeze memory scopes: `session`, `workspace`, `agent`, and `global`.
3. Freeze skill source taxonomy: `builtin`, `local`, `git`, `registry`, `well_known`, plus trust levels `builtin`, `official`, `trusted`, `community`.
4. Record architecture placement rules so new stores remain in `lemon_core`, skill platform logic remains in `lemon_skills`, and prompt/tool changes stay in `coding_agent` / `lemon_router`.

**Definition of done**
- The major nouns used by later milestones are documented and not left implicit.
- The architecture boundaries doc covers the new module placements.
- Downstream issues can point to a single source of truth for invariants.


## M1
### M1-01 — Extract runtime boot/profile/health modules from scripts [L]
**Primary owner:** @lemon/runtime
**Required reviewers:** @lemon/release
**Depends on:** M0-03
**Blocks:** M1-02, M1-03, M1-04, M1-06

**Files to modify**
- `bin/lemon`
- `bin/lemon-dev`
- `config/runtime.exs`
- `apps/lemon_core/lib/lemon_core/application.ex`

**Files to add**
- `apps/lemon_core/lib/lemon_core/runtime/boot.ex`
- `apps/lemon_core/lib/lemon_core/runtime/profile.ex`
- `apps/lemon_core/lib/lemon_core/runtime/health.ex`
- `apps/lemon_core/lib/lemon_core/runtime/env.ex`
- `apps/lemon_core/test/lemon_core/runtime/boot_test.exs`
- `apps/lemon_core/test/lemon_core/runtime/profile_test.exs`

**Work items**
1. Move startup decisions out of shell scripts into `LemonCore.Runtime.*` modules.
2. Define runtime profiles (`runtime_min`, `runtime_full`) as data so both source mode and release mode use the same boot contract.
3. Centralize path normalization, port defaults, health/readiness checks, and ‘already running’ detection.
4. Keep `bin/lemon` and `bin/lemon-dev` as thin wrappers that call the new modules.

**Definition of done**
- Source-mode startup and future release-mode startup share the same Elixir boot logic.
- The runtime profile list is test-covered and not duplicated across scripts.
- Shell wrappers no longer contain product logic that can drift.

### M1-02 — Add first-class Lemon runtime releases [M]
**Primary owner:** @lemon/runtime
**Required reviewers:** @lemon/release
**Depends on:** M1-01
**Blocks:** M1-05, M1-07, M8-03

**Files to modify**
- `mix.exs`
- `README.md`

**Files to add**
- `apps/lemon_core/test/lemon_core/runtime/release_profile_test.exs`

**Work items**
1. Extend root `mix.exs` releases beyond `games_platform` to include `lemon_runtime_min` and `lemon_runtime_full`.
2. Map profile-to-application sets explicitly so release contents are deterministic.
3. Decide that backend runtime releases ship first and the TUI remains attachable rather than blocking packaging on Node bundling.
4. Document the release profiles in the README and runtime plan docs.

**Definition of done**
- `mix release lemon_runtime_min` and `mix release lemon_runtime_full` are buildable from CI.
- Release definitions match the runtime profile module rather than duplicating app lists in multiple places.
- The root README exposes runtime release artifacts as a first-class install path.

### M1-03 — Add `mix lemon.setup` and subcommand orchestration [L]
**Primary owner:** @lemon/runtime
**Required reviewers:** @lemon/release, @z80
**Depends on:** M0-02, M1-01
**Blocks:** M1-05, M1-06, M1-07, M8-01

**Files to modify**
- `apps/lemon_core/lib/lemon_core/onboarding/runner.ex`
- `apps/lemon_core/lib/lemon_core/config/modular.ex`
- `examples/config.example.toml`
- `docs/config.md`
- `README.md`

**Files to add**
- `apps/lemon_core/lib/mix/tasks/lemon.setup.ex`
- `apps/lemon_core/lib/lemon_core/setup/wizard.ex`
- `apps/lemon_core/lib/lemon_core/setup/scaffold.ex`
- `apps/lemon_core/lib/lemon_core/setup/provider.ex`
- `apps/lemon_core/test/mix/tasks/lemon.setup_test.exs`

**Work items**
1. Wrap existing onboarding, secrets bootstrap, and config scaffolding inside a single `mix lemon.setup` entrypoint.
2. Support subcommands like `provider`, `runtime`, `gateway <name>`, and `doctor` without creating separate top-level task namespaces.
3. Implement both interactive and non-interactive modes with deterministic CI behavior.
4. Generate a minimal config scaffold from canonical config structs rather than copying a stale static file.

**Definition of done**
- A fresh machine can initialize Lemon without manually editing TOML.
- Non-interactive setup fails fast when required flags are missing instead of prompting unexpectedly.
- The task reuses existing onboarding logic rather than forking provider-specific flows.

### M1-04 — Add `mix lemon.doctor` diagnostics framework [L]
**Primary owner:** @lemon/runtime
**Required reviewers:** @lemon/skills, @lemon/release, @z80
**Depends on:** M0-02, M1-01
**Blocks:** M1-07, M8-01

**Files to modify**
- `apps/lemon_core/lib/lemon_core/config/modular.ex`
- `apps/lemon_core/lib/lemon_core/secrets.ex`
- `README.md`
- `docs/config.md`

**Files to add**
- `apps/lemon_core/lib/lemon_core/doctor/check.ex`
- `apps/lemon_core/lib/lemon_core/doctor/report.ex`
- `apps/lemon_core/lib/lemon_core/doctor/checks/config.ex`
- `apps/lemon_core/lib/lemon_core/doctor/checks/secrets.ex`
- `apps/lemon_core/lib/lemon_core/doctor/checks/runtime.ex`
- `apps/lemon_core/lib/lemon_core/doctor/checks/providers.ex`
- `apps/lemon_core/lib/lemon_core/doctor/checks/node_tools.ex`
- `apps/lemon_core/lib/lemon_core/doctor/checks/skills.ex`
- `apps/lemon_core/lib/mix/tasks/lemon.doctor.ex`
- `apps/lemon_core/test/mix/tasks/lemon.doctor_test.exs`

**Work items**
1. Implement a structured check model with `pass`, `warn`, and `fail` results plus remediation text.
2. Cover config validation, encrypted secrets readiness, runtime health, local directories, required binaries, optional provider live checks, and skill integrity.
3. Add `--verbose` and `--json` output modes.
4. Make doctor the canonical support/debug command referenced by docs and release smoke tests.

**Definition of done**
- `mix lemon.doctor` gives actionable output on an unconfigured machine and on a healthy install.
- `--json` produces machine-readable output suitable for CI smoke checks.
- No secrets are dumped in plain text in normal output.

### M1-05 — Add staged `mix lemon.update` [M]
**Primary owner:** @lemon/runtime
**Required reviewers:** @lemon/skills, @lemon/release
**Depends on:** M1-02, M1-03
**Blocks:** M2-05, M8-03

**Files to modify**
- `README.md`
- `docs/config.md`

**Files to add**
- `apps/lemon_core/lib/mix/tasks/lemon.update.ex`
- `apps/lemon_core/lib/lemon_core/update/check.ex`
- `apps/lemon_core/lib/lemon_core/update/migrate.ex`
- `apps/lemon_core/lib/lemon_core/update/skills_sync.ex`
- `apps/lemon_core/test/mix/tasks/lemon.update_test.exs`

**Work items**
1. Ship stage-1 update behavior: version check, config migration, and bundled-skill sync.
2. Keep source checkouts immutable by default; only packaged release installs get real self-update later.
3. Integrate update with upcoming skill lockfile migrations rather than adding another migration path.
4. Expose `--check` and `--migrate-config` paths that are safe in CI.

**Definition of done**
- `mix lemon.update --check` reports version/update state without mutating a source checkout.
- Config migrations are versioned and test-covered.
- Bundled skill sync can be invoked from update without bespoke scripts.

### M1-06 — Add gateway setup adapters under `mix lemon.setup gateway ...` [M]
**Primary owner:** @lemon/runtime
**Required reviewers:** @lemon/release
**Depends on:** M1-03, M1-01
**Blocks:** M8-01

**Files to modify**
- `bin/lemon-telegram-send-test`
- `bin/lemon-telegram-webhook`
- `scripts/setup_telegram_bot.py`
- `apps/lemon_gateway/README.md`
- `docs/config.md`

**Files to add**
- `apps/lemon_core/lib/lemon_core/setup/gateway.ex`
- `apps/lemon_core/lib/lemon_core/setup/gateways/telegram.ex`
- `apps/lemon_gateway/test/lemon_gateway/setup/telegram_test.exs`

**Work items**
1. Wrap transport-specific bootstrap in the shared setup flow rather than leaving it as ad hoc scripts.
2. For Telegram first, validate required secrets, config sections, webhook/polling prerequisites, and connectivity smoke behavior.
3. Keep transport continuity semantics out of scope; this is only configuration and health setup.
4. Make the gateway adapter architecture reusable for other transports later.

**Definition of done**
- `mix lemon.setup gateway telegram` configures or validates the Telegram surface without manual spelunking.
- Gateway-specific setup reuses the common setup/reporting framework.
- No cross-channel session semantics are introduced.

### M1-07 — Add release smoke tests and runtime packaging docs [M]
**Primary owner:** @lemon/release
**Required reviewers:** @lemon/runtime, @z80
**Depends on:** M1-02, M1-03, M1-04
**Blocks:** M8-03

**Files to modify**
- `.github/workflows/quality.yml`
- `README.md`
- `docs/product/runtime_plan.md`

**Files to add**
- `.github/workflows/runtime-release.yml`
- `scripts/smoke_runtime_release.sh`

**Work items**
1. Add CI that assembles runtime releases, launches them in a fixture environment, runs `mix lemon.doctor --json` or equivalent health checks, and tears them down.
2. Document the difference between source-dev, release-runtime, and attached-client flows.
3. Add failure artifacts or logs to make packaged-runtime regressions diagnosable.
4. Keep games platform CI independent from generic runtime release CI.

**Definition of done**
- A runtime release build breaks CI when packaging or boot health regresses.
- Docs describe how to install and verify a packaged runtime.
- Packaging smoke tests do not rely on a developer shell environment.


## M2
### M2-01 — Replace skill frontmatter parsing with manifest v2 parser/validator [L]
**Primary owner:** @lemon/skills
**Required reviewers:** @lemon/agent, @z80
**Depends on:** M0-03
**Blocks:** M2-02, M2-03, M3-01

**Files to modify**
- `apps/lemon_skills/lib/lemon_skills/manifest.ex`
- `docs/skills.md`

**Files to add**
- `apps/lemon_skills/lib/lemon_skills/manifest/parser.ex`
- `apps/lemon_skills/lib/lemon_skills/manifest/validator.ex`
- `apps/lemon_skills/test/lemon_skills/manifest_test.exs`
- `docs/skills_v2.md`
- `docs/reference/skill-manifest-v2.md`

**Work items**
1. Replace the hand-rolled parser with a schema-friendly parser/validator that supports nested metadata cleanly.
2. Define manifest v2 fields: `platforms`, `metadata.lemon.category`, `requires_tools`, `fallback_for_tools`, `required_environment_variables`, `verification`, and `references`.
3. Keep legacy skills valid by assigning defaults when v2-only fields are absent.
4. Document the exact schema and migration rules.

**Definition of done**
- Manifest parsing/validation can represent nested metadata without brittle string parsing.
- Legacy built-ins still parse.
- There is a single validator that later CLI and install flows can call.

### M2-02 — Expand `LemonSkills.Entry` and add lockfile storage [L]
**Primary owner:** @lemon/skills
**Required reviewers:** @lemon/runtime
**Depends on:** M2-01
**Blocks:** M2-04, M3-01, M4-01, M4-03

**Files to modify**
- `apps/lemon_skills/lib/lemon_skills/entry.ex`
- `apps/lemon_skills/lib/lemon_skills/registry.ex`
- `apps/lemon_skills/lib/lemon_skills/builtin_seeder.ex`

**Files to add**
- `apps/lemon_skills/lib/lemon_skills/lockfile.ex`
- `apps/lemon_skills/test/lemon_skills/lockfile_test.exs`
- `apps/lemon_skills/test/lemon_skills/entry_test.exs`

**Work items**
1. Extend skill entries with source kind, source id, identifier, trust level, content hash, upstream hash, install timestamps, and audit status.
2. Add a lockfile for global and project installs that records exact provenance and last known upstream state.
3. Teach the registry/builtin seeder to hydrate entries from lockfile state when present.
4. Keep old entry fields usable so existing call sites do not break immediately.

**Definition of done**
- Every installed non-local skill can be represented reproducibly.
- Lockfile reads/writes are covered by tests.
- Registry call sites do not lose backwards compatibility while the richer entry model lands.

### M2-03 — Introduce source abstraction and source router [L]
**Primary owner:** @lemon/skills
**Required reviewers:** @lemon/runtime
**Depends on:** M2-01
**Blocks:** M2-04, M4-02, M4-03

**Files to modify**
- `apps/lemon_skills/lib/lemon_skills/discovery.ex`
- `apps/lemon_skills/lib/lemon_skills/http_client.ex`
- `apps/lemon_skills/lib/lemon_skills/mcp_source.ex`

**Files to add**
- `apps/lemon_skills/lib/lemon_skills/source.ex`
- `apps/lemon_skills/lib/lemon_skills/source_router.ex`
- `apps/lemon_skills/lib/lemon_skills/sources/builtin.ex`
- `apps/lemon_skills/lib/lemon_skills/sources/local.ex`
- `apps/lemon_skills/lib/lemon_skills/sources/git.ex`
- `apps/lemon_skills/lib/lemon_skills/sources/registry.ex`
- `apps/lemon_skills/lib/lemon_skills/sources/github.ex`
- `apps/lemon_skills/test/lemon_skills/source_router_test.exs`

**Work items**
1. Define a source behavior with `search`, `inspect`, `fetch`, `upstream_hash`, and `trust_level` operations.
2. Create explicit source modules for builtin, local, git, registry, and GitHub-like discovery sources.
3. Route user-facing identifiers like `official/devops/k8s-rollout` into a source module plus stable identifier tuple.
4. Separate source resolution from installer business logic.

**Definition of done**
- Skill installation/search can target more than raw paths and git URLs.
- Source resolution is test-covered and extensible.
- No installer code path has to manually parse every source form itself.

### M2-04 — Refactor installer and registry around inspect/fetch/provenance [L]
**Primary owner:** @lemon/skills
**Required reviewers:** @lemon/agent, @lemon/runtime
**Depends on:** M2-02, M2-03
**Blocks:** M2-05, M3-03, M4-01, M4-02

**Files to modify**
- `apps/lemon_skills/lib/lemon_skills/installer.ex`
- `apps/lemon_skills/lib/lemon_skills/registry.ex`
- `apps/lemon_skills/lib/lemon_skills/config.ex`
- `apps/lemon_skills/test/mix/tasks/lemon.skill_test.exs`

**Files to add**
- `apps/lemon_skills/lib/lemon_skills/install_plan.ex`
- `apps/lemon_skills/test/lemon_skills/installer_test.exs`

**Work items**
1. Change installation flow to `resolve -> inspect -> fetch -> audit placeholder -> install -> lockfile write -> register`.
2. Refactor update flow around upstream hash comparison and local-modification detection.
3. Ensure project/global install scope is explicit in both installer and lockfile.
4. Keep registry refresh/search working while shifting the internal source of truth toward lockfile-backed entries.

**Definition of done**
- Installer understands registry refs and richer provenance.
- Update flow can detect drift instead of blindly reinstalling.
- Registry state after install/update is derived from the same provenance model used by CLI and agent tooling.

### M2-05 — Add legacy skill migration path [M]
**Primary owner:** @lemon/skills
**Required reviewers:** @lemon/runtime
**Depends on:** M1-05, M2-04
**Blocks:** M4-01, M4-03

**Files to modify**
- `apps/lemon_skills/lib/lemon_skills/application.ex`
- `apps/lemon_skills/lib/lemon_skills/builtin_seeder.ex`
- `apps/lemon_skills/lib/mix/tasks/lemon.skill.ex`

**Files to add**
- `apps/lemon_skills/lib/lemon_skills/migration.ex`
- `apps/lemon_skills/test/lemon_skills/migration_test.exs`

**Work items**
1. Classify existing installs into builtin, local, and legacy-git buckets without breaking them.
2. Auto-seed lockfile entries for bundled built-ins.
3. Mark older git installs as legacy when upstream provenance is incomplete and require reinstall for full update tracking.
4. Hook migration into `mix lemon.update` and first boot of the upgraded skills app.

**Definition of done**
- Existing skill users are not stranded after the provenance model lands.
- Built-ins are registered with explicit source kind/trust level.
- Legacy git installs degrade gracefully with clear guidance.


## M3
### M3-01 — Create unified skill prompt view and activation logic [M]
**Primary owner:** @lemon/agent
**Required reviewers:** @lemon/skills
**Depends on:** M2-01, M2-02
**Blocks:** M3-02, M3-03

**Files to modify**
- `apps/lemon_skills/lib/lemon_skills/status.ex`

**Files to add**
- `apps/lemon_skills/lib/lemon_skills/prompt_view.ex`
- `apps/lemon_skills/lib/lemon_skills/activation.ex`
- `apps/lemon_skills/test/lemon_skills/prompt_view_test.exs`
- `apps/lemon_skills/test/lemon_skills/activation_test.exs`

**Work items**
1. Define a single metadata summary shape for prompts and CLI surfaces.
2. Extend status checking to report platform incompatibility, missing env vars, missing required tools, and hidden-vs-not-ready distinctions.
3. Implement activation rules so incompatible skills can be hidden while fixable setup gaps remain visible.
4. Keep the logic in `lemon_skills`, not duplicated inside `coding_agent`.

**Definition of done**
- There is one canonical summary contract for skills.
- Prompt assembly and `read_skill` can ask the same module for status/visibility information.
- Status reporting distinguishes unavailable, hidden, and not-ready states cleanly.

### M3-02 — Stop inlining full skill bodies in prompts [M]
**Primary owner:** @lemon/agent
**Required reviewers:** @lemon/skills
**Depends on:** M3-01
**Blocks:** M3-04, M8-01

**Files to modify**
- `apps/coding_agent/lib/coding_agent/prompt_builder.ex`
- `apps/coding_agent/lib/coding_agent/system_prompt.ex`
- `apps/coding_agent/lib/coding_agent/session/prompt_composer.ex`

**Files to add**
- `apps/coding_agent/test/coding_agent/prompt_builder_skills_test.exs`
- `apps/coding_agent/test/coding_agent/system_prompt_skills_test.exs`

**Work items**
1. Switch `PromptBuilder.build_skills_section/3` from embedding full skill bodies to embedding skill summaries only.
2. Make `SystemPrompt` and `PromptBuilder` consume the same `PromptView` output fields.
3. Preserve the instruction that agents should load a skill lazily via `read_skill` when exactly one skill is clearly relevant.
4. Add a guardrail test that fails if full skill markdown is injected in normal prompt assembly.

**Definition of done**
- No normal prompt path injects full `SKILL.md` bodies by default.
- Both prompt builders expose the same skill metadata surface.
- Prompt assembly becomes smaller and more stable.

### M3-03 — Upgrade `read_skill` to structured partial loads [M]
**Primary owner:** @lemon/skills
**Required reviewers:** @lemon/agent
**Depends on:** M3-01, M2-04
**Blocks:** M3-04, M4-01, M7-02

**Files to modify**
- `apps/lemon_skills/lib/lemon_skills/tools/read_skill.ex`
- `apps/coding_agent/lib/coding_agent/tool_registry.ex`

**Files to add**
- `apps/lemon_skills/test/lemon_skills/tools/read_skill_test.exs`

**Work items**
1. Expand tool parameters to support `view: summary|full|section|file`, `section`, `path`, `include_manifest`, and `max_chars`.
2. Support loading referenced skill files in addition to the root `SKILL.md`.
3. Return structured status/manifests when requested without always returning the full body.
4. Keep the result shape friendly to downstream agent reasoning.

**Definition of done**
- Agents can fetch only the part of a skill they need.
- Large skill bundles do not have to be fully injected to use reference material.
- `read_skill` remains backwards compatible for the simple `key` case.

### M3-04 — Add prompt/token regression tests for progressive disclosure [M]
**Primary owner:** @lemon/agent
**Required reviewers:** @lemon/skills, @lemon/release
**Depends on:** M3-02, M3-03
**Blocks:** M8-03

**Files to modify**
- `.github/workflows/quality.yml`

**Files to add**
- `apps/coding_agent/test/coding_agent/prompt_token_regression_test.exs`
- `apps/coding_agent/test/coding_agent/read_skill_progressive_loading_test.exs`

**Work items**
1. Add tests that compare prompt size before/after the progressive loading contract.
2. Assert that only summaries are present in bootstrap prompts and that `read_skill` can recover the full content or sections on demand.
3. Wire one regression test into CI so prompt bloat does not silently return.
4. Capture a few representative prompt snapshots for debugging.

**Definition of done**
- Prompt bloat regressions fail tests.
- The progressive-loading behavior is measured rather than aspirational.
- CI protects the new contract.


## M4
### M4-01 — Expand `mix lemon.skill` with inspect/check/browse/update flow [L]
**Primary owner:** @lemon/skills
**Required reviewers:** @lemon/agent, @z80
**Depends on:** M2-04, M2-05, M3-03
**Blocks:** M4-03, M4-04, M8-01

**Files to modify**
- `apps/lemon_skills/lib/mix/tasks/lemon.skill.ex`
- `docs/skills.md`
- `README.md`

**Files to add**
- `apps/lemon_skills/test/mix/tasks/lemon.skill_cli_test.exs`

**Work items**
1. Add user-facing commands/subcommands for `browse`, `inspect`, `check`, and richer `update` behavior while preserving old command names as aliases where possible.
2. Surface provenance, trust level, required env vars, reference files, and readiness information in inspect output.
3. Make `check` compare lockfile state to upstream hash where available.
4. Keep local/offline installs usable even when upstream check is unavailable.

**Definition of done**
- Users can inspect a skill before installing it.
- Skill check/update behavior is explainable through CLI output rather than implicit registry magic.
- Existing `mix lemon.skill` usage does not hard-break.

### M4-02 — Add skill audit engine and install policy [L]
**Primary owner:** @lemon/skills
**Required reviewers:** @lemon/runtime, @lemon/agent
**Depends on:** M2-03, M2-04
**Blocks:** M4-03, M4-04, M7-02

**Files to modify**
- `apps/lemon_skills/lib/lemon_skills/installer.ex`
- `apps/lemon_skills/lib/mix/tasks/lemon.skill.ex`

**Files to add**
- `apps/lemon_skills/lib/lemon_skills/audit.ex`
- `apps/lemon_skills/lib/lemon_skills/audit/rules/destructive_commands.ex`
- `apps/lemon_skills/lib/lemon_skills/audit/rules/exfiltration.ex`
- `apps/lemon_skills/lib/lemon_skills/audit/rules/remote_exec.ex`
- `apps/lemon_skills/lib/lemon_skills/audit/rules/bundle_layout.ex`
- `apps/lemon_skills/test/lemon_skills/audit_test.exs`

**Work items**
1. Implement audit verdicts `pass`, `warn`, and `block` over fetched skill bundles before install/update.
2. Add initial rules for destructive commands without confirmation, suspicious remote execution, exfiltration patterns, path traversal, and bundled binaries/symlink escapes.
3. Enforce that `block` is not overrideable, while `warn` requires explicit approval.
4. Store last audit verdict/findings in the lockfile.

**Definition of done**
- Install/update always runs audit before mutating skill directories.
- Audit findings are visible to users and recorded in lockfile state.
- A blocked bundle cannot be force-installed.

### M4-03 — Add official registry namespace and trust policy [L]
**Primary owner:** @lemon/skills
**Required reviewers:** @lemon/runtime, @z80
**Depends on:** M2-02, M2-03, M2-05, M4-01, M4-02
**Blocks:** M4-04, M8-01

**Files to modify**
- `apps/lemon_skills/lib/lemon_skills/config.ex`
- `apps/lemon_skills/lib/lemon_skills/source_router.ex`
- `apps/lemon_skills/lib/lemon_skills/lockfile.ex`
- `docs/skills.md`

**Files to add**
- `apps/lemon_skills/lib/lemon_skills/trust_policy.ex`
- `apps/lemon_skills/test/lemon_skills/trust_policy_test.exs`

**Work items**
1. Define `builtin`, `official`, `trusted`, and `community` trust semantics and show them in CLI/lockfile state.
2. Support stable registry identifiers like `official/devops/k8s-rollout`.
3. Keep bundled built-ins distinct from curated official skills so the repo does not become the only distribution channel.
4. Codify install/update rules that vary by trust level without bypassing audit.

**Definition of done**
- Official registry refs are installable.
- Trust level is explicit and visible.
- Built-ins and official skills are separate operational categories.

### M4-04 — Add skill quality gates to CI [M]
**Primary owner:** @lemon/release
**Required reviewers:** @lemon/skills, @z80
**Depends on:** M4-01, M4-02, M4-03
**Blocks:** M8-03

**Files to modify**
- `.github/workflows/quality.yml`
- `apps/lemon_core/lib/mix/tasks/lemon.quality.ex`
- `docs/skills_v2.md`

**Files to add**
- `apps/lemon_skills/lib/mix/tasks/lemon.skill.lint.ex`
- `apps/lemon_skills/test/mix/tasks/lemon.skill_lint_test.exs`

**Work items**
1. Add a lint task that validates manifest v2, reference paths, required sections for official skills, and audit cleanliness for bundled/official content.
2. Integrate the lint/audit flow into CI without making community skill install behavior a compile-time dependency of test runs.
3. Document the skill quality gate so contributors know what is required for official content.
4. Use deterministic fixture skills in tests rather than hitting the network.

**Definition of done**
- Official and bundled skills are quality-checked in CI.
- Skill docs explain the contributor contract for curated content.
- The quality workflow fails fast on malformed manifests or blocked audit findings.


## M5
### M5-01 — Add durable memory store and ingest pipeline [L]
**Primary owner:** @lemon/memory
**Required reviewers:** @lemon/runtime
**Depends on:** M0-02, M0-03
**Blocks:** M5-02, M5-03, M6-01, M7-02

**Files to modify**
- `apps/lemon_core/lib/lemon_core/store.ex`
- `apps/lemon_core/lib/lemon_core/application.ex`
- `docs/context.md`

**Files to add**
- `apps/lemon_core/lib/lemon_core/memory_store.ex`
- `apps/lemon_core/lib/lemon_core/memory_document.ex`
- `apps/lemon_core/lib/lemon_core/memory_ingest.ex`
- `apps/lemon_core/test/lemon_core/memory_ingest_test.exs`

**Work items**
1. Create a separate durable memory database from `run_history.sqlite3` to avoid overloading operational history with retrieval concerns.
2. Ingest finalized runs asynchronously into normalized memory documents.
3. Store at least run summary, session/workspace/agent scope, tools used, provider/model, and coarse outcome label placeholder.
4. Make ingest failure non-fatal to the main run path.

**Definition of done**
- Run finalization still succeeds even if memory ingest fails.
- Operational history and durable memory are physically separate stores.
- Memory documents are queryable by scope and date.

### M5-02 — Add `SessionSearch` API and `search_memory` tool [L]
**Primary owner:** @lemon/memory
**Required reviewers:** @lemon/agent
**Depends on:** M5-01
**Blocks:** M6-03, M8-01

**Files to modify**
- `apps/coding_agent/lib/coding_agent/tool_registry.ex`
- `apps/coding_agent/lib/coding_agent/tools.ex`
- `apps/coding_agent/lib/coding_agent/system_prompt.ex`

**Files to add**
- `apps/lemon_core/lib/lemon_core/session_search.ex`
- `apps/coding_agent/lib/coding_agent/tools/search_memory.ex`
- `apps/lemon_core/test/lemon_core/session_search_test.exs`
- `apps/coding_agent/test/coding_agent/tools/search_memory_test.exs`

**Work items**
1. Implement FTS-first retrieval over run summaries and related metadata.
2. Expose retrieval through a dedicated agent tool with explicit scope controls.
3. Update the main-session memory guidance in the system prompt to use the new tool when appropriate, while leaving subagents conservative by default.
4. Design the API so embeddings can be added later without changing callers.

**Definition of done**
- Agents can search past runs by session/workspace/agent/global scope.
- The search surface is a dedicated tool, not a side effect of file reads.
- The retrieval backend is abstract enough to support hybrid ranking later.

### M5-03 — Add memory management tasks and retention controls [M]
**Primary owner:** @lemon/memory
**Required reviewers:** @lemon/runtime, @z80
**Depends on:** M5-01
**Blocks:** M8-01

**Files to modify**
- `apps/lemon_core/lib/lemon_core/config/modular.ex`
- `docs/memory/session_search_and_feedback.md`
- `docs/config.md`

**Files to add**
- `apps/lemon_core/lib/mix/tasks/lemon.memory.stats.ex`
- `apps/lemon_core/lib/mix/tasks/lemon.memory.prune.ex`
- `apps/lemon_core/lib/mix/tasks/lemon.memory.erase.ex`
- `apps/lemon_core/test/mix/tasks/lemon.memory_tasks_test.exs`

**Work items**
1. Add config for memory retention days and max-documents-per-scope.
2. Expose stats/prune/erase tasks so memory remains user-operable and debuggable.
3. Implement erasure by scope without corrupting raw run history or lockfile state.
4. Document the difference between durable memory and ephemeral run history.

**Definition of done**
- Users/operators can inspect, prune, and erase durable memory intentionally.
- Memory retention is configurable and documented.
- Erasure flows are test-covered.

### M5-04 — Add memory performance and correctness guardrails [M]
**Primary owner:** @lemon/memory
**Required reviewers:** @lemon/release
**Depends on:** M5-01, M5-02
**Blocks:** M8-03

**Files to modify**
- `.github/workflows/quality.yml`
- `docs/telemetry.md`

**Files to add**
- `apps/lemon_core/test/lemon_core/memory_store_perf_test.exs`

**Work items**
1. Add benchmark-ish regression tests for FTS query latency on fixture datasets.
2. Log or measure ingest queue failures/latency so memory does not become a silent bottleneck.
3. Add a small CI guardrail around correctness and reasonable performance, not absolute throughput.
4. Document operational visibility in telemetry docs.

**Definition of done**
- Memory search/ingest has baseline regression protection.
- Telemetry docs include the new memory signals.
- CI can catch obvious performance cliffs.


## M6
### M6-01 — Add explicit run outcome model and capture [M]
**Primary owner:** @lemon/memory
**Required reviewers:** @lemon/runtime, @lemon/agent
**Depends on:** M5-01, M0-02
**Blocks:** M6-02, M7-02

**Files to modify**
- `apps/lemon_core/lib/lemon_core/store.ex`
- `apps/lemon_core/lib/lemon_core/run_store.ex`
- `docs/memory/session_search_and_feedback.md`

**Files to add**
- `apps/lemon_core/lib/lemon_core/outcome.ex`
- `apps/lemon_core/test/lemon_core/outcome_test.exs`

**Work items**
1. Introduce `:success | :partial | :failure | :aborted | :unknown` outcome labels.
2. Attach outcome capture to run finalization and memory ingest paths without breaking existing summary shapes.
3. Define the heuristics and explicit overrides that can set outcome labels.
4. Leave routing behavior unchanged at this stage; this is data capture only.

**Definition of done**
- Runs have outcome labels in stored feedback/memory records.
- Outcome capture can represent uncertainty rather than guessing success all the time.
- No routing policy changes are shipped yet.

### M6-02 — Add task fingerprinting and routing feedback store [L]
**Primary owner:** @lemon/memory
**Required reviewers:** @lemon/agent, @lemon/runtime
**Depends on:** M6-01
**Blocks:** M6-03, M7-01

**Files to modify**
- `apps/lemon_core/lib/lemon_core/application.ex`

**Files to add**
- `apps/lemon_core/lib/lemon_core/routing_feedback.ex`
- `apps/lemon_core/lib/lemon_core/routing_feedback/store.ex`
- `apps/lemon_core/lib/lemon_core/routing_feedback/fingerprint.ex`
- `apps/lemon_core/test/lemon_core/routing_feedback_test.exs`

**Work items**
1. Create coarse task fingerprints using task family, toolset, workspace key, and model/provider choices.
2. Aggregate outcome rates, durations, and sample sizes by fingerprint and candidate model/provider pair.
3. Keep the data model read-only at first so it can power reports without influencing routing.
4. Make sample-size thresholds explicit in the store/query API.

**Definition of done**
- Historical success/failure statistics are queryable by task fingerprint.
- The store distinguishes insufficient data from bad performance.
- No live routing path consumes the feedback yet.

### M6-03 — Expose feedback reporting and offline evaluation [M]
**Primary owner:** @lemon/memory
**Required reviewers:** @lemon/agent, @lemon/release, @z80
**Depends on:** M5-02, M6-02
**Blocks:** M7-01, M7-03, M8-01

**Files to modify**
- `apps/coding_agent/lib/mix/tasks/lemon.eval.ex`
- `docs/agent-loop/README.md`
- `docs/agent-loop/GOALS.md`
- `docs/telemetry.md`

**Files to add**
- `apps/lemon_core/lib/mix/tasks/lemon.feedback.report.ex`
- `apps/lemon_core/test/mix/tasks/lemon.feedback.report_test.exs`

**Work items**
1. Add CLI/reporting surfaces for historical routing stats by workspace and task family.
2. Extend eval harness docs/tasks so routing feedback can be inspected offline before it influences live decisions.
3. Document how to judge minimum sample size, recency, and confidence for routing data.
4. Keep evaluation separate from online routing logic.

**Definition of done**
- Operators can inspect feedback without enabling any adaptive behavior.
- The eval harness has a clear place for feedback-based comparisons.
- Docs describe the offline-first rollout model.


## M7
### M7-01 — Integrate history-aware routing tie-breakers behind a flag [L]
**Primary owner:** @lemon/agent
**Required reviewers:** @lemon/memory, @lemon/runtime
**Depends on:** M6-03, M0-02
**Blocks:** M7-03

**Files to modify**
- `apps/lemon_router/lib/lemon_router/model_selection.ex`
- `apps/lemon_router/lib/lemon_router/run_orchestrator.ex`
- `docs/model-selection-decoupling.md`

**Files to add**
- `apps/lemon_router/lib/lemon_router/model_feedback_adapter.ex`
- `apps/lemon_router/test/lemon_router/model_feedback_adapter_test.exs`

**Work items**
1. Use routing feedback only as a tie-breaker among already-valid candidate models/engines.
2. Gate the behavior behind `features.routing_feedback` and a minimum-sample-size rule.
3. Attach routing-decision diagnostics so model choice changes can be debugged post hoc.
4. Keep manual/explicit model overrides authoritative.

**Definition of done**
- Adaptive routing can be enabled or disabled without code changes.
- Model selection remains deterministic when no reliable feedback is available.
- Routing decisions explain when feedback affected the outcome.

### M7-02 — Add skill synthesis draft pipeline and review flow [L]
**Primary owner:** @lemon/skills
**Required reviewers:** @lemon/memory, @lemon/agent, @z80
**Depends on:** M2-01, M3-03, M4-02, M5-01, M6-01, M0-02
**Blocks:** M7-03, M8-01

**Files to modify**
- `apps/lemon_skills/lib/mix/tasks/lemon.skill.ex`
- `docs/skills_v2.md`
- `docs/memory/session_search_and_feedback.md`

**Files to add**
- `apps/lemon_skills/lib/lemon_skills/synthesis/filter.ex`
- `apps/lemon_skills/lib/lemon_skills/synthesis/generator.ex`
- `apps/lemon_skills/lib/lemon_skills/synthesis/draft_store.ex`
- `apps/lemon_skills/lib/lemon_skills/synthesis/reviewer.ex`
- `apps/lemon_skills/test/lemon_skills/synthesis_test.exs`

**Work items**
1. Generate candidate skill drafts only from successful, non-trivial, repeatable runs.
2. Produce manifest v2 + `SKILL.md` draft bundles, then lint and audit them before storage.
3. Store drafts in dedicated draft directories and add review commands for list/inspect/approve/reject.
4. Explicitly filter out secrets, one-off project facts, and low-quality procedural summaries.

**Definition of done**
- Generated skills are drafts, not live installs.
- Drafts are reviewable and traceable back to source runs without embedding raw transcripts.
- Draft generation respects audit/lint gates before surfacing to humans.

### M7-03 — Add rollout gates and evaluations for adaptive behavior [M]
**Primary owner:** @lemon/release
**Required reviewers:** @lemon/agent, @lemon/memory, @lemon/skills
**Depends on:** M7-01, M7-02
**Blocks:** M8-03

**Files to modify**
- `.github/workflows/quality.yml`
- `docs/agent-loop/GOALS.md`
- `docs/memory/session_search_and_feedback.md`

**Files to add**
- `apps/coding_agent/test/coding_agent/evals/routing_feedback_eval_test.exs`
- `apps/lemon_skills/test/lemon_skills/synthesis_eval_test.exs`

**Work items**
1. Define measurable gates for enabling routing feedback or skill synthesis by default: sample size, success delta, retry delta, and false-positive draft rate.
2. Add eval fixtures for adaptive routing and skill synthesis drafts.
3. Document rollback procedure and required evidence for flipping feature flags.
4. Keep both features opt-in until the metrics pass.

**Definition of done**
- Adaptive features have explicit promotion criteria.
- CI/evals can measure regressions in adaptive behavior.
- There is a documented rollback path.


## M8
### M8-01 — Restructure README and docs by audience [L]
**Primary owner:** @z80
**Required reviewers:** @lemon/docs, @lemon/runtime, @lemon/skills, @lemon/memory
**Depends on:** M0-02, M1-03, M1-04, M4-01, M4-03, M5-02, M5-03, M6-03, M7-02
**Blocks:** M8-02, M8-04

**Files to modify**
- `README.md`
- `docs/README.md`
- `docs/catalog.exs`
- `docs/config.md`
- `docs/skills.md`
- `docs/context.md`

**Files to add**
- `docs/user-guide/setup.md`
- `docs/user-guide/doctor.md`
- `docs/user-guide/skills.md`
- `docs/user-guide/memory.md`
- `docs/reference/cli.md`
- `docs/contributor-guide/README.md`

**Work items**
1. Shrink the root README into a 5-minute orientation and move deep dives into user-guide/reference/architecture/contributor buckets.
2. Document setup, doctor, skills, memory, and adaptive features from the user/operator perspective.
3. Keep the existing docs freshness model by registering every new page in `docs/catalog.exs`.
4. Add walkthroughs for fresh setup, TUI attach, skill inspect/install/update/audit, memory search, and skill-draft review.

**Definition of done**
- Root README is substantially shorter and user-focused.
- All new product surfaces are documented in a discoverable IA.
- Docs freshness enforcement still passes.

### M8-02 — Add contributor shell and public repo basics [M]
**Primary owner:** @lemon/release
**Required reviewers:** @z80
**Depends on:** M0-01, M8-01
**Blocks:** M8-03

**Files to modify**
- `README.md`

**Files to add**
- `CONTRIBUTING.md`
- `SECURITY.md`
- `LICENSE`
- `CHANGELOG.md`
- `.github/ISSUE_TEMPLATE/bug_report.md`
- `.github/ISSUE_TEMPLATE/feature_request.md`
- `.github/PULL_REQUEST_TEMPLATE.md`

**Work items**
1. Write contributor instructions around the real Lemon dev loop, docs catalog, skill manifest quality, and feature-flag policy.
2. Add standard repo files for license, security reporting, changelog/release notes, and issue/PR templates.
3. Ensure docs refer contributors to setup/doctor rather than source-only tribal knowledge.
4. State how security reports should handle skills, secrets, and generated artifacts.

**Definition of done**
- The repo looks and behaves like a project that expects contributors.
- Contributor docs match the productized workflow rather than outdated source-only steps.
- Security and issue-reporting basics are explicit.

### M8-03 — Add release automation and product CI [L]
**Primary owner:** @lemon/release
**Required reviewers:** @lemon/runtime, @z80
**Depends on:** M1-02, M1-07, M4-04, M5-04, M7-03, M8-02
**Blocks:** None

**Files to modify**
- `.github/workflows/quality.yml`
- `mix.exs`
- `clients/lemon-tui/package.json`
- `clients/lemon-web/package.json`

**Files to add**
- `scripts/release.exs`
- `.github/workflows/release.yml`
- `.github/workflows/product-smoke.yml`

**Work items**
1. Choose a single versioning scheme and apply it consistently across Mix and client packages.
2. Automate version bumps, release notes scaffolding, release artifact assembly, runtime smoke tests, and tag/publish steps.
3. Add product-smoke CI jobs for packaged runtime, doctor, skill lint/audit, memory search sanity, and adaptive feature evals.
4. Keep games-platform deployment workflow separate from general product release workflow.

**Definition of done**
- Release creation is scripted and reproducible.
- CI validates the packaged product surface, not just source compilation/tests.
- Version numbers and release notes no longer drift across artifacts.

### M8-04 — Add optional docs site generation after IA stabilizes [M]
**Primary owner:** @z80
**Required reviewers:** @lemon/docs, @lemon/release
**Depends on:** M8-01
**Blocks:** None

**Files to modify**
- `.github/workflows/quality.yml`

**Files to add**
- `docs/site/README.md`
- `.github/workflows/docs-site.yml`

**Work items**
1. Choose a static site generator that consumes repo markdown directly and supports local preview plus CI deployment.
2. Keep repo markdown as the source of truth; the site should be a publishing layer, not a second docs source.
3. Add link checking and preview/deploy workflow only after the IA is stable.
4. Treat this as optional until the new docs layout has settled.

**Definition of done**
- Docs site generation does not duplicate content ownership.
- Local preview and CI checks exist if the site is enabled.
- The in-repo markdown layout remains canonical.

