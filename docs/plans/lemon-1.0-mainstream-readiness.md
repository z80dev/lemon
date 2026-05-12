# Lemon 1.0 Mainstream Readiness Plan

Status: active launch goal

Last reviewed: 2026-05-12

## Summary

Lemon 1.0 should be a local-first AI agent platform that a non-contributor can
install, configure, use daily, upgrade, debug, and get support for without
needing repo expertise.

The goal is not to clone Hermes internals. The goal is to compete at the product
and harness level:

- reliable multi-step agent execution
- strong tool lifecycle guarantees
- durable memory and reusable skills
- safe delegation and background jobs
- useful local and channel-based interfaces
- clear setup, packaging, release, support, and website story

Lemon already has many of the hard architectural primitives: supervised BEAM
runtime, router/gateway separation, multiple engines, native tools, memory,
skills, control plane, release profiles, setup and doctor tasks, CI smoke lanes,
and a long-running Hermes-class parity scorecard. The remaining work is to make
those capabilities coherent, discoverable, tested, supportable, and polished
enough for mainstream use.

## Product Goal

Launch Lemon 1.0 as a mainstream-ready, self-hosted AI agent platform for
developers and technical operators who want local control, durable context, and
multi-channel agent access.

At launch, a new user should be able to:

1. Understand what Lemon is and why they would use it.
2. Install or build Lemon without understanding the umbrella internals.
3. Configure one provider and one interface.
4. Run a real coding task from TUI, web, or Telegram.
5. See what the agent is doing while it works.
6. Recover from common setup and runtime problems.
7. Upgrade safely.
8. Report an issue with enough diagnostics for maintainers to help.

## Positioning

Lemon should be positioned as:

> A local-first AI agent runtime for serious developer workflows, with durable
> memory, reusable skills, multi-engine execution, channel integrations, and
> BEAM-grade supervision.

This should stay concrete. The product is not a generic chatbot and not a hosted
SaaS-first assistant. It is an agent runtime that users can own.

## Competitive Standard

Hermes-class parity should be treated as an external bar for agent harness
quality, not as a requirement to copy implementation details.

Parity means Lemon should have comparable behavior for:

- tool ergonomics and enforcement
- tool-call lifecycle correctness
- provider and streaming edge cases
- memory and procedural skill usage
- delegated work and subagent joins
- scheduled/background jobs
- safe handling of untrusted tool output
- observable progress and failure metadata
- channel delivery and media behavior
- browser/web interaction

The existing parity scorecard remains the detailed harness ledger:

- `docs/plans/lemon-hermes-agent-harness-parity-scorecard.md`

This plan is broader. It combines parity with product readiness, packaging,
website, support, testing, and release discipline.

## Non-Goals

The 1.0 launch goal should not include:

- A full hosted cloud service.
- A billing system.
- A plugin marketplace.
- Full rewrite of the web client.
- Replacing every external engine with native Lemon behavior.
- Perfect feature parity with every Hermes surface before launch.
- Supporting every OS and package manager on day one.
- Broad non-technical consumer onboarding.

These may become later work, but the 1.0 target should stay focused on a
credible self-hosted product that advanced users can adopt and maintain.

## Launch Definition

Lemon is mainstream-ready when these statements are true:

1. **Install:** A fresh user can install and run Lemon from documented
   instructions or release artifacts.
2. **Configure:** The setup path handles provider credentials, secrets, runtime
   defaults, and one interface without hand-editing undocumented state.
3. **Use:** TUI, web, and Telegram each have a documented happy path.
4. **Trust:** Tool execution, approvals, memory, skills, and untrusted content
   behavior are tested and documented.
5. **Observe:** Users and maintainers can inspect runs, tool calls, subagents,
   approvals, failures, memory, skills, and cron jobs.
6. **Recover:** `doctor`, logs, support bundles, and troubleshooting docs cover
   common failures.
7. **Release:** Stable, preview, and nightly release channels are real enough to
   publish and update safely.
8. **Support:** Issues can be triaged with templates, diagnostics, logs, and
   clear support boundaries.
9. **Website:** A public site explains the product, shows how to install it,
   links to docs, and gives users confidence that the project is maintained.
10. **Quality:** Local and CI gates exercise the packaged product, not only unit
    modules.

## Mainstream User Profiles

### Developer

Wants a local coding agent that can work in repos, use tools, remember project
conventions, and be reachable from terminal or chat.

Needs:

- fast setup
- safe file and shell tool approval defaults
- repo-bound sessions
- usable TUI
- memory and skills that improve repeat tasks
- clear error reporting when provider calls fail

### Technical Operator

Wants an agent that can monitor, schedule, and run background tasks from a
server or workstation.

Needs:

- release runtime
- health checks
- cron and background job visibility
- Telegram or web access
- logs and support bundles
- upgrade and rollback path

### Contributor

Wants to extend Lemon without learning every umbrella boundary first.

Needs:

- architecture docs
- app-specific guides
- quality gates
- extension and skill docs
- ownership map
- readable failures

### Evaluator

Wants to compare Lemon against Hermes, Claude Code, Codex, OpenCode, Pi, or a
homegrown agent stack.

Needs:

- clear feature matrix
- demos
- honest gaps
- security model
- performance and reliability claims backed by tests
- reproducible examples

## Workstreams

### Workstream 1: Product Truth Audit

Goal: make the repo tell the truth about what works, what is partial, and what
is missing.

Scope:

- Audit README, docs, website scaffold, release docs, setup docs, CI workflows,
  and the parity scorecard.
- Remove or repair stale references, including missing roadmap or product docs.
- Produce a current gap table with owner, priority, risk, and acceptance
  criteria.
- Separate implemented features from planned features.

Deliverables:

- This plan.
- A living readiness checklist section in this document.
- Updated docs index links.
- Follow-up issues or plan slices for each major gap.

Exit criteria:

- New contributors can find the launch goal from `docs/README.md`.
- Every product claim in the root README has a backing doc, command, workflow,
  or test.
- Missing or stale product docs are either restored, rewritten, or removed from
  navigation.

### Workstream 2: Hermes-Class Harness Parity

Goal: finish enough agent-harness parity to make Lemon credible for long-running
real work.

Current source of truth:

- `docs/plans/lemon-hermes-agent-harness-parity-scorecard.md`

High-value remaining areas:

- media attachment contract for channel delivery
- per-channel markdown/rendering rules and tests
- browser interaction as a first-class tool surface
- media generation, TTS, and image-analysis strategy
- broader post-1.0 prompt-injection variant depth across web, email, and
  extension tools
