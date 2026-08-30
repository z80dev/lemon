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
| `coding_agent` | `lemon_agent`, `lemon_ai`, `lemon_browser`, `lemon_core`, `lemon_gateway`, `lemon_memory`, `lemon_platform_test`, `lemon_skills` | `lemon_agent`, `lemon_ai`, `lemon_browser`, `lemon_core`, `lemon_gateway`, `lemon_memory`, `lemon_platform_test`, `lemon_skills` | *(none)* |
| `coding_agent_ui` | `coding_agent`, `lemon_core` | `coding_agent`, `lemon_core` | *(none)* |
| `lemon_agent` | `lemon_ai`, `lemon_core` | `lemon_ai`, `lemon_core` | *(none)* |
| `lemon_ai` | *(none)* | *(none)* | *(none)* |
| `lemon_automation` | `lemon_agent`, `lemon_core`, `lemon_router`, `lemon_skills` | `lemon_agent`, `lemon_core`, `lemon_router`, `lemon_skills` | *(none)* |
| `lemon_browser` | `lemon_core` | `lemon_core` | *(none)* |
| `lemon_channels` | `lemon_agent`, `lemon_core`, `lemon_media` | `lemon_agent`, `lemon_core`, `lemon_media` | *(none)* |
| `lemon_cli` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_memory` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_memory` | *(none)* |
| `lemon_control_plane` | `lemon_agent`, `lemon_ai`, `lemon_automation`, `lemon_browser`, `lemon_channels`, `lemon_core`, `lemon_lsp`, `lemon_media`, `lemon_memory`, `lemon_router`, `lemon_skills` | `lemon_agent`, `lemon_ai`, `lemon_automation`, `lemon_browser`, `lemon_channels`, `lemon_core`, `lemon_lsp`, `lemon_media`, `lemon_memory`, `lemon_router`, `lemon_skills` | *(none)* |
| `lemon_core` | *(none)* | *(none)* | *(none)* |
| `lemon_evals` | `coding_agent`, `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_skills` | `coding_agent`, `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_skills` | *(none)* |
| `lemon_gateway` | `lemon_agent`, `lemon_core` | `lemon_agent`, `lemon_core` | `lemon_ai`, `lemon_automation` |
| `lemon_honcho` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_memory`, `lemon_platform_test` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_memory`, `lemon_platform_test` | *(none)* |
| `lemon_lsp` | `lemon_core` | `lemon_core` | *(none)* |
| `lemon_mcp` | `coding_agent`, `lemon_agent`, `lemon_core`, `lemon_skills` | `coding_agent`, `lemon_agent`, `lemon_core`, `lemon_skills` | *(none)* |
| `lemon_media` | `lemon_core` | `lemon_core` | *(none)* |
| `lemon_memory` | `lemon_core` | `lemon_core` | *(none)* |
| `lemon_platform_test` | `lemon_agent`, `lemon_ai`, `lemon_channels`, `lemon_core`, `lemon_memory` | `lemon_agent`, `lemon_ai`, `lemon_channels`, `lemon_core`, `lemon_memory` | *(none)* |
| `lemon_router` | `lemon_agent`, `lemon_ai`, `lemon_channels`, `lemon_core`, `lemon_media`, `lemon_memory` | `lemon_agent`, `lemon_ai`, `lemon_channels`, `lemon_core`, `lemon_media`, `lemon_memory` | *(none)* |
| `lemon_sim` | `lemon_agent`, `lemon_ai`, `lemon_core` | `lemon_agent`, `lemon_ai`, `lemon_core` | *(none)* |
| `lemon_sim_ui` | `lemon_ai`, `lemon_core`, `lemon_sim` | `lemon_ai`, `lemon_core`, `lemon_sim` | *(none)* |
| `lemon_skills` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_media`, `lemon_memory` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_media`, `lemon_memory` | *(none)* |
| `lemon_tcg` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_sim` | `lemon_agent`, `lemon_ai`, `lemon_core`, `lemon_sim` | *(none)* |
| `lemon_web` | `lemon_agent`, `lemon_automation`, `lemon_core`, `lemon_router` | `lemon_agent`, `lemon_automation`, `lemon_core`, `lemon_router` | *(none)* |
| `x_api` | `lemon_agent`, `lemon_ai`, `lemon_channels`, `lemon_core`, `lemon_platform_test` | `lemon_agent`, `lemon_ai`, `lemon_channels`, `lemon_core`, `lemon_platform_test` | *(none)* |
<!-- architecture_policy:end -->

## Enforcement

Run:

```bash
mix lemon.quality
```

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

The refactor quality rules also enforce a few concrete ownership boundaries:

- `lemon_router` may emit semantic `LemonCore.DeliveryIntent` values, but it may not construct `LemonChannels.OutboundPayload` values or reference Telegram renderer helpers directly.
- Automation-origin channel notifications may use `LemonRouter.ChannelsDelivery` as a narrow bridge into `LemonChannels`, but this must not become a router-owned rendering path. Router code must continue to avoid `OutboundPayload` construction and platform renderer helpers.
- `lemon_channels` owns channel rendering and presentation state. It must not mutate inbound prompts for pending-compaction behavior.
- `lemon_gateway` owns execution slots and the native execution lifecycle. Router-owned queue semantics, chat-state readback for automatic-resume request mutation, and conversation-key selection must not move back into gateway. Router hands pre-resolved, engine-less `LemonCore.ExecutionCommand` values to `LemonCore.EngineRuntime`; gateway adapts them to its private `LemonGateway.ExecutionRequest` and invokes the fixed native executor. `LemonGateway.Runtime.submit/1` must not be reintroduced as a compatibility path. Default gateway startup is execution-only; gateway-native transport, command, SMS, and voice children require explicit `:gateway_ingress_enabled` configuration. Those surfaces are gateway-owned by design rather than pending migration — SMS, webhook, and voice do not fit `LemonChannels.Plugin`.
- Gateway-owned transports submit through `LemonCore.RouterBridge` when they need router normalization. They must not take a compile-time dependency on `LemonRouter.RunOrchestrator`.
- Router-owned active session state is only exposed through `LemonRouter.Router` and `LemonCore.RouterBridge`. External apps must not reference `LemonRouter.SessionRegistry` or `LemonRouter.SessionReadModel` directly.
- Top-level requests and execution commands never validate or carry a runner identity. `engine: "lemon"` remains fixed run provenance in events and stores. `ResumeToken.engine` and historical `ChatState.last_engine` remain persisted discriminators; only native tokens may resume a top-level run, while non-native historical values are retained and quarantined from resume. Subagents execute natively in-process (`CodingAgent.Session` via `CodingAgent.Coordinator`); there is no external CLI runner registry. Router should use `LemonCore.Cwd` for default cwd resolution instead of `LemonGateway.Cwd`.
- Shared domains in `lemon_core` / `lemon_control_plane` must use typed wrappers such as `RunStore`, `ChatStateStore`, `PolicyStore`, and `ProjectBindingStore` instead of bypassing them with raw store helpers.

Run `mix lemon.quality` after boundary changes. It now checks both dependency policy and these architecture guardrails.

## Skill Source Taxonomy

Skills are classified by source kind. New source kinds must be added here before being used in code. Trust levels are frozen; the set may only be extended via a documented invariant update.

### Source Kinds

| Source kind | Description | Example identifier |
| --- | --- | --- |
| `builtin` | Bundled with the Lemon release. Never fetched from the network. | `builtin/commit-guide` |
| `local` | A directory on the local filesystem outside the installation. | `/path/to/my-skill` |
| `git` | A git repository cloned by URL. | `https://github.com/user/skill-repo` |
| `registry` | An entry from the official Lemon skill registry, addressed by namespace path. | `official/devops/k8s-rollout` |
| `well_known` | A curated community source with a stable short identifier (e.g. GitHub user/repo shorthand). | `gh:user/skill-repo` |

