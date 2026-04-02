# Architecture Boundaries

Lemon enforces direct umbrella dependencies by app. This keeps the harness modular and prevents layer drift.

## Direct Dependency Policy

<!-- architecture_policy:start -->
| App | Allowed direct umbrella deps |
| --- | --- |

| `agent_core` | `ai`, `lemon_core` |
| `ai` | `lemon_core` |
| `coding_agent` | `agent_core`, `ai`, `lemon_core`, `lemon_skills` |
| `coding_agent_ui` | `coding_agent` |
| `lemon_ai_runtime` | `ai`, `lemon_core` |
| `lemon_automation` | `lemon_core`, `lemon_router` |
| `lemon_channels` | `lemon_core` |
| `lemon_control_plane` | `ai`, `coding_agent`, `lemon_automation`, `lemon_channels`, `lemon_core`, `lemon_gateway`, `lemon_router`, `lemon_skills` |
| `lemon_core` | *(none)* |
| `lemon_gateway` | `agent_core`, `ai`, `coding_agent`, `lemon_automation`, `lemon_channels`, `lemon_core` |
| `lemon_mcp` | `agent_core`, `coding_agent` |
| `lemon_router` | `agent_core`, `ai`, `coding_agent`, `lemon_channels`, `lemon_core`, `lemon_gateway` |
| `lemon_services` | *(none)* |
| `lemon_sim` | `agent_core`, `ai`, `lemon_core` |
| `lemon_sim_ui` | `lemon_core`, `lemon_sim` |
| `lemon_skills` | `agent_core`, `ai`, `lemon_channels`, `lemon_core` |
| `lemon_web` | `lemon_core`, `lemon_router` |
| `market_intel` | `agent_core`, `lemon_channels`, `lemon_core` |
<!-- architecture_policy:end -->

## Enforcement

Run:

```bash
mix lemon.quality
```

The architecture checker enforces both:
- direct umbrella dependencies from `apps/*/mix.exs`
- namespace references in `apps/*/lib/**/*.ex` (forbidden cross-app module usage)

It fails if any app introduces either an out-of-policy direct dependency or an out-of-policy cross-app namespace reference.

## Runtime Ownership Rules

The refactor quality rules also enforce a few concrete ownership boundaries:

- `lemon_router` may emit semantic `LemonCore.DeliveryIntent` values, but it may not construct `LemonChannels.OutboundPayload` values or reference Telegram renderer helpers directly.
- `lemon_channels` owns channel rendering and presentation state. It must not mutate inbound prompts for pending-compaction behavior.
- `lemon_gateway` owns execution slots and engine lifecycle. Router-owned queue semantics, chat-state readback for auto-resume request mutation, and conversation-key selection must not move back into gateway. `ExecutionRequest` values must arrive with a pre-resolved `conversation_key`, and `LemonGateway.Runtime.submit/1` must not be reintroduced as a legacy compatibility path.
- Gateway-owned transports submit through `LemonCore.RouterBridge` when they need router normalization. They must not take a compile-time dependency on `LemonRouter.RunOrchestrator`.
- Router-owned active session state is only exposed through `LemonRouter.Router` and `LemonCore.RouterBridge`. External apps must not reference `LemonRouter.SessionRegistry` or `LemonRouter.SessionReadModel` directly.
- Router and channels should validate engine IDs through `LemonCore.EngineCatalog`. Router should use `LemonCore.Cwd` for default cwd resolution instead of `LemonGateway.Cwd`.
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
| Skill platform logic (manifest, registry, installer, lockfile, source router, audit) | `lemon_skills` | `coding_agent`, `lemon_core`, `lemon_router` |
| Prompt assembly and tool registration | `coding_agent` | `lemon_skills`, `lemon_core` |
| Model/session routing | `lemon_router` | `coding_agent`, `lemon_skills` |
| Runtime boot, profile, health, env detection | `lemon_core/runtime` | Shell scripts (only thin wrappers allowed there) |

When a new module does not fit an existing domain, update this table before adding the module.
