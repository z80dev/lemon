# Architecture Boundaries

Lemon enforces an exact direct umbrella dependency graph by app. The generated
table distinguishes dependencies parsed from `mix.exs`, direct edges permitted
by policy, and source-reference exceptions that do not permit a Mix dependency.
This keeps the harness modular and prevents deleted edges from remaining as
silent permissions.

## Direct Dependency Policy

<!-- architecture_policy:start -->
| App | Actual direct deps from `mix.exs` | Allowed direct deps | Reference-only exceptions |
| --- | --- | --- | --- |
| `coding_agent` | `lemon_agent`, `lemon_ai`, `lemon_browser`, `lemon_core`, `lemon_gateway`, `lemon_lsp`, `lemon_mcp`, `lemon_memory`, `lemon_platform_test`, `lemon_skills` | `lemon_agent`, `lemon_ai`, `lemon_browser`, `lemon_core`, `lemon_gateway`, `lemon_lsp`, `lemon_mcp`, `lemon_memory`, `lemon_platform_test`, `lemon_skills` | *(none)* |
| `lemon_agent` | `lemon_ai`, `lemon_core` | `lemon_ai`, `lemon_core` | *(none)* |
| `lemon_ai` | *(none)* | *(none)* | *(none)* |
| `lemon_automation` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_router`, `lemon_skills` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_router`, `lemon_skills` | *(none)* |
| `lemon_browser` | `lemon_core` | `lemon_core` | *(none)* |
| `lemon_channels` | `lemon_agent`, `lemon_core`, `lemon_media` | `lemon_agent`, `lemon_core`, `lemon_media` | *(none)* |
| `lemon_cli` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_memory`, `lemon_skills` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_memory`, `lemon_skills` | `lemon_channels`, `lemon_media` |
| `lemon_computer_use` | `lemon_agent`, `lemon_ai`, `lemon_core` | `lemon_agent`, `lemon_ai`, `lemon_core` | *(none)* |
| `lemon_control_plane` | `lemon_agent`, `lemon_ai`, `lemon_automation`, `lemon_browser`, `lemon_channels`, `lemon_core`, `lemon_lsp`, `lemon_media`, `lemon_memory`, `lemon_omp`, `lemon_router`, `lemon_skills` | `lemon_agent`, `lemon_ai`, `lemon_automation`, `lemon_browser`, `lemon_channels`, `lemon_core`, `lemon_lsp`, `lemon_media`, `lemon_memory`, `lemon_omp`, `lemon_router`, `lemon_skills` | *(none)* |
| `lemon_core` | *(none)* | *(none)* | *(none)* |
| `lemon_evals` | `coding_agent`, `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_memory`, `lemon_skills` | `coding_agent`, `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_memory`, `lemon_skills` | *(none)* |
| `lemon_gateway` | `lemon_agent`, `lemon_core` | `lemon_agent`, `lemon_core` | `lemon_ai` |
| `lemon_honcho` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_memory`, `lemon_platform_test` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_memory`, `lemon_platform_test` | *(none)* |
| `lemon_lsp` | `lemon_core` | `lemon_core` | *(none)* |
| `lemon_mcp` | `lemon_core`, `lemon_skills` | `lemon_core`, `lemon_skills` | *(none)* |
| `lemon_media` | `lemon_core` | `lemon_core` | *(none)* |
| `lemon_memory` | `lemon_core` | `lemon_core` | *(none)* |
| `lemon_omp` | `lemon_agent`, `lemon_ai`, `lemon_core` | `lemon_agent`, `lemon_ai`, `lemon_core` | *(none)* |
| `lemon_platform_test` | `lemon_agent`, `lemon_ai`, `lemon_channels`, `lemon_core`, `lemon_memory` | `lemon_agent`, `lemon_ai`, `lemon_channels`, `lemon_core`, `lemon_memory` | *(none)* |
| `lemon_router` | `lemon_agent`, `lemon_ai`, `lemon_channels`, `lemon_core`, `lemon_mcp`, `lemon_media`, `lemon_memory` | `lemon_agent`, `lemon_ai`, `lemon_channels`, `lemon_core`, `lemon_mcp`, `lemon_media`, `lemon_memory` | *(none)* |
| `lemon_sim` | `lemon_agent`, `lemon_ai`, `lemon_core` | `lemon_agent`, `lemon_ai`, `lemon_core` | *(none)* |
| `lemon_sim_ui` | `lemon_ai`, `lemon_core`, `lemon_sim` | `lemon_ai`, `lemon_core`, `lemon_sim` | *(none)* |
| `lemon_skills` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_media`, `lemon_memory` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_media`, `lemon_memory` | *(none)* |
| `lemon_web` | `lemon_agent`, `lemon_automation`, `lemon_control_plane`, `lemon_core`, `lemon_memory`, `lemon_router` | `lemon_agent`, `lemon_automation`, `lemon_control_plane`, `lemon_core`, `lemon_memory`, `lemon_router` | *(none)* |
<!-- architecture_policy:end -->