- observability panels for skill loads, memory searches, approvals, subagent
  tree, and cron runs

Exit criteria:

- No high-priority gap remains in the parity scorecard.
- Medium-priority gaps are explicitly accepted, assigned to post-1.0, or
  converted into launch blockers.
- Deterministic evals cover every harness behavior that can be tested without
  external credentials.
- Live-model evals cover the core behaviors that depend on actual provider
  behavior.

### Workstream 3: Installation and Setup

Goal: a fresh user can get Lemon running without becoming a maintainer.

Target install paths:

1. Source-dev path for contributors.
2. Release-runtime path for users who do not need Mix.
3. Attached-client path for TUI/web against an existing runtime.

Required improvements:

- Verify `docs/user-guide/setup.md` against a clean environment.
- Make `mix lemon.setup` the canonical interactive path.
- Make `mix lemon.doctor` actionable, with specific fixes and links.
- Ensure Linux and macOS guidance is current.
- Decide the 1.0 supported package path:
  - release tarball only
  - release tarball plus install script
  - package-manager distribution later
- Document minimum provider setup for Anthropic, OpenAI, and OpenAI-compatible
  local endpoints.
- Keep secrets guidance consistent across README, setup guide, config docs, and
  doctor output.

Exit criteria:

- A fresh Linux machine can run Lemon from release artifacts.
- A fresh contributor machine can run Lemon from source.
- A user can configure one provider and complete one successful agent run.
- Failed provider, missing secret, bad config, and missing runtime dependency
  cases produce actionable doctor output.

### Workstream 4: Packaging, Release, and Update

Goal: make Lemon publishable and upgradeable.

Existing pieces:

- release profiles in `docs/release/deployment_flows.md`
- CalVer and channels in `docs/release/versioning_and_channels.md`
- release workflow
- product smoke workflow
- staged `mix lemon.update`

Required improvements:

- Verify the release workflow produces usable artifacts.
- Verify artifact names, checksums, and manifest shape.
- Decide which profiles are public:
  - `lemon_runtime_min`
  - `lemon_runtime_full`
  - `sim_broadcast_platform` if it remains a separate public target
- Make update behavior honest:
  - if remote update download is not implemented, docs must say so clearly
  - if stage-1 update is config and bundled-skill sync only, docs must say so
- Create a release checklist.
- Create a rollback checklist.
- Add a support policy for stable, preview, and nightly.
- Ensure changelog release sections are useful to users, not only maintainers.

Exit criteria:

- A tagged release builds artifacts through CI.
- Artifacts boot locally.
- Manifest checksums verify.
- Release docs match actual behavior.
- Stable and preview channels have clear expectations.

### Workstream 5: TUI, Web, and Channel Polish

Goal: each primary interface should have a complete daily-use path.

Primary surfaces:

- TUI for local development.
- Web UI for observability and operations.
- Telegram for remote chat access.

TUI launch criteria:

- connect to runtime reliably
- start or resume sessions
- show streaming output
- show tool progress and failures
- allow cancellation and follow-up
- make repo/cwd context clear

Web UI launch criteria:

- list sessions and runs
- inspect run timeline
- inspect tool calls and failures
- inspect subagent tree
- inspect approvals
- inspect memory searches and skill loads
- inspect cron/background runs
- expose logs or diagnostic references
- show health and version information

Telegram launch criteria:

- setup guide works end-to-end
- allowed chat configuration is safe by default
- command list is accurate
- long-running runs have useful progress
- cancellation works
- media and markdown behavior is documented
- error states are understandable

Exit criteria:

- Each surface has a documented happy path.
- Each surface has at least one smoke or integration check.
- Failure states are visible and actionable.

### Workstream 6: Website and Public Docs

Goal: create a public face for Lemon that can convert an interested user into a
successful install.

Existing pieces:

- VitePress docs scaffold in `docs/.vitepress/config.js`
- docs-site workflow
- root README
- user-guide docs
- architecture docs

Website information architecture:

1. Home
   - what Lemon is
   - who it is for
   - why local-first matters
   - primary install CTA
   - secondary docs CTA
2. Install
   - release install
   - source install
   - provider setup
   - first run
3. Features
   - coding agent
   - memory
   - skills
   - subagents
   - schedules
   - channels
   - web/TUI
4. Compare
   - Hermes-class harness parity
   - Claude Code, Codex, OpenCode, Pi positioning
   - honest strengths and gaps
5. Docs
   - user guide
   - config
   - troubleshooting
   - architecture
6. Support
   - issue templates
   - support bundle
   - security policy
   - release channels

Website acceptance criteria:

- The homepage explains Lemon in one screen.
- Install instructions are not buried in architecture docs.
- Feature claims link to docs or demos.
- The site can be built in CI.
- Broken internal docs links are treated as a real release blocker once the
  baseline is cleaned up.

### Workstream 7: Testing and Evaluation

Goal: confidence should come from product-level gates, not only unit tests.

Canonical local lanes:

- `scripts/test fast`
- `scripts/test quality`
- `scripts/test clients`
- `scripts/test eval-fast`
- `scripts/test all`

Release and product lanes:

- release smoke
- product smoke
- docs site build
- live-model evals for release candidates

Required improvements:

- Make product smoke prove real user flows:
  - boot packaged runtime
  - health check
  - doctor check
  - memory search probe
  - skill lint
  - representative control-plane request
  - web health check for full profile
- Add a release-candidate checklist that includes:
  - deterministic evals
  - live-model evals
  - client builds
  - docs build
  - artifact boot
  - update/rollback dry run
- Keep unit lanes hermetic and credential-safe.
- Add focused tests for any new setup, doctor, release, or support-bundle
  behavior.

Exit criteria:

- `scripts/test all` is meaningful for BEAM-centric local confidence.
- Client CI catches UI regressions.
- Product smoke catches packaged-runtime regressions.
- Release candidates run live-model evals before stable promotion.

### Workstream 8: Observability and Supportability

Goal: maintainers should be able to diagnose user issues from structured
evidence.

Required capabilities:

- support bundle command or doctor mode
- version and build metadata
- config redaction report
- runtime health snapshot
- provider configuration status without secret exposure
- recent run summary
- recent error summary
- log file locations
- extension and skill inventory
- memory store status
- channel adapter status
- release channel and update status

Possible command:

```bash
mix lemon.doctor --bundle
```

or, for release runtime:

```bash
lemon_runtime_full doctor --bundle
```

Support bundle rules:

- never include API keys, OAuth tokens, private keys, cookies, or raw secrets
- redact provider headers and command env
- include enough version/config state to reproduce common issues
- write a single archive or directory path
- print exactly what was included

