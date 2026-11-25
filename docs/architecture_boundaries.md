# Architecture Boundaries

Lemon enforces architecture rules over the umbrella dependency graph declared in
`apps/*/mix.exs`, which is the only authority for that graph. The generated
table shows each app's role, its lib and `only: :test` edges, and the
reference-only seams that permit runtime dispatch without a Mix dependency.

## Direct Dependency Policy

<!-- architecture_policy:start -->
| App | Role | Lib deps from `mix.exs` | `only: :test` deps | Reference-only seams |
| --- | --- | --- | --- | --- |
| `coding_agent` | platform | `lemon_agent`, `lemon_ai`, `lemon_browser`, `lemon_core`, `lemon_gateway`, `lemon_lsp`, `lemon_memory`, `lemon_skills` | `lemon_platform_test` | *(none)* |
| `lemon_agent` | platform | `lemon_ai`, `lemon_core` | *(none)* | *(none)* |
| `lemon_ai` | foundation | *(none)* | *(none)* | *(none)* |
| `lemon_automation` | platform | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_router`, `lemon_skills` | *(none)* | *(none)* |
| `lemon_browser` | platform | `lemon_core` | *(none)* | *(none)* |
| `lemon_channels` | platform | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_media` | *(none)* | *(none)* |
| `lemon_cli` | satellite | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_memory`, `lemon_skills` | *(none)* | `coding_agent`, `lemon_channels`, `lemon_media`, `lemon_router` |
| `lemon_computer_use` | satellite | `lemon_agent`, `lemon_ai`, `lemon_core` | *(none)* | *(none)* |
| `lemon_control_plane` | platform | `lemon_agent`, `lemon_ai`, `lemon_automation`, `lemon_browser`, `lemon_channels`, `lemon_core`, `lemon_memory`, `lemon_omp`, `lemon_router`, `lemon_skills` | *(none)* | *(none)* |
| `lemon_core` | foundation | *(none)* | *(none)* | *(none)* |
| `lemon_evals` | satellite | `coding_agent`, `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_memory`, `lemon_skills` | *(none)* | *(none)* |
| `lemon_gateway` | platform | `lemon_agent`, `lemon_core`, `lemon_media` | *(none)* | `lemon_ai` |
| `lemon_honcho` | satellite | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_memory` | `lemon_platform_test` | *(none)* |
| `lemon_lsp` | platform | `lemon_core` | *(none)* | *(none)* |
| `lemon_media` | platform | `lemon_core` | *(none)* | *(none)* |
| `lemon_memory` | platform | `lemon_core` | *(none)* | *(none)* |
| `lemon_omp` | platform | `lemon_agent`, `lemon_ai`, `lemon_core` | *(none)* | *(none)* |
| `lemon_platform_test` | test kit | `lemon_agent`, `lemon_ai`, `lemon_channels`, `lemon_core`, `lemon_memory` | *(none)* | *(none)* |
| `lemon_router` | platform | `lemon_agent`, `lemon_ai`, `lemon_channels`, `lemon_core`, `lemon_media`, `lemon_memory`, `lemon_skills` | *(none)* | *(none)* |
| `lemon_skills` | platform | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_media`, `lemon_memory` | *(none)* | *(none)* |
| `lemon_web` | satellite | `lemon_agent`, `lemon_automation`, `lemon_control_plane`, `lemon_core`, `lemon_memory`, `lemon_router` | *(none)* | *(none)* |
<!-- architecture_policy:end -->

## Package Map

Every umbrella app, its version in `mix.exs`, and whether it is in the Hex
publish set (its `project/0` declares `package:` metadata). The publish set must
equal the `PACKAGES` list in `scripts/verify_packages`, which
`scripts/release_package` publishes from; `mix lemon.quality` fails when they
differ. In-repo versions are not publication claims: which versions are on Hex
is in [package status](platform-split.md). Apps outside the publish set ship
only inside the product releases.

<!-- package_map:start -->
| App | Version in `mix.exs` | Hex publish set |
| --- | --- | --- |
| `coding_agent` | 0.1.0 | no |
| `lemon_agent` | 0.3.0 | yes |
| `lemon_ai` | 0.3.0 | yes |
| `lemon_automation` | 0.1.0 | no |
| `lemon_browser` | 0.1.0 | no |
| `lemon_channels` | 0.1.0 | no |
| `lemon_cli` | 0.1.0 | no |
| `lemon_computer_use` | 0.1.0 | no |
| `lemon_control_plane` | 0.1.0 | no |
| `lemon_core` | 0.3.0 | yes |
| `lemon_evals` | 0.1.0 | no |
| `lemon_gateway` | 0.1.0 | no |
| `lemon_honcho` | 0.1.0 | no |
| `lemon_lsp` | 0.1.0 | no |
| `lemon_media` | 0.1.0 | no |
| `lemon_memory` | 0.2.0 | yes |
| `lemon_omp` | 0.1.0 | no |
| `lemon_platform_test` | 0.2.0 | yes |
| `lemon_router` | 0.1.0 | no |
| `lemon_skills` | 0.1.0 | no |
| `lemon_web` | 0.1.0 | no |
<!-- package_map:end -->

## Enforcement

Run:

```bash
mix lemon.quality          # also part of `scripts/test quality`
mix lemon.architecture.docs          # regenerate the generated tables above
mix lemon.architecture.docs --check  # fail if a table is stale
```

The rules live in `LemonCore.Quality.ArchitecturePolicy`
(`apps/lemon_core/lib/lemon_core/quality/architecture_policy.ex`), which names
roles (namespace ownership, foundations, satellites, test kits, reference-only
seams and config bindings) and never restates `mix.exs`. The tables between the
`architecture_policy` and `package_map` markers are generated from it and from
`apps/*/mix.exs`, and must not be edited by hand. `mix lemon.quality` runs the
docs link check (local Markdown links in `docs/**/*.md` must resolve), the
generated-table freshness and publish-set checks, the architecture check and the
duplicate test-module guard.

The architecture checker fails when:

- a foundation (`lemon_ai`, `lemon_core`) declares any umbrella dependency
- any app depends on a satellite, or on a test kit outside `only: :test`
- declared edges plus reference-only seams and config bindings form a cycle
- a lib edge has no reference from the app's `lib/`, or `lib/` reaches an
  `only: :test` dependency
- code under `apps/*/lib` reaches another app outside its lib dependencies, by
  alias, quoted `:"Elixir.Module"` atom, `Module.concat` with literal namespace
  segments (including `"Lemon" <> "X"`), or `Application`/`:application` env
  access naming another umbrella app; quoted atoms and literal `Module.concat`
  are rejected even toward a dependency, because they hide the edge from xref
- `config :app` in `config/*.exs` names a module of an app that `app` neither
  depends on nor is depended on by, unless the policy lists that config binding
- a reference-only seam or config binding is unused, or a seam duplicates a
  declared edge

## Runtime Ownership Rules

These ownership boundaries are review conventions; `mix lemon.quality` enforces
the dependency policy above, not these source-level rules:

- `lemon_router` may emit semantic `LemonCore.DeliveryIntent` values, but it may not construct `LemonChannels.OutboundPayload` values or reference Telegram renderer helpers directly.
- Automation binds supervision targets and submits terminal facts through the registered `LemonCore.ChannelSupervision` capability. Channels owns its implementation, durable admission, rendering and Outbox delivery. No consumer resolves a channels namespace or constructs platform payloads across this boundary.
- `lemon_channels` owns channel rendering and presentation state. It must not mutate inbound prompts for pending-compaction behavior.
- `lemon_gateway` owns execution slots and the native execution lifecycle. Router-owned queue semantics, chat-state readback for automatic-resume request mutation, and conversation-key selection must not move back into gateway. Router hands pre-resolved, engine-less `LemonCore.ExecutionCommand` values to `LemonCore.EngineRuntime`; gateway adapts them to its private `LemonGateway.ExecutionRequest` and invokes the fixed native executor. `LemonGateway.Runtime.submit/1` must not be reintroduced as a compatibility path. Default gateway startup is execution-only; gateway-native transport, command, SMS, and voice children require explicit `:gateway_ingress_enabled` configuration. Those surfaces are gateway-owned by design rather than pending migration — SMS, webhook, and voice do not fit `LemonChannels.Plugin`.
- Gateway-owned transports submit through `LemonCore.RouterBridge` when they need router normalization. They must not take a compile-time dependency on `LemonRouter.RunOrchestrator`.
- Router-owned active session state is only exposed through `LemonRouter.Router` and `LemonCore.RouterBridge`. External apps must not reference `LemonRouter.SessionRegistry` directly.
- Top-level requests and execution commands never validate or carry a runner identity. `engine: "lemon"` remains fixed run provenance in events and stores. `ResumeToken.engine` and historical `ChatState.last_engine` remain persisted discriminators; only native tokens may resume a top-level run, while non-native historical values are retained and quarantined from resume. Subagents execute natively in-process (`CodingAgent.Session` via the task lifecycle); there is no external CLI runner registry. `LemonCore.Cwd` is the only default-cwd resolver.
- Execution authorization is shared core language:
  `LemonCore.ToolPolicy` strictly validates supplied policy and
  `LemonCore.ExecutionContext` binds run lineage, principal/provenance,
  workspace, effective capabilities, and limits. Router layers and child
  execution use authority intersection; named nodes transport and revalidate
  only the versioned context rather than independently normalizing policy.
- Shared domains in `lemon_core` / `lemon_control_plane` must use typed wrappers such as `RunStore`, `ChatStateStore`, `PolicyStore`, and `ProjectBindingStore` instead of bypassing them with raw store helpers.
- Agent runtime registration and optional callback contracts live in `LemonCore.AgentRuntime`. Coding products register their provider at boot; control-plane methods, automation reviewers, channel commands and Web projections call the same core seam. Registry configuration belongs to `:lemon_core`; no consumer depends on the control plane to discover the running agent.
- The shared CLI registry dispatches Mix-free command modules in their owning apps. Its `coding_agent`, `lemon_channels`, `lemon_media` and `lemon_router` references are reference-only seams so setup and other one-shot commands do not start those services through an application dependency. Source Mix tasks are thin adapters; packaged runtime profiles include the same handlers.
- The MCP client library (`LemonMCP.*`) ships inside `lemon_skills`, which owns its only source consumer, `LemonSkills.McpSource`, and calls the clients directly. `coding_agent` uses it for native MCP capability discovery; `lemon_router` reuses `LemonMCP.HTTP.OriginPolicy` during native follow-up admission, `lemon_automation` for cron admission, and `lemon_cli` and `lemon_control_plane` so local and remote `lemon doctor` runs compare Lemon Bot admission origins with that same canonicalization. All of them declare an ordinary `lemon_skills` edge. Consuming apps supervise any clients and transports they create; origin validation is not duplicated or moved into dependency-free `lemon_core` / `lemon_ai`.

### Shared mechanisms without foundation dependencies

`lemon_ai` and `lemon_core` remain independent foundations: neither may acquire
an umbrella dependency merely to share a mechanism. Consolidation means **one
implementation per foundation package**, not a new dependency between them.
Provider retries and rate limiting live in `lemon_ai`; platform/channel retries,
dedupe and rate limiting live in `lemon_core`. The agent loop uses the AI retry
policy rather than adding another retry implementation. Retry policies in both
foundations use bounded attempts, capped delays and caller-selected retryability;
they never implicitly retry an unknown mutation outcome. A single response owns
one retry budget even when more than one provider layer is involved.

`LemonCore.RuntimeSeam` implements optional-consumer configuration, validation
and protected dispatch. `AgentRuntime`, `ChannelSupervision`, `AgentMessaging`,
`RouterBridge`, `EventBridge` and `EngineInfoBridge` retain only their domain
contracts, acknowledgement checks and failure policies; `EngineRuntime` retains
its execution behaviour and delegates implementation validation to the same
seam. These domain APIs are not interchangeable registries. Missing consumers
retain their documented degradation; reached mutation failures remain
`:outcome_unknown` and queries never masquerade as successful empty state.

## Skill Source Taxonomy

Skills are classified by source kind and trust level (`LemonSkills.Entry`). Routing from user-facing identifiers to sources is `LemonSkills.SourceRouter`; install/update/audit rules are `LemonSkills.TrustPolicy`. New source kinds must be added here before being used in code, and the trust-level set may only be extended via a documented invariant update. See the [skills reference](skills.md) and the [skills guide](../apps/lemon_skills/AGENTS.md) for operational detail.

### Source Kinds

| Source kind | Description | Example identifier |
| --- | --- | --- |
| `builtin` | Bundled with the Lemon release and seeded by `LemonSkills.BuiltinSeeder`. Never fetched from the network. | `builtin` |
| `local` | A directory on the local filesystem outside the installation. | `/path/to/my-skill` |
| `git` | A git repository: URL, `git+<url>`, SSH URL, `gh:<owner>/<repo>` shorthand, or an official `hermes:<collection>/<path>` ID. | `https://github.com/user/skill-repo` |
| `registry` | An entry from the official Lemon skill registry, addressed by namespace path. | `official/devops/k8s-rollout` |
| `well_known` | A skill found by probing well-known registry URL patterns during discovery; recorded as `community`. | *(discovered, no identifier form)* |

### Trust Levels

Trust levels control install/update policy and audit behavior. Ordered from highest to lowest trust:

| Trust level | Assigned to | Policy |
| --- | --- | --- |
| `builtin` | Source kind `builtin` only. | No audit; the only level that is auto-approved. |
| `official` | Skills in the `official/` registry namespace and `hermes:` sources. | Audited; install, update and uninstall need explicit approval. |
| `trusted` | `local` sources (a path the user controls). | Audited; approval required. |
| `community` | Third-party `git`, `registry` and `well_known` sources. | Audited; approval required. |

Every non-builtin install or update is audited. A `warn` verdict needs explicit approval; a `block` verdict is not bypassed by ordinary approval and needs the separate security-override operation bound to the exact bundle hash and findings.

## Module Placement Rules

These rules complement the dependency policy table above. They must be respected when adding new modules.

| Domain | Canonical home | Forbidden locations |
| --- | --- | --- |
| Durable memory documents, scoped search/recall, context scopes and lifecycle | `lemon_memory` | `lemon_core` (generic Store only), any other app |
| Browser capability driver | `lemon_browser` | `lemon_core`, `coding_agent`, `lemon_control_plane` |
| Agent runtime and channel supervision capability contracts/registries | `lemon_core` | Consumer apps (provider implementations remain in their owning products) |
| Media job driver and media provider drivers (OpenAI, Google, ElevenLabs and Deepgram HTTP clients, Google service-account token cache) | `lemon_media` | `lemon_core`, `lemon_skills`, `lemon_channels`, `lemon_gateway`, `lemon_router`, `lemon_control_plane` |
| LSP server driver | `lemon_lsp` | `lemon_core`, `coding_agent`, `lemon_control_plane` |
| Debug adapter (DAP) client | `coding_agent` | `lemon_core`, `lemon_control_plane` |
| omp delegate driver (RPC protocol, session processes, discovery, `omp` tool) | `lemon_omp` | `lemon_core`, `coding_agent`, `lemon_gateway`, `lemon_control_plane` |
| Native computer-use driver (LCU bridge, approval routing, `cua_js` tools) | `lemon_computer_use` | `lemon_core`, `coding_agent`, `lemon_control_plane` |
| Skill platform logic (manifest, registry, installer, lockfile, source router, audit) | `lemon_skills` | `coding_agent`, `lemon_core`, `lemon_router` |
| Coding-session prompt assembly and coding/file tool registration | `coding_agent` | `lemon_skills`, `lemon_core` |
| Assistant-platform tools (`remember`, `recall`, goal, kanban, media, skill tools) | `lemon_skills` | `coding_agent`, `lemon_core` |
| Execution policy and authority context contracts | `lemon_core` | Any product-specific app |
| Model/session routing | `lemon_router` | `coding_agent`, `lemon_skills` |
| Optional GenAI model/tool telemetry span export | `lemon_agent` | `lemon_ai`, `lemon_core` (both remain umbrella-independent) |
| Runtime boot, profile, health, env detection | `lemon_core/runtime` | Shell scripts (only thin wrappers allowed there) |
| Transport-independent RPC request ownership, framing and transport behaviours | `lemon_core/rpc` | Product apps (protocol policy and driver lifecycle stay in their owning apps) |

When a new module does not fit an existing domain, update this table before adding the module.
