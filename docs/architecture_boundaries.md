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
| `lemon_channels` | `lemon_core`, `lemon_gateway` |
| `lemon_control_plane` | `ai`, `lemon_automation`, `lemon_channels`, `lemon_core`, `lemon_router`, `lemon_skills` |
| `lemon_core` | *(none)* |
| `lemon_gateway` | `agent_core`, `coding_agent`, `lemon_core` |
| `lemon_router` | `agent_core`, `coding_agent`, `lemon_channels`, `lemon_core`, `lemon_gateway` |
| `lemon_skills` | `agent_core`, `ai`, `lemon_core` |

## Enforcement

Run:

```bash
mix lemon.quality
```

The architecture checker reads `apps/*/mix.exs` and fails if any app introduces a direct `in_umbrella: true` dependency outside this policy.