Docs required:

- troubleshooting guide
- support bundle guide
- log locations
- common provider errors
- common Telegram errors
- common release boot errors
- upgrade and rollback guide

Exit criteria:

- A GitHub issue template asks for the support bundle.
- The support bundle can be generated from source-dev and release-runtime paths.
- A maintainer can identify setup, config, provider, release, and channel
  classes of failure from the bundle.

### Workstream 9: Security and Trust

Goal: users should understand what Lemon can do, what it will ask approval for,
and how secrets and untrusted content are handled.

Existing pieces:

- `SECURITY.md`
- `docs/security/agent-safety-contract.md`
- tool policies
- approval gates
- secret screening for memory and skill synthesis
- skill install/update audit
- untrusted tool-output boundary

Required improvements:

- Make the public security model easy to read.
- Document default approval behavior for shell and file writes.
- Document what skills can and cannot do.
- Document extension trust levels.
- Keep the launch-focused prompt-injection tests for web, email, skill, and
  extension-style tool surfaces green.
- Add broader adversarial variant depth after 1.0.
- Ensure website and README do not imply unsafe automation is enabled by
  default.

Exit criteria:

- New users can understand the safety model before running tools.
- Security docs match actual tool policy behavior.
- Prompt-injection regressions are covered by deterministic tests.

### Workstream 10: Documentation Maintenance

Goal: documentation remains accurate as launch work lands.

Rules:

- Every doc in `docs/` must be registered in `docs/catalog.exs`.
- Product docs should distinguish implemented, partial, and planned behavior.
- README should stay short and correct.
- Deep details should live in docs, not app guides.
- Any code change that changes behavior must update the relevant docs.

Immediate cleanup candidates:

- Replace stale roadmap references with this plan or restore a real roadmap.
- Ensure VitePress navigation points only at existing docs.
- Make release/update docs match actual `mix lemon.update` behavior.
- Keep changelog entries user-readable.

Exit criteria:

- `mix lemon.quality` passes documentation freshness checks.
- Docs site builds.
- Internal links are clean enough to make link failures blocking.

## Launch Gap Execution Ledger

This is the first repo-backed audit snapshot for Milestone 1. It should be
updated as each gap is closed or reclassified.

Snapshot date: 2026-05-11

Priority:

- P0: must be resolved before any stable 1.0 release.
- P1: must be resolved or explicitly documented as preview/accepted risk before
  stable 1.0.
- P2: useful polish or post-1.0 hardening.

Status:

- Done: no remaining action for this gap in the current milestone.
- Partial: some remediation landed, but launch work remains.
- Open: no implementation or proof exists yet.
- Blocked: needs a product or scope decision before implementation.

