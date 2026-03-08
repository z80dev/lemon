# Architecture Boundaries

Lemon enforces direct umbrella dependencies by app. This keeps the harness modular and prevents layer drift.

## Direct Dependency Policy

| App | Allowed direct umbrella deps |
| --- | --- |
| `agent_core` | `ai`, `lemon_core` |
| `ai` | `lemon_core` |
| `coding_agent` | `agent_core`, `ai`, `lemon_core`, `lemon_skills` |
| `coding_agent_ui` | `coding_agent` |
| `lemon_automation` | `lemon_core`, `lemon_router` |
| `lemon_channels` | `lemon_core` |
| `lemon_control_plane` | `ai`, `coding_agent`, `lemon_automation`, `lemon_channels`, `lemon_core`, `lemon_games`, `lemon_gateway`, `lemon_router`, `lemon_skills` |
| `lemon_core` | *(none)* |
| `lemon_games` | `lemon_core` |
| `lemon_gateway` | `agent_core`, `ai`, `coding_agent`, `lemon_automation`, `lemon_channels`, `lemon_core` |
| `lemon_mcp` | `agent_core`, `coding_agent` |
| `lemon_router` | `agent_core`, `ai`, `coding_agent`, `lemon_channels`, `lemon_core`, `lemon_gateway` |
| `lemon_sim` | `agent_core`, `ai`, `lemon_core` |
| `lemon_services` | *(none)* |
| `lemon_skills` | `agent_core`, `ai`, `lemon_channels`, `lemon_core` |
| `lemon_web` | `lemon_core`, `lemon_games`, `lemon_router` |
| `market_intel` | `agent_core`, `lemon_channels`, `lemon_core` |

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
