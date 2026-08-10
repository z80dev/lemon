# Lemon Platform Split — Plan of Record

Status: **v2 — open questions resolved, execution plan set** · Started 2026-08-09, decisions resolved 2026-08-09 with code-level investigation (see Evidence). Living document: append to the Decision Log as work lands; check off work items in place.

## 1. Goal

Reshape Lemon from a 22-app umbrella (~415k LOC) into a **platform for building BEAM agents**:

- The `lemon` repo publishes a small set of hex packages with deliberate, semver'd public APIs, plus a batteries-included reference runtime.
- Products (coding agent, sim arenas, tcg, showcase, TS clients) live in their own repos and consume hex releases exactly as a third party would.
- Third-party builders get: documented extension behaviours, a contract-test kit, `mix lemon.new`, and getting-started docs written for *their* agent, not ours.

## 2. Target architecture

### Published packages (from the `lemon` platform repo)

| Package | Contents | Source today | Publish order |
|---|---|---|---|
| `lemon_ai` | Provider-agnostic LLM client: providers, registry, rate limiting, circuit breaker, compaction, tokens/text | `apps/ai` (31k, zero umbrella deps) | 1 |
| `lemon_core` | The platform's shared language: Bus, Event envelope, Store (+backends), Secrets, Config loader, boundary contracts (`RunRequest`, `ExecutionCommand`, `InboundMessage`, `DeliveryIntent`, `EngineRuntime`, `RouterBridge`, `SessionKey`, `ResumeToken`, run phases), primitives (clock/id/retry/telemetry/idempotency), Extensions manifest | slimmed `apps/lemon_core` | 2 |
| `lemon_agent` | Agent loop, tool registry, subagents, model runtime, CLI runners, workspace stores (goals/kanban/heartbeats) | `apps/agent_core` + 3 stores from lemon_core | 3 |
| `lemon_memory` | Durable agent memory: document schema, store, provider behaviour + fan-out registry, ingest pipeline, search, task fingerprints | 8 modules from lemon_core (~1.9k LOC) | 4 |
| `lemon_router` | Run lifecycle + session orchestration: single-flight, queue/steer, coalescing, policy, watchdog, delivery routing | `apps/lemon_router`, facade hardened | 5 |
| `lemon_gateway` | Engine execution runtime only: `Engine` behaviour, engine registry/scheduler/locks, `EngineRuntime` impl | `apps/lemon_gateway` minus transports/sms/voice | 5 |
| `lemon_channels` | Channel core (Registry, Outbox, Dispatcher, PresentationState) + `Plugin` behaviour + built-in adapters (telegram, discord, whatsapp, xmtp, email, farcaster, webhook) | `apps/lemon_channels` + gateway's transports | 5 |
| `lemon_platform_test` | Contract-test kit: behaviour compliance suites for Plugin/Engine/StoreBackend/MemoryProvider authors | new | 6 |

Satellite (separate small repos/packages, the model for all vendor integrations): `x_api` (X client + its channel adapter + its 3 skills tools, self-registering).

### Stays in the platform repo, unpublished initially

`lemon_control_plane`, `lemon_cli`, `lemon_web`, `lemon_automation`, `lemon_skills` (minus X tools), `lemon_media`, `lemon_browser`, `lemon_lsp` — these form the **reference runtime** ("lemon server") that wires the published packages together. Publish later if demand appears; being in-repo keeps their API churn cheap.

### Product repos (extracted, consume hex releases)

| Repo | Takes | Why grouped |
|---|---|---|
| `coding-agent` | `coding_agent`, `coding_agent_ui`, `lemon_mcp`, `lemon_evals` | mcp + evals compile-depend on coding_agent |
| `lemon-sim` | `lemon_sim` (incl. Bench), `lemon_sim_ui`, `lemon_tcg` | tcg needs sim's Kernel/LLM engines; sim_ui needs everything. **Flagship demo repo** (D8) |
| `showcase` | `showcase/` static site | |
| `lemon-clients` | `clients/` TS packages | different toolchain |

### Dependency rules (enforced, see Phase 3)

```
lemon_ai ← lemon_agent ← {router, gateway, channels, skills, products}
lemon_core ← everything
lemon_memory ← {router (ingest hook), skills, products}
router ⇄ gateway: ONLY via LemonCore.EngineRuntime behaviour (config-injected)
channels → router: ONLY via LemonCore.RouterBridge
router → channels: Dispatcher/Outbox facade only (the one allowed compile-time edge)
products/satellites → platform: hex deps; platform NEVER depends on a product
```

## 3. Evidence (investigations of 2026-08-09)

Full details in agent reports; key facts the plan relies on:

**E1 — Store/lemon_core publishability audit.** `LemonCore.Store` is an application singleton, not a library: `name: __MODULE__` hardcoded (`store.ex:40-42`), config read from `:lemon_core` app env ignoring `start_link` opts (`store.ex:472-478`), ReadCache uses fixed *public named* ETS tables that fail open on collision (`store/read_cache.ex:38-49`). Domain coupling in the hot path: `finalize_run` calls `RunHistoryStore.put/4` and `MemoryIngest.ingest/3` directly (`store.ex:906,914`); Telegram msg-id indexing at `store.ex:1048`; policy/session/telegram tables baked in (`store.ex:28-38`). Deps: `sentry` + `finch` + `exqlite` are **non-optional** (`apps/lemon_core/mix.exs:27-42`); `uuid ~> 1.1` unmaintained. Secrets crypto is sound (AES-256-GCM + HKDF) but key provisioning is macOS-Keychain-first with no non-macOS init path (`secrets/master_key.ex:47-61,216-224`). Backend behaviour itself (`store/backend.ex`) is clean and genuinely pluggable.

**E2 — Bench extraction assessment.** Bench is only 2,857 LOC (~2.9% of lemon_sim), filesystem-only persistence, and near-zero coupling to sim internals — but its `Domains` registry hardcodes ~21 `LemonSim.Examples.*` module pairs (`bench/domains.ex:48+`), and **no consumer wants Bench without the sim**: lemon_tcg uses zero Bench (it uses `LemonSim.Kernel.*` + `LLM.*` engines), lemon_sim_ui uses ~9 `League`/`Domains` functions but also the kernel and five game engines. Extraction would add graph nodes for no consumer gain.

**E3 — router/gateway/channels topology.** The three apps already communicate almost entirely through indirection: router→gateway has *zero* compile-time references (behaviour injection via `LemonCore.EngineRuntime`, 4 callbacks, bound in `config/config.exs:36`); channels→router and gateway→router go through `LemonCore.RouterBridge`; the only compile-time edge is router→channels (Dispatcher/Outbox). CI already polices boundaries (`lemon_core/quality/architecture_rules_check.ex:37-51`). Blemishes: gateway hosts 5.1k LOC of email/farcaster/webhook transports + sms/voice that duplicate the channels concept under a **second** transport behaviour (`LemonGateway.Transport` vs `LemonChannels.Plugin`); channels/control_plane reach back into gateway via dynamic atoms (`lemon_channels/gateway_config.ex:4`, `engine_registry.ex:13`, `control_plane/methods/transports_status.ex:139`); control_plane leaks router internals (`RunRegistry`, `RunSupervisor`, `RunOrchestrator` — 5 call sites). Gateway's coding_agent dep is 12 refs in 4 files: the in-process "lemon" engine shim (`engines/lemon.ex`, `engines/lemon/session_runner.ex`) plus `CodingAgent.Config.workspace_dir/0` and `CodingAgent.Security.ExternalContent`.

**E4 — misc.** License is MIT (hex-compatible). Hex names `lemon`, `lemon_core`, `lemon_ai`, `lemon_agent`, `lemon_runtime`, `lemon_bench`, `lemon_memory`, `lemon_channels` all unclaimed as of 2026-08-09. `LemonChannels.Plugin` (6 callbacks, worked example in moduledoc, runtime registration via `Application.register_and_start_adapter/2`) is the best extension point in the tree. control_plane uses 7 CodingAgent surfaces, all ops-introspection (TaskStore, SessionRegistry, Session.compact, Extensions, RunGraph, Wasm.SidecarSupervisor, skills paths).

## 4. Resolved decisions