| ID | Area | Owner lane | Priority | Status | Current evidence | Gap | Next action |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G1 | Launch goal | Product / Docs | P0 | Done | `docs/plans/lemon-1.0-mainstream-readiness.md` exists, is registered in `docs/catalog.exs`, and is linked from `README.md`, `docs/README.md`, and VitePress navigation. | The launch goal needed a durable repo artifact. | Keep this document as the execution ledger. |
| G2 | Roadmap truth | Docs | P1 | Done | Root `README.md` and `docs/README.md` now point at this plan instead of a missing `ROADMAP.md`. A repo-wide stale-reference pass found no remaining main-checkout `ROADMAP.md` references outside this execution ledger; only old `.worktrees/` review branches still contain their own roadmap files. | No remaining launch-blocking roadmap-truth gap. | Keep this plan as the launch roadmap unless a separate public roadmap is intentionally restored. |
| G3 | Release/update truth | Runtime / Docs | P0 | Done for docs truth | `apps/lemon_core/lib/mix/tasks/lemon.update.ex` says remote update download is not available; `docs/release/versioning_and_channels.md` now describes current stage-1 update behavior. | Remote binary update is not implemented. | Treat remote update as a separate launch gap only if 1.0 requires auto-update. |
| G4 | Release artifact scope | Release | P0 | Done for initial 1.0 scope | `.github/workflows/release.yml` builds `lemon_runtime_min` and `lemon_runtime_full` on `ubuntu-latest`; release docs now state Linux `x86_64` artifact scope. `docs/release/release_checklist_and_support_policy.md` makes Linux `x86_64` tarballs the initial stable 1.0 release artifact support target. | macOS and other release artifacts remain future release-matrix work. | Reopen only when expanding supported artifact platforms. |
| G5 | Product smoke strength | Release / Harness | P0 | Done for deterministic packaged runtime | `.github/workflows/product-smoke.yml` now boots a release, checks control-plane HTTP health, handshakes over the control-plane WebSocket protocol, calls `health`, submits a deterministic `echo` agent run through `agent`, waits through `agent.wait`, checks web `/healthz` for `lemon_runtime_full`, lints skills, and runs adaptive gate checks. | Product smoke intentionally avoids live provider credentials and does not cover memory-search behavior. | Keep live provider and memory behavior covered by eval, focused tests, and manual release-candidate checks rather than CI product smoke. |
| G6 | Doctor support mode | Runtime / Support | P0 | Done | `mix lemon.doctor --bundle` and release-runtime `LemonCore.Doctor.CLI.bundle!()` now write a redacted zip containing the doctor report, runtime metadata, selected environment shape, and redacted Lemon config files. Product smoke verifies release support-bundle generation from the packaged artifact. | Bundle redaction intentionally excludes logs, memory contents, private prompts, and tool outputs rather than collecting them. | Keep redaction tests current as support data expands. |
| G7 | Issue triage | Support | P1 | Done | `.github/ISSUE_TEMPLATE/bug_report.md` distinguishes source-dev vs release-runtime installs and asks for the appropriate redacted support-bundle command in each path. | Users still need to review bundles before attaching them. | Revisit once public release artifact naming is final. |
| G8 | Website scaffold | Product / Docs | P0 | Partial | `docs/index.md` now provides a VitePress homepage with positioning, launch-stage status, and entry points; `docs/install.md` provides a short install landing page with source install, provider setup, doctor, and release-artifact status; `docs/compare.md`, `docs/demo.md`, and `docs/support.md` add public-facing comparison, deterministic demo, and support-boundary pages; navigation links the full product-doc set. `docs/assets/launch/web-session-proof-2026-05-11.png` and `docs/assets/launch/web-ops-proof-2026-05-11.png` provide initial launch screenshots for the Web interface. | The site still needs final public release-asset copy and broader launch media after downloaded artifact proof. | Add final release artifact language after public artifact verification and capture TUI/Telegram launch visuals when those live proofs pass. |
| G9 | Docs site link gate | Docs | P1 | Done | VitePress navigation links to existing launch, user guide, architecture, testing, release, and contributor docs. The docs markdown link baseline passes locally with `markdown-link-check`, and `.github/workflows/docs-site.yml` now fails when the link check reports broken links. `scripts/verify_docs_site` now installs docs dependencies in a temp copy, runs high-severity docs-tooling audit, builds the VitePress site, and runs the markdown link check without leaving `docs/node_modules`, `docs/package-lock.json`, or `docs/.vitepress/dist` in the repo. | External links can still drift after a green CI run. | Keep `.mlc.json` focused on intentional localhost/internal exceptions and fix broken external docs links when they appear. |
| G10 | Hermes parity | Harness | P0 | Done for initial 1.0 scope | `docs/plans/lemon-hermes-agent-harness-parity-scorecard.md` tracks completed harness slices, no active high-priority memory/skill/delegation/tool-lifecycle gap, launch-focused safety coverage, and remaining medium/post-1.0 gaps. The Hermes parity launch classification below marks browser/media/rich-channel/admin-console depth as post-1.0 or preview unless marketed as stable launch features. | Ongoing parity hardening remains, but no current harness gap blocks the initial 1.0 launch positioning. | Keep deterministic and opt-in live-model eval lanes green for release candidates; reopen only if launch messaging expands stable claims. |
| G11 | UI supportability | Interfaces / Support | P0 | Done for initial 1.0 scope | `docs/plans/lemon-1.0-interface-supportability-audit-2026-05-11.md` verifies that the control plane already exposes broad support APIs for health, logs, sessions, runs, run graphs, run introspection, tasks, cron, approvals, skills, events, config, secrets status, channels, transports, and usage. The TUI has credible local session, streaming, tool lifecycle, stats, overlay, cancellation support, a source-runtime deterministic echo transcript, a source-runtime rendered tool-failure transcript, and source-runtime cancellation proof against a real cancellable run. Telegram has session commands, model selection, cancellation, watchdog controls, and channel-native approval callbacks. `LemonWeb.OpsDashboardLive` now adds `/ops`, an initial Web operations dashboard with runtime/router health, provider/secrets status, version/build/release metadata, active sessions, recent runs, pending approval resolution actions, observed cron/skill/channel/memory/log activity from introspection, cron schedule and recent failure summary, cron create/edit/delete/run controls, installed skill provenance/status plus install/update/enable/disable controls, channel transport enablement config controls, default provider/model/thinking/engine editing, provider secret-reference editing, gateway default editing, Telegram token-secret/allowlist editing, configured binding create/edit/delete controls, live adapter runtime status, disconnect/reconnect controls for configured adapters, support-bundle download/commands, and next-panel placeholders. `LemonWeb.OpsRunLive` adds `/ops/runs/:run_id`, a run-detail page for timeline events, tool events, failures, nested run graph/subagent lineage, run-scoped pending approvals, event counts, and support-bundle download/commands. `docs/plans/lemon-1.0-interface-proof-pack-2026-05-11.md` records green automated evidence for the TUI lane, TUI source-runtime echo/tool-failure/cancellation proof, Web supportability tests including cron, skill, and channel controls, Web source-runtime browser proof, unified-runtime custom-port Web proof, Telegram/router deterministic coverage, and Telegram live proof for /cwd, progress rendering, prompt round-trip, bare /cancel on a real active run, approval-button resolution, and concise invalid-model config errors. `docs/support.md` now defines Telegram's text-first markdown/media support boundary for stable 1.0. | Broader Web admin/config panels outside defaults, providers, channels, cron, skills, approvals, runs, runtime health, and support bundles are post-1.0 unless marketed as stable launch features. | Keep proof pack and interface tests green; reopen only if launch messaging expands the Web UI into a full admin console. |
| G12 | Fresh install proof | Runtime / Docs | P0 | Partial | `docs/plans/lemon-1.0-fresh-install-proof-2026-05-11.md` records a clean source-copy install proof with isolated `HOME`, `MIX_HOME`, and `HEX_HOME`; `mix deps.get`, `mix compile`, and `mix lemon.doctor --bundle` completed with no doctor failures. It also records a clean Docker source-install proof on the current supported toolchain, Elixir 1.19.5 / Erlang/OTP 28, using `elixir:1.19.5-otp-28`; `mix deps.get`, `mix compile`, and `mix lemon.doctor --bundle` completed with no doctor failures. The simulator UI Dockerfile now builds on the current Hex.pm Elixir/OTP image, `hexpm/elixir:1.19.5-erlang-28.5-debian-bookworm-20260505`, and `docker manifest inspect` confirmed that image tag exists. The same proof file now records isolated `mix lemon.setup --non-interactive`, `mix lemon.setup runtime --profile runtime_min`, and fake-token `mix lemon.setup provider` checks for Anthropic and OpenAI; the runtime check found and fixed a stale release command, now covered by setup task tests. `docs/plans/lemon-1.0-release-artifact-proof-2026-05-11.md` records refreshed `2026.05.0` local tarball proofs for `lemon_runtime_min` and `lemon_runtime_full`: checksum verified, extracted runtime booted, `/healthz` returned ok, and release `eval` generated a support bundle. Setup docs now include `mix local.hex --force`, real `mix lemon.setup` / `mix lemon.secrets.*` commands, an OpenAI-compatible endpoint example, and prerequisites updated to Elixir 1.19.5, Erlang/OTP 28.5, and Node.js 24 LTS. `gh release list --limit 10` returned no public releases on 2026-05-11 and again on 2026-05-12, so downloaded artifact proof is not yet possible. | Public GitHub Release artifact download proof is still missing. | Publish a release, then rerun artifact proof against downloaded public release artifacts before stable 1.0. |
| G13 | Security posture | Security / Docs | P0 | Done for initial 1.0 scope | `SECURITY.md`, `docs/security/agent-safety-contract.md`, and `docs/security/safety.md` exist. The public safety page explains Lemon's local-first safety model, recommended approval defaults, secrets handling, high-risk operations, support-bundle redaction, and vulnerability reporting. The parity scorecard tracks tool policies, approvals, memory screening, skill audit, and untrusted boundaries. Deterministic prompt-injection coverage now spans web fetch output, inbound email prompts, skill prompt rendering, and generic untrusted extension-style tool results. | Broader adversarial prompt-injection variant depth remains post-1.0 hardening work. | Keep the launch-focused safety tests green and add deeper adversarial variants after 1.0. |
| G14 | Release channel support | Release / Support | P1 | Partial | `docs/release/versioning_and_channels.md` defines stable, preview, and nightly channels. `docs/release/release_checklist_and_support_policy.md` now defines the release-candidate checklist, tag/publish checklist, rollback checklist, initial support matrix, and support boundaries. `.github/workflows/release.yml` publishes `manifest.json` with artifact sizes and SHA-256 checksums, verifies the assembled artifact directory before publishing, requires matched release files, and the `verify-published-artifacts` job downloads the published GitHub Release assets and runs `scripts/verify_github_release_artifacts`. `scripts/verify_release_artifacts` verifies manifest entries against downloaded files. `scripts/verify_release_runtime_boot` verifies manifest/checksums, extracts both runtime profiles, boots them without Mix, checks health, and generates support bundles. `scripts/verify_github_release_artifacts` downloads a GitHub Release's Linux `x86_64` artifacts and manifest, then runs the runtime boot verifier. `.github/workflows/live-eval.yml` provides a manual release-candidate live-model eval lane on Elixir 1.19.5 / Erlang/OTP 28.5. `scripts/audit_1_0_readiness` wraps the final release-candidate audit for version metadata, release notes, CI/docs policy, canonical local test lanes, docs-site verification, local artifact manifest/runtime boot verification, public GitHub Release artifact verification/runtime boot, and provider-backed live eval. `scripts/prepare_release_notes` now blocks publishing unless the target version has a useful Keep a Changelog-style section for the GitHub Release body. `scripts/lint_ci_docs.sh` now fails if first-party version metadata drifts from `mix.exs`, published-artifact verification is removed from release automation, first-party BEAM toolchain pins drift from Elixir 1.19.5 / OTP 28.5, docs-site verification or canonical local test lanes fall out of the final readiness audit, or the manual live-eval workflow is missing, not manual-only, disconnected from `scripts/test live-eval`, or undocumented. `CHANGELOG.md` has a `## [2026.05.0]` release section, `scripts/prepare_release_notes 2026.05.0` passes, and the release workflow uses that version-specific section for the GitHub Release body. `gh release list --limit 10` returned no public releases on 2026-05-11 and again on 2026-05-12. | Release automation still needs a downloaded-public-artifact proof before stable 1.0. Remote binary update remains out of 1.0 scope. | Publish a GitHub Release and confirm the `verify-published-artifacts` job plus `scripts/verify_github_release_artifacts {tag-or-version}` pass before stable 1.0. Keep release notes versioned before tagging. |
| G15 | Dependency audit | Docs / Security | P1 | Done for initial 1.0 scope | `npm audit --json` in `docs/` reports three moderate advisories in `vitepress -> vite -> esbuild`, no high or critical advisories, and `fixAvailable: false`. `docs/release/release_checklist_and_support_policy.md` now defines the dependency audit policy: high/critical runtime or docs-tooling advisories block release candidates; moderate docs-build tooling advisories are accepted only when they do not ship in runtime tarballs, static docs build succeeds, link checking succeeds, there is no safe available fix, and the finding is recorded in the launch ledger. `.github/workflows/docs-site.yml` runs `npm audit --audit-level=high` after installing docs dependencies. | The accepted advisories can still be fixed later when VitePress publishes a safe dependency chain. | Revisit before public docs launch or when a safe VitePress/Vite/esbuild fix becomes available. |