## Enforcement

Run:

```bash
mix lemon.quality          # also part of `scripts/test quality`
mix lemon.architecture.docs          # regenerate the policy table above
mix lemon.architecture.docs --check  # fail if the table is stale
```

The policy lives in `LemonCore.Quality.ArchitecturePolicy`
(`apps/lemon_core/lib/lemon_core/quality/architecture_policy.ex`); the table
between the `architecture_policy` markers is generated from it and must not be
edited by hand. `mix lemon.quality` runs the docs link check (local Markdown
links in `docs/**/*.md` must resolve), the generated-table freshness check, the
architecture check and the duplicate test-module guard.

The architecture checker enforces all of the following:

- direct umbrella dependencies parsed from complete `deps/0` bodies in `apps/*/mix.exs`, including lists wrapped by package helpers
- removal of stale direct-dependency permissions after a Mix edge is deleted
- namespace references in `apps/*/lib/**/*.ex`, including the separately listed reference-only exceptions

It fails if an app introduces an out-of-policy dependency, retains a policy
permission after deleting the dependency, or references a cross-app namespace
outside its direct dependencies and explicit exceptions. Reference-only
exceptions permit source use but cannot authorize a new `mix.exs` edge. When an
explicit target policy differs from the current policy, target drift remains a
non-failing migration report.

## Runtime Ownership Rules

These ownership boundaries are review conventions; `mix lemon.quality` enforces
the dependency policy above, not these source-level rules:

- `lemon_router` may emit semantic `LemonCore.DeliveryIntent` values, but it may not construct `LemonChannels.OutboundPayload` values or reference Telegram renderer helpers directly.
- Automation binds supervision targets and submits terminal facts through the registered `LemonCore.ChannelSupervision` capability. Channels owns its implementation, durable admission, rendering and Outbox delivery. No consumer resolves a channels namespace or constructs platform payloads across this boundary.
- `lemon_channels` owns channel rendering and presentation state. It must not mutate inbound prompts for pending-compaction behavior.
- `lemon_gateway` owns execution slots and the native execution lifecycle. Router-owned queue semantics, chat-state readback for automatic-resume request mutation, and conversation-key selection must not move back into gateway. Router hands pre-resolved, engine-less `LemonCore.ExecutionCommand` values to `LemonCore.EngineRuntime`; gateway adapts them to its private `LemonGateway.ExecutionRequest` and invokes the fixed native executor. `LemonGateway.Runtime.submit/1` must not be reintroduced as a compatibility path. Default gateway startup is execution-only; gateway-native transport, command, SMS, and voice children require explicit `:gateway_ingress_enabled` configuration. Those surfaces are gateway-owned by design rather than pending migration — SMS, webhook, and voice do not fit `LemonChannels.Plugin`.
- Gateway-owned transports submit through `LemonCore.RouterBridge` when they need router normalization. They must not take a compile-time dependency on `LemonRouter.RunOrchestrator`.
- Router-owned active session state is only exposed through `LemonRouter.Router` and `LemonCore.RouterBridge`. External apps must not reference `LemonRouter.SessionRegistry` directly.
- Top-level requests and execution commands never validate or carry a runner identity. `engine: "lemon"` remains fixed run provenance in events and stores. `ResumeToken.engine` and historical `ChatState.last_engine` remain persisted discriminators; only native tokens may resume a top-level run, while non-native historical values are retained and quarantined from resume. Subagents execute natively in-process (`CodingAgent.Session` via `CodingAgent.Coordinator`); there is no external CLI runner registry. Router should use `LemonCore.Cwd` for default cwd resolution instead of `LemonGateway.Cwd`.
- Execution authorization is shared core language:
  `LemonCore.ToolPolicy` strictly validates supplied policy and
  `LemonCore.ExecutionContext` binds run lineage, principal/provenance,
  workspace, effective capabilities, and limits. Router layers and child
  execution use authority intersection; named nodes transport and revalidate
  only the versioned context rather than independently normalizing policy.
