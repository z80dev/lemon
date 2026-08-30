# Lemon ↔ Hermes Functionality and UX Gap Audit

Status: current rolling audit; refreshed 2026-08-30. This supersedes the
findings in the original 2026-08-11 revision of this file. The May
[feature matrix](lemon-hermes-feature-parity-matrix-2026-05-12.md) is retained
as historical evidence, not current upstream truth.

## Source baseline and reproducibility

The focused [runtime functionality audit](../reviews/hermes-runtime-functionality-audit-2026-08-30.md)
records the implementation evidence for durable same-session heartbeats and
the remaining harness-level gaps found during this refresh.

This refresh uses official upstream source and documentation, not a local
Hermes checkout:

- Hermes repository: [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
- Hermes `main`: [`4f22543509d1b91dc45bcb369447126c5eb14fb7`](https://github.com/NousResearch/hermes-agent/commit/4f22543509d1b91dc45bcb369447126c5eb14fb7),
  committed `2026-08-30T09:03:57-07:00`
- Hermes product version: `v0.20.6`, from the pinned
  [`pyproject.toml`](https://github.com/NousResearch/hermes-agent/blob/4f22543509d1b91dc45bcb369447126c5eb14fb7/pyproject.toml)
- Official docs: [documentation home](https://hermes-agent.nousresearch.com/docs/),
  [curated machine index](https://hermes-agent.nousresearch.com/docs/llms.txt),
  and the pinned
  [`website/docs`](https://github.com/NousResearch/hermes-agent/tree/4f22543509d1b91dc45bcb369447126c5eb14fb7/website/docs)
- Lemon source: `64092542f523c24b032a0789516a5366a943ac8a`
- Observation date: `2026-08-30`

The upstream snapshot contains 436 tracked files under `website/docs`.
[`hermes-upstream-baseline.json`](hermes-upstream-baseline.json) records these
values in machine-readable form. Run
`scripts/verify_hermes_parity_sources` for the deterministic repository check,
or `scripts/verify_hermes_parity_sources --remote` when intentionally refreshing
the audit. Remote mode fails when official `main` has moved so a changing target
cannot silently become a supposedly current comparison.

The older local checkouts observed during this refresh were stale and were not
used as authority. Hermes changes quickly; every upstream source link below is
therefore either an official live documentation URL or a permalink at the exact
commit above.

## Scope and status vocabulary

This audit asks a user-centered question: “What non-transport work can a Hermes
user do, and can a Lemon user complete the same job with comparable setup,
discoverability, safety, and lifecycle support?” Messaging-platform count is
deliberately excluded for now. Features incidental to a channel, such as voice
mode or session handoff, remain in scope when they are general product
functionality.

Statuses mean:

- **Parity+** — Lemon covers the job and has a meaningful additional advantage.
- **Near** — core behavior exists; remaining differences are bounded UX or edge
  cases.
- **Partial** — useful primitives exist, but a normal user cannot complete the
  whole Hermes workflow through a coherent supported surface.
- **Missing** — no supported end-to-end Lemon workflow was found.
- **Different** — both products solve the problem, with materially different
  strengths; neither is a drop-in substitute.

Priority is the Lemon product gap, not a judgment about upstream quality:
**High** blocks the “anything I can do in Hermes” goal for common daily use;
**Medium** is important but can follow the product spine; **Low** is specialized
or intentionally deferrable.

## Executive verdict

Lemon is no longer missing the central harness mechanics highlighted on
2026-08-11. It now has programmatic tool calling, progressive tool disclosure,
three-way interruption, live provider and credential failover, and the cron
quality features that audit proposed. Those are real closures, not roadmap
claims.

The remaining difference is chiefly **product integration**. Hermes packages a
broad runtime behind one installer, one extensive CLI, a native desktop, a
machine-management dashboard, profiles presented as durable specialist bots,
rich session lifecycle commands, and unusually thorough user documentation.
Lemon exposes a strong BEAM runtime, TUI, control plane, automation, memory,
skills, browser, media, and node execution, but many capabilities are source-only,
preview-only, split across Mix tasks and JSON-RPC, or absent from the Web and
packaged CLI. Matching a Python module is no longer the main task; making the
whole system legible and operable by a new user is.

## Corrections to the 2026-08-11 audit

These old gaps are closed or materially changed at the Lemon baseline. They
must not be copied into new plans.

| Old finding | Current Lemon evidence | Current boundary |
| --- | --- | --- |
| No programmatic tool calling | [`execute_code.ex`](../../apps/coding_agent/lib/coding_agent/tools/execute_code.ex) provides bounded Python RPC over an allowlist; [usage docs](../tools/execute-code.md) cover per-call and persistent kernels. | Disabled by default and its allowlist is smaller than the whole tool catalog, but the mechanism exists end to end. |
| No progressive tool disclosure | [`tool_disclosure.ex`](../../apps/coding_agent/lib/coding_agent/tool_disclosure.ex) freezes a session catalog and substitutes `tool_search`/`tool_invoke` when schema cost crosses the configured budget. | Built-ins stay visible; deferred MCP/extension/WASM tools still pass the normal policy and approval path. |
| No redirect interruption | [`AbortSignal`](../../apps/lemon_agent/lib/lemon_agent/abort_signal.ex), the [streaming loop](../../apps/lemon_agent/lib/lemon_agent/loop/streaming.ex), and [`CodingAgent.Session`](../../apps/coding_agent/lib/coding_agent/session.ex) implement redirect while preserving completed tool results and degrading to steer during tool execution. | Local native runs support it. Remote named-node steering/redirect remains an explicit boundary. |
| Provider fallback was only a preview ordering | [`ProviderRouting`](../../apps/lemon_agent/lib/lemon_agent/model_runtime/provider_routing.ex) builds route candidates; [`ProviderFallback`](../../apps/coding_agent/lib/coding_agent/session/provider_fallback.ex) executes per-turn provider and credential failover with cooldowns and session pinning. | Runtime resilience is implemented; self-service pool/fallback administration is still weak. |
| No same-provider credential rotation | [`ProviderPoolRotator`](../../apps/lemon_agent/lib/lemon_agent/model_runtime/provider_pool_rotator.ex) and session fallback implement pool rotation; [live test guidance](../testing.md) covers invalid-to-valid credential proof. | No Hermes-like `auth`/pool management UX in the packaged CLI or Web. |
| Cron lacked monitor mode, command jobs, chaining, drift guard, and preflight | [`CronManager`](../../apps/lemon_automation/lib/lemon_automation/cron_manager.ex), [`CronMonitor`](../../apps/lemon_automation/lib/lemon_automation/cron_monitor.ex), [`CronContext`](../../apps/lemon_automation/lib/lemon_automation/cron_context.ex), [`CronPreflight`](../../apps/lemon_automation/lib/lemon_automation/cron_preflight.ex), and [`CronCommandRunner`](../../apps/lemon_automation/lib/lemon_automation/cron_command_runner.ex) implement all five. [`Blueprint`](../../apps/lemon_automation/lib/lemon_automation/blueprint.ex) now adds one exact-confirmed skill + agent-cron template vertical. | Blueprint suggestions/catalog UX, richer template shapes, and a simple recurring `/loop` UX remain gaps. |
| Multi-engine execution was a Lemon advantage | Lemon deliberately removed vendor-CLI engines and now has one native supervised executor with provider/model routing and in-process subagents. | This is a simplification and reliability choice, not a current multi-engine differentiator. |

## Functionality and product gap matrix

### Product spine: installation, CLI, desktop, Web, and sessions

| User job | Hermes at pinned upstream | Lemon at pinned baseline | Status | Priority | Concrete next closure |
| --- | --- | --- | --- | --- | --- |
| Install on a supported computer and reach first chat | The [installer](https://hermes-agent.nousresearch.com/docs/getting-started/installation) covers one-line shell, PowerShell/native Windows, desktop installers, WSL, Nix/NixOS, Termux, Docker, and setup entry. Quick Portal setup can authorize model plus hosted search/image/TTS/browser services through one account; see pinned [quickstart](https://github.com/NousResearch/hermes-agent/blob/4f22543509d1b91dc45bcb369447126c5eb14fb7/website/docs/getting-started/quickstart.md). | [Install Lemon](../install.md) now provides verified one-line release installation, idempotent setup, and a first-TUI readiness gate for macOS and Linux artifacts. Provider credentials are configured individually; Linux requires the documented glibc baseline. No native Windows, Nix, Android, or desktop installer. | Partial | **High** | Add a platform-aware launcher UX, native Windows or an explicit supported WSL path, broader Linux compatibility, and an optional bundled account/OAuth path for a useful no-key first run. |
| Discover and administer the product from one CLI | Hermes documents roughly sixty top-level families in its pinned [CLI reference](https://github.com/NousResearch/hermes-agent/blob/4f22543509d1b91dc45bcb369447126c5eb14fb7/website/docs/reference/cli-commands.md): chat, models/fallback/MoA, sessions, cron, profiles, skills, memory, approvals, backups, updates, logs, plugins, MCP, completions, and more. | Packaged [`LemonCli.CLI`](../../apps/lemon_cli/lib/lemon_cli/cli.ex) has seven families: setup, model, gateway, doctor, config, secrets, channels. Source `bin/lemon` adds node, send, media, model/provider inspection, policy, proofs, readiness, skill, usage, and update through Mix tasks. TUI commands cover additional runtime functions, but there is no single stable command map. | Partial | **High** | Promote the supported runtime surfaces into the packaged CLI, with consistent help, JSON output, exit codes, shell completions, and a generated reference. |
| Use a polished native daily-agent interface | The pinned [Desktop guide](https://github.com/NousResearch/hermes-agent/blob/4f22543509d1b91dc45bcb369447126c5eb14fb7/website/docs/user-guide/desktop.md) covers onboarding, tabs/panes, chat, artifacts, files, terminal, git/worktrees, reviews, memory, voice, settings, plugins, multi-profile concurrency, and remote connections. | Lemon has a capable Bun TUI, a session LiveView, JSON-RPC clients, and LemonSim UI. It has no native desktop product or a single interface that composes files, terminal, artifacts, git review, memory, settings, and remote connections. | Missing | **High** | Choose and ship a desktop/product-shell strategy. A wrapper is useful only if it owns onboarding, connection management, updates, file/artifact UX, and settings—not merely a WebView around chat. |
| Create durable specialist agents and collaborate among them | [Bot Mode](https://hermes-agent.nousresearch.com/docs/user-guide/bot-mode) presents profiles as bots with independent config/model/memory/skills/SOUL, canonical chats, cron routines, DMs, groups, cross-machine roster, and remote creation. Profiles also have full [CLI lifecycle](https://hermes-agent.nousresearch.com/docs/reference/profile-commands). | Lemon has named agents/personas, native child sessions, router delegation, kanban, agent inboxes, and authenticated named execution nodes. It does not offer isolated user-managed agent homes, profile create/clone/export/delete, canonical bot chats, a roster, or group-room UX. | Partial | **High** | Define a first-class profile record over existing agent/node primitives, including isolated config/memory/skills, create/clone/export lifecycle, canonical chat, and TUI/Web roster before attempting group rooms. |
| Manage several local or remote runtimes from one client | Hermes Desktop registers local, URL, SSH, Docker, and cloud connections and merges their agent rosters; see [multi-connection Desktop](https://hermes-agent.nousresearch.com/docs/user-guide/multi-connection-desktop). | Lemon's authenticated named nodes are stronger as native remote execution workers and have real name-based routing, cancellation, pairing, and presence. The TUI/Web do not provide a multi-controller connection registry or merged agent/session roster. | Different | **High** | Preserve Lemon's execution-node advantage, then add connection profiles, health/re-auth UX, and a merged node/agent/session picker. |
| Administer a machine in the browser | Hermes's [Web Dashboard](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard) manages profiles, real TUI chat, status/resources, a large config surface, credentials, sessions, models, skills, MCP, pairing, webhooks, gateways, memory, cron, plugins, logs, and analytics. | [`LemonWeb.Router`](../../apps/lemon_web/lib/lemon_web/router.ex) now has a fail-closed token-required `/manage` shell for runtime health, sanitized live-node presence, and durable session operations, alongside chat and `/healthz`. Provider credentials/pools, approvals, cron, skills/MCP, memory, logs, and config do not yet have equivalent Web journeys. | Partial, first vertical shipped | **High** | Extend the authenticated shell one existing service at a time: providers/credentials, approvals, cron, skills/MCP, memory, logs, and config. Keep each mutation scoped and browser-tested. |
| Browse, search, resume, export, archive, and safely prune sessions | Hermes [sessions](https://hermes-agent.nousresearch.com/docs/user-guide/sessions) support workspace-aware resume, rename/pin/archive/read state, FTS search, rich filtering, lineage, redacted JSONL/HTML/Markdown/QMD/trace exports, verified delete-after-export, prune, handoff, recovery, and recap. | `LemonCore.SessionLifecycle` now composes the canonical stores for bounded search, title/pin/archive, redacted JSON/Markdown export, verified delete, and exact-candidate guarded prune. Web supports list/search/inspect/resume/export/mutation/prune, and authenticated control-plane RPCs expose the redacted lifecycle. TUI and packaged CLI do not yet expose the shared lifecycle; lineage, handoff, recovery, recap, read state, and richer formats remain gaps. | Near in service/Web; partial cross-client | **High** | Reuse the shared lifecycle in TUI and packaged CLI, then add lineage/read state and recovery/backup semantics without introducing another store. |

### Agent runtime, models, tools, context, and media

| User job | Hermes at pinned upstream | Lemon at pinned baseline | Status | Priority | Concrete next closure |
| --- | --- | --- | --- | --- | --- |
| Configure models, auth pools, fallback, and per-task routing | Hermes has interactive provider/model setup, OAuth credentials, credential pools, ordered fallbacks, auxiliary task models, provider routing, custom endpoints, and selectable [Mixture of Agents](https://hermes-agent.nousresearch.com/docs/user-guide/features/mixture-of-agents) presets. The [provider catalog](https://hermes-agent.nousresearch.com/docs/integrations/providers) is user-facing. | Lemon supports a broad provider set, custom endpoints, model catalogs, per-session resolution, live provider fallback, credential pools, cooldowns, and route preview. Setup can configure a provider and default model. Pool/fallback editing is not a cohesive end-user workflow; MoA reference fan-out/presets are absent. | Near at runtime; partial in UX | **High** | Ship `lemon auth`, `lemon fallback`, and pool commands plus equivalent Web forms and health proof. Treat MoA as a separate opt-in orchestration feature with cost/budget visibility. |
| Interrupt, steer, or redirect a running agent | Hermes distinguishes hard interrupt, non-canceling steer, and model-request redirect. | Lemon implements the same local-native semantics through router queue modes, `CodingAgent.Session`, and `LemonAgent.Loop`. | Near | Medium | Expose all three consistently in every client and carry steer/redirect over named-node invocation rather than falling back at the remote boundary. |
| Avoid context bloat from large tool catalogs and intermediate data | Hermes documents [Tool Search](https://hermes-agent.nousresearch.com/docs/user-guide/features/tool-search), [`execute_code`](https://hermes-agent.nousresearch.com/docs/user-guide/features/code-execution), result offloading, and multiple compaction paths. | Lemon has frozen progressive disclosure, `execute_code`, output truncation/blob offload, context guardrails, summarization/hybrid compaction, overflow recovery, and cache-stable tool catalogs. | Near | Medium | Enable and explain safe defaults, widen the execute-code allowlist based on policy, and add live compaction/cost observability rather than another mechanism. |
| Browse and operate the Web or desktop | Hermes exposes local/cloud browser providers, browser profiles, computer use, screenshots, and document/deliverable workflows in its [tools overview](https://hermes-agent.nousresearch.com/docs/user-guide/features/tools). | Lemon has a deep supervised browser driver, CDP/Playwright client, route policy, downloads/uploads, events/cookies/state, screenshots, image analysis, artifacts, and a `computer_use` tool. | **Parity+** for browser automation; partial for integrated desktop use | Medium | Promote one stable browser setup path and surface live driver/session/artifact state in the product UI. Keep computer use separately approval-gated. |
| Attach files and reference repository context naturally | Hermes supports `@file`, `@folder`, `@git-diff`, `@url`, session references, PDF/Office/notebook extraction, and deliverable attachments; see [context references](https://hermes-agent.nousresearch.com/docs/user-guide/features/context-references) and [document extraction](https://hermes-agent.nousresearch.com/docs/user-guide/features/document-extraction). | Lemon agents can read/search files, inspect git through tools, accept Web uploads, and create media artifacts. There is no consistent composer-level reference syntax or general PDF/Office/notebook extraction pipeline. | Partial | Medium | Add a client-independent context-reference resolver with explicit previews/budgets, then safe extractors for PDF, DOCX, XLSX, PPTX, and notebooks. |
| Use voice and multimodal interaction | Hermes provides voice mode, wake word, streaming TTS, voice input, vision, and desktop/gateway integration; see [voice mode](https://hermes-agent.nousresearch.com/docs/user-guide/features/voice-mode). | Lemon has Deepgram STT, TTS/media generation, image analysis, Twilio voice, and media artifacts, but no cohesive push-to-talk/realtime TUI or desktop voice experience and no wake word. | Partial | Medium | Prove one polished voice loop in the primary interface: record, transcribe, editable preview, submit, streaming playback, cancel, and artifact retention. Wake word can remain low priority. |
| Run code in alternate environments | Hermes supports local, Docker, SSH, Singularity, Modal, Daytona, and Vercel-style sandboxes, plus a [terminal-environment plugin API](https://github.com/NousResearch/hermes-agent/blob/4f22543509d1b91dc45bcb369447126c5eb14fb7/website/docs/developer-guide/terminal-environment-plugin.md). | Lemon has local, local PTY, SSH, and Docker terminal backends with policy, plus named execution nodes that run the whole native agent remotely. | Partial | Medium | Stabilize/document existing backends and named-node selection first; add serverless/hibernating environments only behind the existing backend behavior and contract tests. |

### Memory, skills, automation, security, extensions, and operations

| User job | Hermes at pinned upstream | Lemon at pinned baseline | Status | Priority | Concrete next closure |
| --- | --- | --- | --- | --- | --- |
| Keep durable personal and project memory | Hermes combines local USER/MEMORY files, session search, background review/curation, a learning journey, and a broad set of [memory providers](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers). | Lemon has SQLite FTS memory, redaction-aware ingest, provider fan-out, session search, project context, memory tools, scheduled skill synthesis/curation, and a production Honcho integration. Local and Honcho are the implemented providers; adaptive features remain intentionally opt-in. | Near for durable recall; partial for ecosystem/UX | Medium | Add a memory browser with provenance/edit/delete, measure whether safe defaults should enable recall, and prioritize provider conformance over provider count. |
| Teach the agent from a URL, directory, or corpus and inspect what it learned | Hermes exposes `/learn`, curator flows, and the Journey learning graph/timeline. | Lemon synthesizes candidates from finalized runs and can curate/install skills, but has no direct “learn this source” job or learning-graph UI. | Missing | Medium | Build an auditable ingestion job that shows sources, proposed memories/skills, conflicts, and approval before write; visualize the same records rather than inventing a second learning store. |
| Find, audit, install, update, bundle, and distribute skills | Hermes's [skills system](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills) includes a Hub, taps, bundles, a large catalog, publishing, audit, curator, and profile distributions. | Lemon has agentskills-compatible discovery, local/project/builtin precedence, official Hermes catalog import, risk audit, trust metadata, atomic install/update, curator, model-facing management, and MCP-based discovery. Versioned unpacked bundles now reuse those audits for explicit profile-local enablement, with safe catalog list/inspect/validate/preview RPC. Lemon still lacks a signed public registry/index, taps, publishing/export, archive import, and TUI/Web bundle UX. | Near in engine; first bundle vertical shipped, partial in ecosystem | Medium | Add signed index/distribution and export/publish lifecycle, then TUI/Web browse/review/activate UX over the existing bundle service. Do not weaken the unpacked, path-bounded activation policy for archive convenience. |
| Schedule recurring agent and script work safely | Hermes provides cron, heartbeats, recurring [loops](https://hermes-agent.nousresearch.com/docs/user-guide/features/loops), monitor jobs, no-agent scripts, chaining, blueprints, suggestions, preflight, and multiple delivery modes. | Lemon has durable cron, exact timers, jitter/retries/lineage, overlap locks, pause/resume/abort/run-now, heartbeat suppression, monitor mode, command jobs, chaining, preflight, default-model drift guard, goal continuation/auto loops, and kanban dispatch. A versioned agent-cron blueprint now requires an exact plan digest, persists bundle/definition provenance, enables skills in the derived profile workspace, and replays without duplicate jobs through the existing scheduler. | Near in engine; first blueprint vertical shipped, partial in UX | Medium | Add natural-language recurring-loop commands, suggestions, and TUI/Web/packaged CLI blueprint management. Expand beyond one agent cron only when a concrete workflow preserves exact confirmation and existing cron/heartbeat stores. |
| Review dangerous actions and constrain agent execution | Hermes documents smart/manual/off [approvals and security](https://hermes-agent.nousresearch.com/docs/user-guide/security), deny rules, circuit breakers, container isolation, checkpoints, and managed scope. | Lemon has centralized execution approvals, per-node policies, tool policy profiles, structured approval events across interfaces, file/checkpoint guards, URL/SSRF policy, extension capability approvals, redaction, support-bundle cleanup, and proof artifacts. | **Parity+** in auditable policy; partial in enterprise scope | Medium | Add admin-pinned managed settings and a human-readable policy editor. Preserve Lemon's proof/redaction advantages. |
| Keep credentials out of config and remote sandboxes | Hermes resolves credentials from 1Password, Bitwarden, or an arbitrary command and can inject them through an [egress proxy](https://hermes-agent.nousresearch.com/docs/user-guide/egress/iron-proxy) so a remote sandbox never receives the real secret. | Lemon encrypts a local secret store, uses platform key storage or a protected master-key file, supports OAuth token persistence, redacts outputs, and avoids sending resolved provider credentials to named nodes. It has no external secret-source interface or general credential-injecting egress proxy for arbitrary tools. | Partial | **High** | Add a supervised secret-source behavior (1Password/Bitwarden/command implementations) and design an explicit outbound credential-broker boundary for remote/browser/tool workloads. |
| Install extensions and hooks without patching core | Hermes supports typed plugins across providers, memory, browsers, media, cron, observability, platforms, dashboard, and terminal environments, plus hooks and package lifecycle UI/CLI; see [plugins](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins). | Lemon has MCP clients/server bridge, native extension manifests, WASM tools, OAuth-aware remote MCP, capability approvals, conflict rules, supervised hosts, registry metadata, and platform contract tests. Third-party distribution and end-user lifecycle remain preview. | Different | Medium | Finish one signed package/install/update/remove flow with compatibility and capability review, then expose host health in Web/TUI. Do not create a second plugin format for every subsystem. |
| Update, back up, migrate, recover, and uninstall the product | Hermes has update check/plan/backup, receipts, multi-profile restart/version verification, full backup/import, profile distributions, checkpoints, doctor/dump/debug/logs/status/insights, completions, and uninstall commands; see [updating](https://hermes-agent.nousresearch.com/docs/getting-started/updating). | Lemon has release channels and signed checksums, source `lemon update --check`, config/skill migration, a release installer/uninstaller, doctor and redacted support bundles, readiness/proofs, hot reload, and deployment-specific backup guidance. It lacks a coherent data backup/restore/export command, update plan/receipt/rollback, fleet/profile restart, and shell completion. | Partial | **High** | Define the entire `~/.lemon` data contract, then ship atomic backup/verify/restore and update plan/apply/rollback with receipts before adding more updater intelligence. |
| Read task-oriented and machine-readable documentation | Hermes offers structured learning paths, user/task guides, full references, FAQs, edit links, and both curated/full machine indexes. | Lemon's VitePress site builds and has deep architecture/test plans, but navigation favors internal launch artifacts, several user features lack task guides, CLI reference is incomplete, and stale claims persisted in prominent pages. This refresh adds a task-first quickstart plus generated `llms.txt` and `llms-full.txt`. | Partial | **High** | Continue the install → first task → daily use → administration → troubleshooting information architecture, generate CLI/config/tool references, and demote historical plans from the primary navigation. |
| Run deterministic simulations and evaluation arenas | Hermes has batch processing, trajectory export, evaluation skills, and training-oriented Atropos/RL workflows. | LemonSim provides event-sourced worlds, deterministic replay verification, leagues/ratings, hosted observation, benchmark domains, usage persistence, and tamper-evident artifacts. | **Parity+** for simulation/benchmark products; partial for generic trajectory pipelines | Low | Keep LemonSim as the differentiated surface; add standard trajectory export only when a concrete training/eval consumer requires it. |

## Website and documentation audit

Hermes's current docs are not merely larger. They make product capability
discoverable through a stable hierarchy: install and quickstart, learning path,
user guide, feature guides, task recipes, integrations, command/reference
material, FAQ, developer extension guides, and machine-readable indexes. Most
major capabilities link in both directions between concept, task, CLI, and
configuration reference.

At the Lemon baseline:

1. The VitePress site is real and build-checked, but prominent navigation mixes
   current user docs with dated launch plans and a historical May matrix.
2. The home page still described removed vendor-CLI “multi-engine” execution
   and still characterized binary installation as future work.
3. `compare.md` listed shipped provider fallback, cron, goal, kanban, LSP,
   browser, media, checkpoint, API, and ACP capabilities as future targets.
4. The old feature matrix claimed a removed Web `/ops` surface. The current
   router instead provides a focused token-required `/manage` session vertical;
   historical `/ops` claims remain invalid and should not be restored.
5. Lemon has strong implementation documents for many tools but lacks a complete
   user-facing CLI reference, session guide, automation guide, Web guide,
   provider/auth guide, node guide, extension install guide, and task-recipe
   layer.
6. Lemon exposed no concise task-first quickstart and no `llms.txt` or
   `llms-full.txt`. This refresh adds the quickstart, generated site assets, and
   a stale-output check; run `scripts/generate_docs_llms.py` after changing
   included documentation.

The right response is not to copy 436 files. It is to make every promoted Lemon
workflow have four connected pieces: a task guide, stable interface reference,
configuration/security notes, and a troubleshooting path. Internal proof plans
remain valuable evidence but should not be the first page a new user sees.

## Prioritized implementation bundles

These are intentionally vertical bundles rather than isolated modules.

### High: product shell and daily operation

1. **Management Web vertical** — the authenticated shell, runtime/live-node
   health, and complete session slice are implemented over shared services.
   Continue with providers/credentials/fallback pools, approvals, cron,
   skills/MCP, memory, logs, and config, with real browser tests per slice.
2. **Packaged CLI convergence** — promote supported source-only and TUI-only
   operations into `LemonCli.CLI`; consistent help/JSON/errors; generate the
   reference and completions from the command registry.
3. **Profile/bot primitive** — isolated homes and capability config; create,
   clone, rename, export, delete; canonical chat; agent/node roster. Add group
   rooms only after this lifecycle is boring and reliable.
4. **Session lifecycle** — the shared service, authenticated RPC, and Web are
   implemented with redaction and verified-before-delete. Surface the same API
   in TUI and packaged CLI; then add lineage/read state/recovery rather than a
   parallel store.
5. **Install/update/backup** — widen supported installation, add update
   plan/apply/rollback receipts, and make backup/restore cover the documented
   data contract.
6. **Secret sources and outbound credential boundary** — external secret
   providers plus credential brokerage for arbitrary remote/browser/tool
   execution.

### Medium: capability completion and polish

7. Provider/auth/pool/fallback management UI and an opt-in cost-bounded MoA
   design.
8. Auditable learn-from-source ingestion and a memory/learning inspection UI.
9. **Skill distribution** — the first versioned unpacked bundle and
   profile-local enablement slice is implemented over the existing skill
   registry/audit. Continue with signed indexing, export/publish, and TUI/Web
   review without adding another store.
10. **Automation templates** — the first exact-confirmed, duplicate-safe
    skill + agent-cron blueprint is implemented over `CronManager`. Continue
    with natural-language loops, suggestions, and management surfaces; keep
    command or multi-job expansion separately justified and explicitly
    confirmed.
11. Composer context references and document extraction with preview and budget
    controls.
12. One polished voice workflow in the primary interface.
13. Extension package lifecycle and host-health UX.
14. Remote steer/redirect plus multi-controller connection management.

## Lemon advantages to preserve

Parity work should not flatten the areas where Lemon is already a stronger
substrate:

- OTP supervision, isolated processes, restart recovery, typed events, hot
  reload, and runtime introspection.
- Authenticated named execution nodes that route the native agent itself—not
  merely SSH or terminal commands—to destination-local files and credentials.
- Deterministic LemonSim arenas, replay verification, ratings, benchmark worlds,
  and tamper-evident artifacts.
- Central approvals, policy-aware extension execution, redacted observability,
  support bundles, and proof artifacts.
- Native in-process subagents with budget inheritance and parent/child run
  lineage.
- Contract-test kits and architecture-boundary checks for platform packages.
- Current harness closures: execute-code RPC, progressive tool disclosure,
  redirect, provider/credential failover, browser automation, and high-quality
  cron internals.

The standard for new parity work is therefore “Hermes-level user completion,
with Lemon-level supervision and proof,” not surface-count imitation.

## Official Hermes source map

- [Docs home](https://hermes-agent.nousresearch.com/docs/)
- [Machine-readable docs index](https://hermes-agent.nousresearch.com/docs/llms.txt)
- [Installation](https://hermes-agent.nousresearch.com/docs/getting-started/installation)
- [CLI reference](https://hermes-agent.nousresearch.com/docs/reference/cli-commands)
- [Desktop](https://hermes-agent.nousresearch.com/docs/user-guide/desktop)
- [Bot Mode](https://hermes-agent.nousresearch.com/docs/user-guide/bot-mode)
- [Web Dashboard](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard)
- [Sessions](https://hermes-agent.nousresearch.com/docs/user-guide/sessions)
- [Tools](https://hermes-agent.nousresearch.com/docs/user-guide/features/tools)
- [Memory](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory)
- [Skills](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills)
- [Cron](https://hermes-agent.nousresearch.com/docs/user-guide/features/cron)
- [Security](https://hermes-agent.nousresearch.com/docs/user-guide/security)
- [Plugins](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins)
- [Updating](https://hermes-agent.nousresearch.com/docs/getting-started/updating)