## Hermes Parity Launch Classification

Source: `docs/plans/lemon-hermes-agent-harness-parity-scorecard.md`.

This table classifies the scorecard's current residual gaps for the 1.0 launch.
It does not replace the scorecard; it decides which parity gaps must block
stable launch versus which can be documented as preview or post-1.0.

| Scorecard area | Current scorecard status | Residual gap | Launch classification | Required 1.0 action |
| --- | --- | --- | --- | --- |
| Tool ergonomics and enforcement | Partial / strong foundation; high priority | Portability aliases and broader prompt guidance for non-memory/non-skill tool families may be useful later. | Post-1.0 unless prompt/tool drift is found during fresh install or eval work. | Keep existing deterministic tool lifecycle, schema, transcript, streaming, and policy contracts green. |
| Skills lifecycle and procedural memory | Partial / strong foundation; no active high-priority harness gap remains. | No launch-blocking skill lifecycle gap currently identified. | Not blocking. | Keep skill docs and evals green; verify setup docs explain skills clearly. |
| Memory and session recall | Partial / strong foundation; no active high-priority harness gap remains. | No launch-blocking memory selection gap currently identified. | Not blocking. | Keep memory docs and evals green; product smoke should stop accepting unimplemented memory search for full launch profile. |
| Delegation and orchestration | Partial / strong foundation; live-model delegation coverage exists. | No active launch-blocking delegation harness gap currently identified. | Not blocking. | Keep deterministic and live-model delegation evals in release-candidate validation. |
| Cron and durable background jobs | Partial; medium-high priority | Recursive model-facing scheduling is structurally blocked, but non-tool API entrypoints remain operator-controlled. | Preview for stable 1.0: support reproducible operator-controlled scheduling bugs, not production-grade scheduling guarantees or unrestricted model-facing cron management. | Keep the documented support boundary current and keep blocked-tool evals green. |
| Messaging and native delivery | Partial / strong foundation; medium priority | Telegram now has documented text-first markdown/media support boundaries; richer live media proof is still absent. Other channel adapters have code/docs but less launch proof. | Telegram text-first remote chat is stable for 1.0. Discord, X/Twitter, XMTP, SMS, voice, and other channel adapters are preview unless promoted by release notes. | Keep markdown/outbound/tool tests green and do not market rich media generation, image analysis, TTS, or preview channel adapters as stable 1.0 features. |
| Browser/web/media tools | Partial; medium priority | Browser interaction is not first-class in the default native harness. Media generation, TTS, and image analysis remain outside the stable Telegram/product promise. | Stable 1.0 supports first-party text web search/fetch in reproducible agent runs. Browser automation is preview; generated media, image analysis, and voice/TTS are preview or out of scope unless promoted by release note. | Keep the public support boundary current and do not market browser/media as stable launch features. |
| Safety, approvals, and untrusted content | Done for initial 1.0 safety scope; broader hardening remains | Launch-focused prompt-injection coverage now covers web fetch output, inbound email prompts, skill prompt rendering, and generic untrusted extension-style tool results. | Not blocking for initial 1.0; broader adversarial variant depth remains P1. | Keep launch-focused safety tests green and expand adversarial variants after 1.0. |
| Observability and dogfood loop | Done for initial 1.0 support scope; richer metrics remain post-1.0 | `/ops` and `/ops/runs/:run_id` now cover runtime health, recent runs, active sessions, approvals, cron schedules and failures, skills, channel transports, memory/log activity summaries, nested run lineage, event counts, support bundles, and core runtime/config controls. | Not blocking for a daily developer-agent launch; P1 if Lemon later markets a full operations/admin console. | Keep browser proof and supportability tests green; add richer dashboards after the release artifact and security blockers are closed. |