- Shared domains in `lemon_core` / `lemon_control_plane` must use typed wrappers such as `RunStore`, `ChatStateStore`, `PolicyStore`, and `ProjectBindingStore` instead of bypassing them with raw store helpers.
- Agent runtime registration and optional callback contracts live in `LemonCore.AgentRuntime`. Coding products register their provider at boot; control-plane methods, automation reviewers, channel commands and Web projections call the same core seam. Registry configuration belongs to `:lemon_core`; no consumer depends on the control plane to discover the running agent.
- The shared CLI registry dispatches Mix-free command modules in their owning apps. Its `lemon_channels` and `lemon_media` references are runtime-only so setup and other one-shot commands do not start channel services through an application dependency. Source Mix tasks are thin adapters; packaged runtime profiles include the same handlers.
- `coding_agent` declares a direct `lemon_mcp` dependency for native MCP capability discovery; `lemon_router` declares the same edge to reuse MCP HTTP origin validation during native follow-up admission. Both use `runtime: false`: the minimal and full runtime releases explicitly include `lemon_mcp: :load`, making these library modules available without starting an application callback. Consuming apps supervise any clients and transports they create. Origin validation stays in `lemon_mcp`, not duplicated in router or moved into dependency-free `lemon_core` / `lemon_ai`.

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
| Media job driver | `lemon_media` | `lemon_core`, `lemon_skills`, `lemon_router`, `lemon_control_plane` |
| LSP server driver | `lemon_lsp` | `lemon_core`, `coding_agent`, `lemon_control_plane` |
| Debug adapter (DAP) client | `coding_agent` | `lemon_core`, `lemon_control_plane` |
| omp delegate driver (RPC protocol, session processes, discovery, `omp` tool) | `lemon_omp` | `lemon_core`, `coding_agent`, `lemon_gateway`, `lemon_control_plane` |
| Native computer-use driver (LCU bridge, approval routing, `cua_js` tools) | `lemon_computer_use` | `lemon_core`, `coding_agent`, `lemon_control_plane` |
| Skill platform logic (manifest, registry, installer, lockfile, source router, audit) | `lemon_skills` | `coding_agent`, `lemon_core`, `lemon_router` |
| Coding-session prompt assembly and coding/file tool registration | `coding_agent` | `lemon_skills`, `lemon_core` |
| Assistant-platform tools (`remember`, `recall`, goal, kanban, media, skill tools) | `lemon_skills` | `coding_agent`, `lemon_core` |
| Execution policy and authority context contracts | `lemon_core` | Any product-specific app |
| Model/session routing | `lemon_router` | `coding_agent`, `lemon_skills` |
| Runtime boot, profile, health, env detection | `lemon_core/runtime` | Shell scripts (only thin wrappers allowed there) |

When a new module does not fit an existing domain, update this table before adding the module.