### Trust Levels

Trust levels control install/update policy and audit behavior. Ordered from highest to lowest trust:

| Trust level | Assigned to | Policy |
| --- | --- | --- |
| `builtin` | Source kind `builtin` only. | No audit required. Cannot be uninstalled. |
| `official` | Skills in the `official/` registry namespace. | Audit runs; `warn` verdicts require acknowledgement; `block` verdicts cannot be overridden. |
| `trusted` | Sources explicitly added to the user's trusted list. | Same audit policy as `official`. |
| `community` | All other `git`, `registry`, and `well_known` sources not in the trusted list. | Audit runs; `warn` verdicts require explicit approval; `block` verdicts cannot be overridden. |

`local` skills inherit the trust level of the install scope (`builtin` for bundled seeds, `trusted` when explicitly added by the user, `community` otherwise).

## Module Placement Rules

These rules complement the dependency policy table above. They must be respected when adding new modules.

| Domain | Canonical home | Forbidden locations |
| --- | --- | --- |
| Memory scope stores (session, workspace, agent, global) | `lemon_core` | Any other app |
| Browser capability driver | `lemon_browser` | `lemon_core`, `coding_agent`, `lemon_control_plane` |
| Media job driver | `lemon_media` | `lemon_core`, `lemon_skills`, `lemon_router`, `lemon_control_plane` |
| LSP server driver | `lemon_lsp` | `lemon_core`, `coding_agent`, `lemon_control_plane` |
| Skill platform logic (manifest, registry, installer, lockfile, source router, audit) | `lemon_skills` | `coding_agent`, `lemon_core`, `lemon_router` |
| Prompt assembly and tool registration | `coding_agent` | `lemon_skills`, `lemon_core` |
| Model/session routing | `lemon_router` | `coding_agent`, `lemon_skills` |
| Runtime boot, profile, health, env detection | `lemon_core/runtime` | Shell scripts (only thin wrappers allowed there) |

When a new module does not fit an existing domain, update this table before adding the module.