Current parity decision:

- The core agent harness is strong enough to continue toward 1.0; the remaining
  scorecard gaps are mostly productization, observability, channel, browser,
  and safety-depth work.
- Stable 1.0 should not claim first-class browser automation, media generation,
  or rich media channel delivery until those surfaces are implemented and
  tested.
- Public GitHub Release artifact proof and final release-site copy are now the
  highest launch risks, not core tool-call lifecycle semantics.

## Docs-Site Audit Classification

Command run from `docs/`:

```bash
npm install --package-lock-only --ignore-scripts
npm audit --json
```

Current result:

- `vitepress` is the direct dependency with a moderate advisory through `vite`.
- `vite` reports a moderate optimized-deps source-map path traversal advisory.
- `esbuild` reports a moderate development-server request exposure advisory.
- `fixAvailable` is `false` for the reported dependency chain.

Launch classification:

- This does not block Lemon runtime release artifacts because the affected
  packages are docs-site tooling and are not shipped in `lemon_runtime_min` or
  `lemon_runtime_full`.
- This can block a public docs-site launch only if the docs site is served by a
  long-running Vite/VitePress development server. GitHub Pages/static hosting of
  the built output does not expose that dev server path.
- Before enabling a public docs deployment, rerun `npm audit`, check whether a
  fixed VitePress/Vite chain exists, and document any accepted risk in release
  notes if no fix is available.

## Current Launch Status

Milestone 0 is mostly complete:

- launch goal document exists
- docs catalog includes it
- docs hub links it
- README points to it
- docs site navigation exposes it
- initial quality and docs-site build validation passed after cleanup

Milestone 1 is now active:

- build the full gap ledger
- verify each launch claim against code, docs, workflows, or tests
- fix inaccurate launch-critical docs immediately
- classify remaining gaps as launch-blocking, post-1.0, or accepted risk
- turn the P0 rows into implementation slices

## Milestones

### Milestone 0: Launch Goal Accepted

Purpose: agree on the target and make it visible.

Deliverables:

- `docs/plans/lemon-1.0-mainstream-readiness.md`
- docs index and catalog registration
- initial launch checklist

Exit criteria:

- The goal is discoverable from the docs hub.
- The plan has measurable launch criteria.
- The next execution batch is explicit.

### Milestone 1: Truth Audit and Gap Ledger

Purpose: eliminate ambiguity.

Deliverables:

- current-state audit of README, setup docs, release docs, website scaffold,
  workflows, parity scorecard, and UI surfaces
- launch gap ledger
- stale-link cleanup
- product claim inventory

Exit criteria:

- Every launch-critical claim is classified as implemented, partial, planned, or
  incorrect.
- Incorrect claims are fixed or removed.
- Launch blockers are listed with acceptance criteria.

### Milestone 2: Installable Release Candidate

Purpose: make Lemon runnable by users who are not contributors.

Deliverables:

- verified release artifact boot
- release install guide
- source install guide refresh
- setup/doctor hardening
- config and secrets docs refresh
- release checklist
- rollback checklist

Exit criteria:

- Fresh machine install is verified.
- Packaged runtime boots and passes health checks.
- First-run provider setup is documented and tested.

### Milestone 3: Product Smoke and Harness Confidence

Purpose: make CI prove real product behavior.

Deliverables:

- stronger product smoke lane
- release-candidate eval checklist
- live-model eval release process
- expanded parity scorecard closure plan
- prompt-injection variant tests

Exit criteria:

- Release candidate gates catch packaged-runtime, provider, docs, and harness
  regressions.
- Remaining parity gaps are non-blocking or explicitly assigned.

### Milestone 4: Interface Polish

Purpose: make daily use coherent.

Deliverables:

- TUI happy-path polish
- web observability panels
- Telegram command/error polish
- media/channel rendering docs and tests
- browser tool product decision

Exit criteria:

- A user can run and inspect a real task from each primary surface.
- Failures are visible and actionable.
- Support docs explain each surface.

### Milestone 5: Support and Operations

Purpose: make user support practical.

Deliverables:

- support bundle
- troubleshooting guide
- log and diagnostics docs
- issue templates
- release channel support policy
- upgrade/update/rollback guide

Exit criteria:

- A user can file a useful issue without maintainer back-and-forth for basic
  environment data.
- Maintainers can triage setup, provider, runtime, channel, and release classes
  of failure from bundle data.

### Milestone 6: Public Website and Launch Package

Purpose: make Lemon understandable and credible to the public.

Deliverables:

- public homepage
- install page
- feature pages
- comparison page
- demos or screenshots
- docs site deployment
- launch changelog
- first stable release

Exit criteria:

- Website explains the product clearly.
- Install path works from the site.
- Stable release artifacts are published.
- Docs, README, changelog, and release notes agree.

## Readiness Checklist

### Product

- [x] Clear one-sentence positioning exists.
- [x] README matches current behavior.
- [x] Website homepage exists.
- [x] Website install path exists.
- [x] Feature matrix exists.
- [x] Hermes-class parity status is summarized for users.
- [x] Known gaps are documented honestly.

### Install and Setup

- [x] Source install verified.
- [x] Release install verified locally for `lemon_runtime_full` artifact shape.
- [x] `mix lemon.setup` verified.
- [x] `mix lemon.doctor` verified.
- [x] Provider setup verified for Anthropic.
- [x] Provider setup verified for OpenAI.
- [x] OpenAI-compatible local endpoint setup documented.
- [x] Secrets setup documented.
- [x] Config examples are current.

### Runtime and Release

- [x] `lemon_runtime_min` boots.
- [x] `lemon_runtime_full` boots.
- [x] Health endpoint works for both local release artifact proofs.
- [x] Product smoke covers packaged runtime.
- [ ] Release workflow publishes artifacts.
- [x] Manifest includes checksums.
- [x] Release notes are useful.
- [x] Update behavior is documented accurately.
- [x] Rollback path is documented.

### Agent Harness