| # | Decision | Rationale |
|---|---|---|
| **D1** | **No merged `lemon_runtime` package.** Router, gateway, channels stay separate packages; the name `lemon_runtime` is retired. | E3: router↔gateway is already a published-package-quality boundary (behaviour-injected, zero compile refs). Merging destroys the cleanest seam in the tree. |
| **D2** *(amended 2026-08-10)* | **Gateway sheds only what is actually a channel.** Original D2 ("all five move to Plugin, Transport behaviour deleted") was not supportable: only email/farcaster/webhook implement `LemonGateway.Transport` (SMS/voice never did); `Plugin.deliver/1` is fire-and-forget and cannot return a synchronous HTTP response into the originating request (webhook sync-mode, farcaster frames); channels has zero HTTP-server infrastructure; and all ~7.9k LOC is dead-by-default (`:legacy_ingress_enabled` false, `:transports` `[]`). Amended: **port email** to Plugin (genuine fit, needs new `LemonChannels.InboundHttp`); **webhook + SMS stay in gateway** as non-channel ingress; **voice deferred**; **farcaster pending user decision** (delete vs keep). Prior art: `docs/plans/gateway-channels-transport-migration.md` (2026-07-07) reached the same conclusion; re-verified 2026-08-10. Full analysis: `docs/platform/transport-unification.md`. | Enlarging Plugin (sync-response/idempotency/queue-override) to serve non-channel surfaces would bloat the platform's most third-party-facing extension point. |
| **D3** | **Bench stays inside lemon_sim** and leaves with it. In the sim repo, move the wiring modules (`bench/domains.ex`, the three registries) out of `bench/` into a `LemonSim.BenchDomains` namespace and inline `stable_json`, so `bench/` has zero `Examples.*` references. Extract to `lemon_bench` only when a second consumer appears. | E2: exactly one dependent, which needs full lemon_sim anyway. Extract on the second consumer, not the first. |
| **D4** | **`lemon_memory` becomes its own published package** (memory_document, memory_store, memory_provider behaviour, memory_providers registry, memory_ingest, memory_safety, session_search, task_fingerprint). | Coherent ~1.9k LOC domain, has a behaviour, 3+ consumers, MemoryStore is already `:name`-parameterized. Durable memory is a headline platform feature. |
| **D5** | **goal_store / kanban_store / heartbeat_store move to `lemon_agent`** under an `AgentCore.Workspace.*` namespace. | They are multi-agent work coordination built purely on core primitives; every consumer (automation, channels, skills, control_plane) already depends on agent_core. Keeps slim core product-free without inventing a fourth package. |
| **D6** | **Store gets library-ified before publish** (see Phase 1 items); sentry/finch/exqlite become optional deps; `uuid` replaced with a vendored UUIDv7 or `uniq`. | E1. Non-negotiable for a package third parties embed. |
| **D7** | **x_api becomes the model satellite integration**: its own repo/package containing the X client, the channels adapter (`adapters/x_api*` moves there), and the 3 X skills tools (`get_x_mentions`, `x_search`, `post_to_x` move out of lemon_skills). It self-registers via the Plugin/tool registration APIs. Platform loses all compile-time knowledge of X. | Proves the extension story with a real integration; kills two wrong-direction deps at once. |
| **D8** | **lemon-sim is the flagship demo repo.** | Cleanest dependency profile (core+agent+ai only) = the best advertisement that the platform seam works; arenas are the most visually compelling artifact. |
| **D9** | **control_plane↔coding_agent inversion via method-provider registration**: control_plane exposes a `MethodProvider` registration API; coding_agent registers its ops methods (tasks_*, sessions_*, extensions_status, skills_status, run_graph, wasm status) at boot. Same pattern as channel adapters. | E4: all 7 usages are ops-introspection methods — a registry fits better than 7 behaviours. |
| **D10** | **Versioning**: umbrella calver stays for the repo; each published package starts at `0.1.0` semver at first publish, `1.0.0` only after the extraction (Phase 5) has proven the APIs. Hex names reserved at Phase 0. MIT license confirmed. | Freedom to break APIs while the only consumers are our own repos. |

## 5. Execution plan

Phases are ordered by dependency; items within a phase are parallelizable unless noted. Sizes: S (≤1 day), M (days), L (week+).

### Phase 0 — Groundwork (S)

- [ ] **0.1** Reserve hex package names: publish `0.0.1` placeholder releases of `lemon_ai`, `lemon_core`, `lemon_agent`, `lemon_memory`, `lemon_router`, `lemon_gateway`, `lemon_channels`, `lemon_platform_test` (names verified free 2026-08-09).
- [x] **0.2** ~~Add `boundary` or~~ Extended `architecture_rules_check.ex` (AST-based `@module_reference_rules`, catches dynamic atoms) with 5 rules + 29-entry shrink-only `@grandfathered` allowlist grouped by the Phase 2 item that retires each group. Found+grandfathered one unknown violation: `lemon_automation/cron_manager.ex:479` uses `LemonRouter.RunRegistry` (retire in 2.6). Runs in existing `mix lemon.quality` lane. *(2026-08-10)*
- [x] **0.3** `docs/platform/` skeleton created (8 package stubs), cataloged in `docs/catalog.exs`. *(2026-08-10)*

**Done when:** names reserved; CI red on any new cross-boundary reference.

### Phase 1 — Carve `lemon_core` (L; the critical path)

Store library-ification (from E1, all in `apps/lemon_core`):

