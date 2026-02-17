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
| `lemon_control_plane` | `ai`, `coding_agent`, `lemon_automation`, `lemon_channels`, `lemon_core`, `lemon_router`, `lemon_skills` |
| `lemon_core` | *(none)* |
| `lemon_gateway` | `agent_core`, `ai`, `coding_agent`, `lemon_automation`, `lemon_channels`, `lemon_core` |
| `lemon_router` | `agent_core`, `ai`, `coding_agent`, `lemon_channels`, `lemon_core`, `lemon_gateway` |
| `lemon_skills` | `agent_core`, `ai`, `lemon_core` |

## Enforcement

Run:

```bash
mix lemon.quality
```

The architecture checker enforces both:
- direct umbrella dependencies from `apps/*/mix.exs`
- namespace references in `apps/*/lib/**/*.ex` (forbidden cross-app module usage)

It fails if any app introduces either an out-of-policy direct dependency or an out-of-policy cross-app namespace reference.