- [x] High-priority parity gaps closed.
- [x] Tool lifecycle tests pass.
- [x] Memory tests pass.
- [x] Skill tests pass.
- [x] Delegation tests pass.
- [x] Cron/background tests pass.
- [x] Safety tests pass.
- [ ] Live-model evals run for release candidates.

### Interfaces

- [x] TUI happy path documented and tested for source-runtime deterministic echo path, rendered tool-failure path, and real-run cancellation path.
- [x] Web UI happy path documented and tested for source-runtime deterministic echo path and unified-runtime custom-port boot.
- [x] Telegram happy path documented and tested for /cwd, prompt round trip, progress rendering, bare /cancel, and approval-button resolution.
- [x] Web UI shows tool failures.
- [x] Web UI shows subagent tree.
- [x] Web UI shows approvals.
- [x] Web UI shows memory/skill activity.
- [x] Cron/background jobs visible.
- [x] Channel markdown behavior documented.
- [x] Media attachment behavior documented for Telegram's text-first 1.0 support boundary.

### Support

- [x] Support bundle exists.
- [x] Support bundle redacts secrets.
- [x] Troubleshooting guide exists.
- [x] Log locations documented.
- [x] Issue templates request useful diagnostics.
- [x] Security policy is current.
- [x] Release channel support policy exists.

### Documentation

- [x] Docs catalog includes every doc.
- [x] Docs site builds.
- [x] Internal links are clean.
- [x] VitePress navigation points at existing pages.
- [x] Stale roadmap references fixed.
- [x] Changelog is current.
- [x] Prompt-to-artifact completion audit exists.

## Latest Validation

2026-05-12:

- `scripts/test quality` passed: CI/docs lint, test runner contract, skill lint,
  `mix lemon.quality`, and focused quality/eval harness tests.
- `scripts/test clients` passed after the `2026.05.0` client metadata and
  lockfile updates.
- `uv run pytest` passed in `clients/lemon-cli` after the Python CLI metadata
  and `uv.lock` update.
- `scripts/lint_ci_docs.sh` passed with the first-party version metadata guard.
- `scripts/test_contract.sh` passed after adding the explicit `scripts/test
  live-eval` lane.
- `.github/workflows/live-eval.yml` now provides a manual release-candidate
  live eval lane on Elixir 1.19.5 / Erlang/OTP 28.5, backed by repository
  secrets and dispatch inputs for provider/model/base URL/API type.
- `scripts/lint_ci_docs.sh` now fails if the manual live eval workflow is
  missing, is not manual-only, drifts from the supported BEAM toolchain, stops
  calling `scripts/test live-eval`, or falls out of testing/release docs.
- `scripts/lint_ci_docs.sh` now also fails if first-party workflow or simulator
  UI Dockerfile BEAM pins drift from Elixir 1.19.5 / Erlang/OTP 28.5.
- `npm run build` in `docs/` now passes after replacing raw angle-bracket
  placeholders in public release docs with VitePress-safe brace placeholders.
- The docs markdown link check passes after the public release-doc placeholder
  cleanup.
- `scripts/verify_docs_site` now repeats the docs high-severity audit, VitePress
  build, and markdown link check in a temp copy, so the final readiness audit can
  validate the public docs surface without leaving generated files in the repo.
- `scripts/audit_1_0_readiness` now runs the canonical local release-candidate
  lanes before accepting local evidence: `scripts/test fast`,
  `scripts/test quality`, `scripts/test eval-fast`, and `scripts/test clients`.
- `scripts/audit_1_0_readiness` now provides a final release-candidate audit
  wrapper for version metadata, release notes, CI/docs policy, local test lanes,
  docs-site verification, local artifact manifest and runtime boot
  verification, public GitHub Release artifact verification and boot, and
  provider-backed live eval.
- `.github/workflows/release.yml` now has a `verify-published-artifacts` job
  that depends on publication, downloads the GitHub Release assets, and runs
  `scripts/verify_github_release_artifacts`.
- `scripts/verify_release_artifacts` now enforces the initial 1.0 artifact
  contract directly: CalVer manifest version, safe channel name, exact Linux
  `x86_64` artifact names, and both required profiles
  (`lemon_runtime_min`, `lemon_runtime_full`).
- `scripts/test_contract.sh` now proves the artifact verifier accepts a complete
  min/full manifest and rejects a manifest missing `lemon_runtime_full`.
- `scripts/verify_github_release_artifacts` now retries release lookup and asset
  download so the post-publish workflow gate is less sensitive to GitHub asset
  propagation timing.
- `scripts/lint_ci_docs.sh` now fails if the release workflow stops verifying
  published GitHub Release artifacts after upload.
- `scripts/audit_1_0_readiness 2026.05.0
  /tmp/lemon-release-artifact-proof-2026-05-0/artifacts` now exits `66` only
  because launch-blocking external evidence is missing. It confirms version
  metadata, release notes, CI/docs policy, `scripts/test fast`,
  `scripts/test quality`, `scripts/test eval-fast`, `scripts/test clients`,
  docs-site verification, and local artifact manifest/runtime boot
  verification.
- The final `scripts/test fast` rerun passed after tightening three
  timing-sensitive cleanup tests: LocalServer duplicate-name teardown, Outbox
  queue-full fixture shape, and AgentCore EventStream timeout cleanup.
- `env -u LEMON_EVAL_API_KEY -u INTEGRATION_API_KEY -u ANTHROPIC_API_KEY
  scripts/test live-eval` failed fast with exit `66` before app startup and
  printed the accepted credential variables.
- `scripts/verify_github_release_artifacts 2026.05.0` failed fast with exit
  `66` because GitHub Release `v2026.05.0` does not exist yet.
- `docs/plans/lemon-1.0-completion-audit-2026-05-12.md` now maps the launch
  objective to concrete artifacts, commands, evidence, and the two remaining
  external launch blockers.
- `scripts/bump_version.sh 2026.05.0` aligned first-party version metadata
  across the Elixir umbrella, Node clients, package locks, Python CLI metadata,
  Python CLI lockfile package block, and CLI banner.
- `mix run --no-start -e 'IO.puts(Mix.Project.config()[:version])'` returned
  `2026.05.0`.
- `scripts/prepare_release_notes 2026.05.0` passed and produced the
  version-specific GitHub Release body from `CHANGELOG.md`.
- `MIX_ENV=prod mix release lemon_runtime_min --overwrite` and
  `MIX_ENV=prod mix release lemon_runtime_full --overwrite` passed for the
  `2026.05.0` candidate.
- `scripts/verify_release_artifacts
  /tmp/lemon-release-artifact-proof-2026-05-0/artifacts` passed for the
  refreshed local release tarballs.