- [x] **1.1** Done: server-first optional arg (`def get(server \\ __MODULE__, ...)`; explicit higher-arity clauses where trailing opts made defaults ambiguous). Opts-first config with app-env fallback; `:store_runtime_override` deliberately applies only to the default instance; per-instance RunHistoryStore sqlite filenames. *(2026-08-10)*
- [x] **1.2** Done: ReadCache rewritten — per-store table sets, table refs (no hot-path atom derivation), ownership-based collision rule (claim only if owner is self() or the store's registered process; else raise `CollisionError`). 14-test `store_instance_test.exs` proves two stores + caches isolated in one node. *(2026-08-10)*
- [x] **1.3** Done: `Store.Hooks` (`store/hooks.ex`) — finalize_run invokes registered `{m,f,args}` hooks with failure isolation; runtime registrations live in `:persistent_term` keyed by store name so they survive store restarts. RunHistoryStore + MemoryIngest register themselves via config (each owns its `handle_finalize_run` adapter, so it moves with the module in 1.6). Read path inverted too: `get_run_history` forwards to a configured `:run_history_provider`. Telegram msg-id indexing at store.ex:1048 turned out to be a stale comment (real code removed in 77d68e58, guarded by `:core_telegram_resume_index_leak`); `:telegram_known_targets` removed from core defaults — cached tables are per-instance opts + `register_cached_table/1`, channels registers its own at boot. sessions_index staleness bug fixed (write-through, regression test). A source-scan test now asserts store.ex contains no RunHistoryStore/MemoryIngest/telegram references. Policy wrappers deliberately untouched (§6). *(2026-08-10)*
- [ ] **1.4** Deps hygiene (`apps/lemon_core/mix.exs`): `sentry`, `finch`, `exqlite`, `phoenix_pubsub` → `optional: true` with graceful degradation (Bus falls back to a Registry-based pubsub or requires phoenix_pubsub explicitly — decide at implementation); replace `uuid` (unmaintained) with vendored UUIDv7.
- [x] **1.5** Done: `KeyProvider` behaviour (keychain/env/file built-ins, chain configurable via `config :lemon_core, LemonCore.Secrets, key_providers:`), portable non-macOS provisioning (0600 key file; `mix lemon.secrets.init --target --force`), weak raw keys rejected loudly (`:weak_master_key`) rather than HKDF-stretched — stretching would silently break existing ciphertexts; `allow_legacy_raw_keys: true` escape hatch with deprecation warning. Rotation gap documented in moduledoc. *(2026-08-10)*

Module moves (destinations per the disposition table in §6):

- [x] **1.6** Done: `apps/lemon_memory` created (deps: lemon_core + exqlite as a direct, non-optional dep — durable memory is the app's reason to exist). All 8 modules moved with `git mv`, renamed `LemonCore.Memory*` → `LemonMemory.*` (`Document`, `Store`, `Provider`, `Providers`(`.Local`), `Ingest`, `Safety`, `SessionSearch`, `TaskFingerprint`); `mix lemon.memory` moved too. Supervision (Providers always; Store+Ingest behind the exqlite guard) now lives in `LemonMemory.Application`, and the finalize-run hook config points at `LemonMemory.Ingest`. App-env key moved from `:lemon_core, LemonCore.MemoryStore` to `:lemon_memory, LemonMemory.Store` (config.exs, test.exs, runtime.exs). Doctor's memory diagnostics now go through `LemonCore.Doctor.RuntimeModules` (`:memory_providers`) instead of naming the module — so lemon_core has zero memory references left. 5 consumers updated (coding_agent, lemon_cli, lemon_control_plane, lemon_router, lemon_skills). Clean break, no shims. *(2026-08-10)*
- [x] **1.7** Move goal/kanban/heartbeat stores → `apps/agent_core` as `AgentCore.Workspace.*` (D5); update automation/channels/skills/control_plane call sites. Clean break, no shims. `lemon_automation` gained an `agent_core` dep; core's support bundle now resolves the goal/kanban diagnostics modules from `config :lemon_core, :workspace_diagnostics` so core keeps zero references to agent_core.
- [x] **1.8** Move single-consumer modules out. Done: `provider_pool_rotator`→coding_agent (`CodingAgent.ProviderPoolRotator`, now supervised by coding_agent), `provider_config_resolver`→agent_core (`AgentCore.ProviderConfigResolver`). Doctor: the 17 check modules turned out to reference *no* foreign app — the cross-app reach was in `doctor/support_bundle.ex` (media, browser) and `doctor/lsp_diagnostics.ex` (lsp), which now resolve those modules from `config :lemon_core, :doctor_runtime` (`LemonCore.Doctor.RuntimeModules`); `config :lemon_core, :doctor_checks` lets any app register its own checks. lemon_core's doctor code and tests now name zero foreign modules (guarded by a test). **Not moved, blocked on boundaries:** `build_info` is not single-consumer (core's own support-bundle manifest uses it at `support_bundle.ex:130`, and it reports lemon_core's version) — moving it to lemon_sim_ui would make core depend on sim_ui; `chat_state`/`chat_state_store` are used by lemon_gateway (`run.ex`, `transports/farcaster/cast_handler.ex`) as well as router/control_plane, and are baked into `Store.put_chat_state/get_chat_state` — moving them to router would force a gateway→router dep, which §2 forbids. Both need a decision recorded before they can move.
- [x] **1.9** Done: `LemonCore.Env` is now framework-only (258 LOC, down from 3,455); the 266 declarations live in 16 per-app registry modules aggregated through `config :lemon_core, :env_registries`. Contract is structural (`declarations/0`), with a `use LemonCore.Env.Registry` macro adding compile-time shape validation for apps that depend on lemon_core — `ai` implements it by hand precisely because it must not depend on core. Unloaded registries are skipped, so the aggregate always describes what the build can actually read. **Ownership is by reader, not by name**: 25 variables whose names say `LEMON_GATEWAY_*`/`LEMON_TELEGRAM_*`/`LEMON_WEB_CACHE_*` stay in lemon_core because `LemonCore.Config.*` resolves them (via `Env.get/2`, often through atoms passed as arguments); moving them by namespace made lemon_core raise standalone. They follow their readers out in a later pass. lemon_core's env_test now tests the framework against a test-local registry + core-owned vars, so it passes standalone and in the umbrella. *(2026-08-10)*
- [ ] **1.10** Sweep remaining lemon-specific defaults: `~/.lemon` paths in Config/MemoryStore/ConfigReloader become configurable with the current values as the *reference runtime's* config, not the library's.

**Done when:** `apps/lemon_core` has no modules referencing telegram/run-history/memory/kanban concepts; two differently-named Stores can run in one node (add a test); `mix deps.tree` for lemon_core shows sentry/finch/exqlite optional; umbrella CI + smoke green.

### Phase 2 — Invert wrong-direction deps (M)

- [x] **2.1** Gateway ⊘ coding_agent: `engines/lemon.ex` + `engines/lemon/session_runner.ex` moved to `apps/coding_agent` as `CodingAgent.GatewayEngine(.SessionRunner)`, self-registering via the new `LemonGateway.EngineRegistry.register/1` at coding_agent boot (registration also updates `:lemon_gateway, :engines` so a registry restart keeps it; configured engines whose module is absent are skipped instead of crashing the registry). Gateway's workspace dir is now its own `LemonGateway.Workspace` reading `config :lemon_gateway, :workspace_dir`, which the reference runtime points at `{CodingAgent.Config, :workspace_dir, []}`. mix.exs dep deleted and the edge inverted (coding_agent → lemon_gateway); the four grandfathered entries are retired. **Correction to this item:** `Security.ExternalContent` was NOT moved to lemon_core — `CodingAgent.Security.ExternalContent` is already a delegation shim over `AgentCore.Security.ExternalContent`, which depends on `AgentCore.Types.AgentToolResult` and `Ai.Types.TextContent`, so core cannot host it without taking agent/AI types. Gateway now calls the agent_core module directly (an edge it already had). §6 should move Security.ExternalContent from the core row to the lemon_agent row.
- [x] **2.2** Control_plane ⊘ coding_agent (D9). **Shape chosen: one capability provider, not per-method registration.** All 7 surfaces turned out to be *backends behind existing methods* (TaskStore inside tasks.*, SessionRegistry+Session.compact inside sessions.compact, Extensions/ToolRegistry/Config/Wasm inside extensions.status and skills.status, RunGraph inside run_graph.get, Progress inside agent.progress) — no method is wholly owned by the agent, so registering method modules would have meant splitting 8 handlers in half. Instead `LemonControlPlane.AgentRuntime` resolves a single registered module implementing the 13-callback `AgentRuntime.Provider` behaviour, and `AgentRuntime.call/3` is the only path to it: missing provider, unimplemented optional callback, raise and exit all yield the caller's fallback, which is what preserves every method's existing empty/unavailable payload. coding_agent registers `CodingAgent.ControlPlaneProvider` at boot via `Module.concat` + `apply` so the *product* keeps zero compile-time reference to the unpublished reference runtime (it does not declare the behaviour either; a coding_agent test checks the module against `behaviour_info(:callbacks)` at runtime instead). mix dep deleted, 8 grandfathered entries retired, policy row updated. Bonus: extensions.status and agent.progress were previously *unguarded* — they would have crashed without coding_agent, and now degrade.
- [x] **2.3** Done (D7): the adapter (`XApi.ChannelAdapter` + `.GatewayMethods`) and the three tools (`XApi.Tools.{XSearch,PostToX,GetXMentions}`) moved into `apps/x_api` with `git mv`; x_api gained `lemon_channels`/`agent_core`/`ai` deps and channels+skills dropped theirs, so the arrow now points satellite → platform. **The tools were the real work**: they were never registered from lemon_skills — three *platform* lists named them (`CodingAgent.ToolRegistry.@builtin_tools`, `CodingAgent.Tools` coding_tools/all_tools, `LemonMCP.ToolAdapter.@builtin_tools`), so moving them would have made the platform depend on the satellite. Added `AgentCore.ToolRegistry` (persistent_term, built-ins win on name collision) — the tool-side analogue of the engine/adapter/check registries — and all three consumers merge it. `XApi.Application` registers the adapter via `LemonChannels.Application.register_and_start_adapter/2` and the tools via the registry, both behind `Code.ensure_loaded?` guards, so x_api boots standalone. `LemonChannels.Adapters.XAPI` is out of `config :lemon_channels, :adapters` — the runtime's config no longer names X either. All 5 XApi allowlist entries retired. Left in place deliberately: `LemonChannels.Capabilities.lookup("x_api")`, a string-keyed data table with no `XApi.*` reference and its own test; folding capability lookup into the registered adapter's `meta` belongs with 2.4. *(2026-08-10)*
- [ ] **2.4** *(rescoped per amended D2 — see `docs/platform/transport-unification.md` §sequencing)* A1–A3: decision checkpoint, correct "transitional legacy ingress" language, rename `:legacy_ingress_enabled`. B1: characterization tests for email `outbound.ex` (715 LOC, zero tests). B2: `LemonChannels.InboundHttp` (plug/bandit — channels' first HTTP server). B3: port email to Plugin. Webhook/SMS remain gateway ingress; voice deferred; farcaster awaiting user decision. `transports.status` + capabilities delegation + telegram-surfaces moved to 2.5's scope.
- [x] **2.5** Kill dynamic-atom back-refs. New `LemonCore.EngineInfoBridge` (RouterBridge's pattern pointed the other way: configured implementation module per capability, runtime dispatch, documented degraded answer). The engine runtime registers itself in `LemonGateway.Application.start/2` with three capabilities — `engine_registry`, `transport_registry`, `gateway_config` — and the three back-refs now ask core: channels' `gateway_config.ex` (via new `LemonGateway.Config.replacement_config/0`, so the app-env peek lives in the app that owns the env), channels' `engine_registry.ex` (`extract_resume/1`), and control_plane's `transports_status.ex` (the `:transport_registry_module` app-env override still wins, which is how its tests substitute a stub). **The @grandfathered allowlist is now empty** — every authorized cross-boundary reference is gone.
- [x] **2.6** Done: `LemonRouter` gained `available?/0`, `active_runs/0`, `run_active?/1`, `active_run_count/0`, `counts/0`, designed from the 13 call sites rather than speculatively (`submit/1`, `abort/2`, `abort_run/2` already existed and just needed callers pointed at them). The facade owns the defensiveness each caller had reimplemented — `Process.whereis` probes, `Registry.select`/`lookup`, `DynamicSupervisor.count_children`, rescue/catch ladders — so a router that is not running reports nothing-active instead of raising. `counts/0` deliberately returns the full zeroed shape rather than `%{}`: control_plane's status method reads `.active`/`.queued`/`.completed_today` unguarded, and an empty map raised KeyError (caught in test). 9 call sites migrated across control_plane (7), automation (1, the `Process.whereis(RunRegistry)` probe → `available?/0`) and the abort pair; `RunSupervisor`/`RunOrchestrator` are now `@moduledoc false` (there is no RunRegistry module — it's a plain `Registry` started in the router's supervision tree). All 8 router entries retired from `@grandfathered`; the `:router_internals_boundary` rule now has zero exemptions. New `facade_test.exs` proves the contract with the router both running and stopped. *(2026-08-10)*

**Done when:** `mix xref graph` shows no gateway→coding_agent, control_plane→coding_agent, channels→x_api, skills→x_api edges; only one transport behaviour exists; boundary CI allowlist from 0.2 shrinks accordingly.

### Phase 3 — Contracts, docs, test kit (M)

- [ ] **3.1** Typed bus events: catalog every `LemonCore.Bus` topic + payload actually published (grep `Bus.broadcast`); give each a struct or documented shape in `LemonCore.Events.*`; consumers pattern-match on structs. This is the platform's wire format — treat changes as semver-major from first publish.
- [ ] **3.2** Document the six extension behaviours as the official surface: `LemonChannels.Plugin`, `LemonGateway.Engine`, `LemonCore.EngineRuntime`, `LemonCore.Store.Backend`, `LemonMemory.Provider`, agent tool contract in `AgentCore`. Each gets a hexdocs guide with a worked example.
- [ ] **3.3** Build `lemon_platform_test`: ExUnit case templates that run compliance suites against a user's Plugin/Engine/Backend/Provider implementation (seed from our own adapters' shared tests).
- [ ] **3.4** `mix lemon.new` generator: scaffolds an agent project depending on `lemon_agent`+`lemon_ai`+`lemon_core`, with one example tool and one channel wired.
- [ ] **3.5** Getting-started docs: "build your first agent," "add a channel," "add an engine," "persist memory" — written against the generator output.

**Done when:** a fresh project from `mix lemon.new` compiles against path deps and passes the contract kit; every behaviour has a hexdocs page.

### Phase 4 — Publish from the monorepo (S–M)

- [ ] **4.1** Add hex metadata (description, licenses, links, docs) to the 8 packages; umbrella keeps `in_umbrella` path deps in dev, publishes real versions outward.
- [ ] **4.2** CI publish workflow (tag-driven, per-package `vX.Y.Z-<package>` tags or a release script); hexdocs publishing.
- [ ] **4.3** Publish `0.1.0` in dependency order: ai → core → agent → memory → router/gateway/channels → platform_test.
- [ ] **4.4** Soak: one full dev cycle where product apps *inside* the umbrella are switched to consume the published contracts conceptually (no mechanical change, but any API change now requires a changelog entry). Fix what chafes while changes are still one-repo atomic.

**Done when:** all 8 on hex with docs; CHANGELOG discipline in place.

### Phase 5 — Extract product repos (M per repo)

Per repo (`coding-agent`, `lemon-sim`, `showcase`, `lemon-clients`), in that order:

- [ ] **5.1** `git filter-repo` preserving history for the moved paths; swap `{:x, in_umbrella: true}` → `{:lemon_x, "~> 0.1"}`.
- [ ] **5.2** Port the umbrella's CI (test/credo/dialyzer/smoke) from templates; per-repo README/CONTRIBUTING/SECURITY.
- [ ] **5.3** lemon-sim specifics: D3 Bench boundary hardening (BenchDomains wiring namespace, inline stable_json); take the `LEMON_ARENA_*` env registrations with it (from 1.9).
- [ ] **5.4** coding-agent specifics: takes lemon_mcp + lemon_evals + coding_agent_ui; its gateway engine registers via 2.1's mechanism.
- [ ] **5.5** x_api leaves to its satellite repo (D7 completion).
- [ ] **5.6** Delete moved apps from the umbrella; platform repo keeps the reference runtime + published packages only.
- [ ] **5.7** Cross-repo integration check: a nightly CI job in the platform repo that builds coding-agent and lemon-sim against hex releases (and optionally against `main` via git deps) — the early-warning system for accidental breakage.

**Done when:** umbrella contains only platform apps; products build green in their repos from hex releases; nightly integration lane green.

### Phase 6 — Launch polish (S–M)

- [ ] **6.1** Platform README rewritten for external builders; showcase site points at packages + generator + lemon-sim arenas as the demo.
- [ ] **6.2** Position lemon-sim as flagship (D8): its README leads with the arena leaderboards; link from platform docs.
- [ ] **6.3** Issue templates, `good-first-integration` labels (a new channel adapter is the ideal first PR), release announcement.

## 6. `lemon_core` module disposition (final)

Updated for D1–D9. Buckets: **core** (stays in published `lemon_core`), **router/channels/gateway/agent/memory** (moves to that package), **consumer** (moves to the named app), **runtime** (stays in platform repo's reference-runtime layer, unpublished).

| Destination | Modules |
|---|---|
| **core — primitives** | bus, event, store (+backends, post-1.1–1.4), secrets (post-1.5), config + config_cache(+error), clock, id, retry, telemetry, map_helpers, dedupe_ets, idempotency(+store), httpc, dotenv, logging + logger_setup, testing, env *framework* (registrations leave, 1.9), extensions/ (manifest, registry_audit) |
| **core — boundary contracts** | run_request, run_phase, run_phase_event, run_phase_graph, run_outcome, execution_command, inbound_message, delivery_intent, delivery_route, engine_runtime, engine_catalog, router_bridge, event_bridge, session_key, resume_token, chat_state + chat_state_store (a resume-token cache keyed by session — same family; corrected from the router row, see D11), exec_approvals (approval contract; storage wrapper moves w/ control_plane), terminal_backend (behaviour), introspection, + new: EngineInfoBridge (2.5), Events.* structs (3.1). ~~Security.ExternalContent~~ corrected 2026-08-10: lives in **lemon_agent** (`AgentCore.Security.ExternalContent` — depends on agent/AI types, so core can't host it; see 2.1 note) |
| **router** | run_store, run_history_store (post-1.3 hook split). *`chat_state`/`chat_state_store` corrected to stay in core — see the boundary-contracts row.* |
| **channels** | cwd, binding, binding_resolver, gateway_config, project_binding_store, telegram-flavored store pieces from 1.3 |
| **gateway** | (none — gateway consumes core contracts; sheds transports per D2) |
| **agent (`lemon_agent`)** | goal_store, kanban_store, heartbeat_store → `AgentCore.Workspace.*` (D5); provider_config_resolver |
| **memory (`lemon_memory`)** | ✅ moved (1.6): `LemonMemory.Document`, `.Store`, `.Provider`, `.Providers`(+`.Local`), `.Ingest`, `.Safety`, `.SessionSearch`, `.TaskFingerprint`, plus `mix lemon.memory` (D4) |
| **consumer** | ~~build_info → lemon_sim_ui~~ **corrected 2026-08-10: build_info stays core** — core's own support-bundle manifest uses it and it reports core's version/release metadata; the single-consumer premise was wrong. provider_pool_rotator → coding_agent ✓ (done, supervised child moved too); doctor checks → **audit found none reach foreign apps**; the real cross-app reach was support_bundle/lsp_diagnostics helpers, now behind `LemonCore.Doctor.RuntimeModules` (`:doctor_runtime` config) + app-owned checks registrable via `:doctor_checks` ✓; checkpoint → verify owner during Phase 1 (unchanged) |
| **runtime (platform repo, unpublished)** | config_reloader(+dir), reload, terminal_backends registry + terminal_backend_policy, usage_store, usage_diagnostics, exec_approval_store, policy_store, progress_store, heartbeat wiring |

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Phase 1 destabilizes everything at once (Store is in every hot path) | Land 1.1–1.4 as compatibility-preserving refactors (default name = `LemonCore.Store`, app-env fallback kept); umbrella behavior unchanged until consumers opt into instances. Smoke suite after every item. |
| Bus payload typing (3.1) reveals undocumented consumer assumptions | Catalog first, type incrementally topic-by-topic; keep struct + legacy-map acceptance for one cycle. |
| Extraction loses git history / breaks muscle memory | `git filter-repo` with path preservation; leave tombstone READMEs in the umbrella pointing to new repos for one release. |
| Cross-repo drift after Phase 5 | 5.7 nightly integration lane; contracts changes require changelog + version bump by CI check. |
| Scope creep: publishing skills/media/browser/etc. too early | Explicitly deferred (§2); revisit only on external demand. |

## 8. Decision log

| Date | Decision | Why |
|---|---|---|
| 2026-08-09 | Sequencing: carve core → invert deps → contracts → hex from monorepo → extract products | Extraction is cheap after boundaries are real; painful before. |
| 2026-08-10 | **D11**: `chat_state`/`chat_state_store` stay in `lemon_core` as boundary contracts, and the router becomes their single writer (gateway's writes deleted). | Third plan-corrected-by-evidence outcome after `build_info` and `ExternalContent`. §6 assigned them to router on the assumption router was the only reader; lemon_channels is a legitimate reader+writer, so router ownership would force channels→router. Chat state is a resume-token cache keyed by session — the same family as `ResumeToken`/`SessionKey`, already core boundary contracts. Moving it to channels (the one legal alternative, since router→channels is allowed) would encode an accident as architecture. |
| 2026-08-09 | D1–D10 resolved (see §4) after code-level investigation (E1–E4) | Store singleton audit; Bench coupling measurement; router/gateway/channels topology mapping; license + hex-name checks. |

## 9. Deferred (not open — parked with owners)

- Telegram config/diagnostics surfaces still in lemon_core (config.ex gateway-telegram block conversion, channel_readiness, inbound_message naming): decide during Phase 2.4 transport unification whether these become channel-registered capabilities. A blanket telegram-atom rule was deliberately not added (would need ~8 grandfathered files). **Partly resolved in 2.5:** `doctor/channel_diagnostics` no longer duplicates a hardcoded transport list — the reported transports drive the binding counts from one list, and the channels registry is now reachable through `:doctor_runtime` (`channel_registry`), surfacing what is actually registered as a new `registered_transports` field. Deliberately *not* done: making the registry list drive `binding_count`/`unsupported_binding_count`. Those have always meant "transports this diagnostic reports on", which is a smaller set than "registered adapters" (whatsapp, xmtp, x_api register but get no status block), so swapping the source would silently change what the numbers mean. The remaining work is per-transport status builders, which is 2.4's business.
- ~~chat_state/chat_state_store → router move.~~ **Resolved 2026-08-10 (D11): they stay in core.** Two premises were wrong. Router is *not* the only reader — lemon_channels reads (`telegram/transport/per_chat_state.ex:17`) and writes (`:125`, `:138`), and channels may not depend on router (§2), so the move would have created a forbidden edge. And gateway's writes were redundant rather than load-bearing: the overflow delete was duplicated by router's `compaction_trigger.ex:177` on the same event, and the completion event already carries `:resume` into router (`extract_completed_resume/1`), so router could always have done the write. Gateway's chat-state coupling is now zero and router is the single writer.
- LemonMemory.Ingest `:name` parameterization (currently always registers as `__MODULE__`) — small API change, do before publishing lemon_memory.
- LemonMemory.SessionSearch has 0% direct coverage (consumers test callers) — main thing holding lemon_memory at 60%.

- Adapter satellite packages (`lemon_channels_telegram`, `lemon_channels_discord`): after Plugin behaviour is documented and x_api (D7) proves the pattern.
- Renaming `lemon_gateway` → `lemon_engines`: revisit at 4.1; name describes the post-D2 shrunk scope better, but rename churn during the carve is not worth it.
- Secrets key rotation / re-encrypt path: known-missing, documented in 1.5; schedule when a second key provider lands.
- Publishing skills/media/browser/lsp/automation: on external demand only.