- Extracted `2026.05.0` local proof tarballs for `lemon_runtime_min` and
  `lemon_runtime_full` booted without Mix, returned `{"ok":true}` from
  `/healthz`, and generated release-runtime support bundles.
- Focused deterministic harness tests passed:
  - memory store, ingest, document, safety, routing-fingerprint, and simulation
    memory tools
  - all `apps/lemon_skills/test`
  - AgentCore tool-call and tool-supervision tests
  - CodingAgent eval harness, task, agent, subagent, and extension lifecycle
    tests
  - all `apps/lemon_automation/test/lemon_automation`
- `gh release list --limit 10` returned no public releases, so downloaded
  artifact proof remains blocked.
- Live-model eval credentials were absent for `LEMON_EVAL_API_KEY`,
  `INTEGRATION_API_KEY`, and `ANTHROPIC_API_KEY`, so `scripts/test live-eval`
  remains unrun against a real provider.
- Cron and scheduled automation are now classified as preview for stable 1.0:
  supported only for reproducible operator-controlled scheduling bugs through
  first-party runtime/Web paths, not production-grade scheduling guarantees or
  unrestricted model-facing cron management.
- Browser/media support is now classified in public docs: first-party text web
  search/fetch can be supported in reproducible agent runs, while browser
  automation, generated media, image analysis, and voice/TTS remain preview or
  out of scope unless a release note promotes a narrower path.
- 1.0 install support is scoped to source install plus verified Linux `x86_64`
  tarballs. A one-line remote install script is not part of the initial support
  promise.
- Telegram is the stable remote channel for text-first agent runs. Discord,
  X/Twitter, XMTP, SMS, voice, and other channel adapters remain preview unless
  promoted by release notes.
- Hermes comparison is public as a scorecard/readiness reference, not as a
  blanket drop-in compatibility claim beyond the supported 1.0 feature boundary.
- `mix lemon.update` remains stage-1 only for 1.0: version reporting, config
  migration, and bundled-skill sync, not remote binary update.
- The minimum live-model eval matrix for stable promotion is the full current
  `scripts/test live-eval` lane passing at least once for the release
  candidate.

## Launch Blockers

These should block a 1.0 stable release:

- There is no public GitHub Release yet, so `scripts/verify_github_release_artifacts {tag-or-version}` cannot complete the downloaded artifact proof.
- `scripts/test live-eval` has not run against a real provider in this
  environment because release-eval credentials are absent.
- Any future regression in these already-closed gates should reopen the launch
  blocker: fresh install first run, packaged release boot, product smoke,
  setup/doctor clarity, README/website truth, approval defaults, support-bundle
  redaction, primary-interface happy paths, support path coverage, and release
  artifact checksum/runtime boot verification.

## Acceptable 1.0 Gaps

These can ship if documented:

- Limited OS/package-manager coverage beyond release tarballs.
- Some medium-priority Hermes parity gaps.
- Browser automation marked preview.
- Cron and scheduled automation marked preview for operator-controlled usage.
- Media generation or TTS marked preview or absent.
- Advanced extension marketplace deferred.
- Hosted service deferred.
- Some channel integrations marked experimental.
- One-line remote install script deferred.

## First Execution Batch

The first implementation batch should be small enough to finish without turning
into a general rewrite.

### Batch 1A: Documentation Truth Cleanup

Tasks:

- Add this plan to docs index and catalog.
- Keep stale `ROADMAP.md` references removed unless a real roadmap is restored.
- Check VitePress navigation for missing docs.
- Audit root README for product claims and stale links.
- Audit release docs against actual `mix lemon.update` and release workflows.

Validation:

- `mix lemon.quality`
- docs site build if dependencies are available

### Batch 1B: Launch Gap Ledger

Tasks:

- Convert this checklist into a gap table with owner, status, and priority.
- Link each launch blocker to a file, workflow, command, or issue.
- Mark each parity scorecard gap as launch-blocking or post-1.0.

Validation:

- plan review
- no code required unless stale docs are fixed

### Batch 1C: Fresh Install Probe

Tasks:

- Run setup from a clean environment or container.
- Record missing system dependencies.
- Verify one provider path.
- Verify first agent run.
- Capture every friction point.

Validation:

- documented install transcript
- setup docs patch
- doctor improvements if needed

### Batch 1D: Product Smoke Upgrade

Tasks:

- Extend product smoke to check the full profile web health endpoint. Done.
- Add a representative control-plane request that is not only `/healthz`. Done:
  product smoke now submits a deterministic `echo` agent run through WebSocket
  and waits for completion through `agent.wait`.
- Make memory search expectations explicit per profile. Done for CI scope:
  product smoke no longer claims or probes unimplemented memory search behavior;
  memory behavior remains covered by focused tests and eval lanes.
- Ensure release logs upload on failure.

Validation:

- product-smoke workflow
- release-smoke workflow

## Ownership Model

Suggested ownership lanes:

| Lane | Owns |
| --- | --- |
| Product | positioning, website, feature matrix, launch checklist |
| Runtime | setup, doctor, release profiles, update, health checks |
| Harness | tool lifecycle, memory, skills, delegation, evals |
| Interfaces | TUI, web, Telegram, channel rendering |
| Support | support bundle, troubleshooting, issue templates |
| Docs | docs catalog, README, docs site, changelog |
| Security | approval defaults, secrets, untrusted content, support redaction |

## Success Metrics

Quantitative:

- fresh install to first run in under 15 minutes for a technical user
- release artifact boots in CI and locally
- product smoke passes on every release candidate
- zero known secret leaks in support bundle paths
- zero high-priority parity gaps
- docs site builds successfully
- setup/doctor failure messages link to docs

Qualitative:

- Users can describe what Lemon is after reading the homepage.
- Users can recover from common setup errors without asking a maintainer.
- Maintainers can triage issues from diagnostics.
- Contributors can add features without violating architecture boundaries.
- Agent behavior feels reliable across multi-step tasks.

## Open Decisions

No local launch-positioning decisions are currently open. The remaining launch
work is evidence collection: public release artifact proof and provider-backed
live eval proof.

## Recommended Next Step

Publish the `v2026.05.0` GitHub Release after maintainer approval, watch the
specific release workflow run with `gh run watch {run-id} --exit-status`, run
`scripts/verify_github_release_artifacts 2026.05.0`, run `scripts/test live-eval`
with release-candidate credentials or dispatch `.github/workflows/live-eval.yml`,
then rerun `scripts/audit_1_0_readiness 2026.05.0 {artifact-directory}`.
