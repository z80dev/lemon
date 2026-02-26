# Decoupling Model Selection from Profile Binding

## Problem
Profiles currently provide useful defaults (engine, tool policy, system prompt), but users need to choose model independently at runtime (task/agent/session) without being locked to profile model defaults.

## Goals
- Preserve profile-level behavior and policy defaults.
- Let callers specify model independently from profile.
- Keep explicit engine selection possible.
- Support clear precedence and mismatch visibility.

## Final Design

### 1) Canonical run contract now has top-level `model`
`LemonCore.RunRequest` now includes `:model` so model overrides can be passed explicitly (not only via `meta`).

### 2) Dedicated resolver module
Added `LemonRouter.ModelSelection` to centralize resolution:

- **Model precedence**:
  1. request-level explicit model
  2. meta model (back-compat)
  3. session policy model
  4. profile model
  5. router default model (`:lemon_router, :default_model`)

- **Engine precedence**:
  1. resume token engine
  2. explicit `engine_id`
  3. model-implied engine (`codex:*`, `claude:*`, etc.)
  4. profile default engine

### 3) Mismatch warnings (non-blocking)
If explicit engine conflicts with model-implied engine, the system:
- keeps explicit engine (caller intent wins),
- records warning in `job.meta[:model_resolution_warning]`,
- logs warning in orchestrator.

### 4) API/tool surface updates
- `agent` control-plane method accepts `model`.
- `agent.inbox.send` accepts `model`.
- `CodingAgent.Tools.Agent` accepts `model` and forwards it through `RunRequest.model`.
- `CodingAgent.Tools.Task` accepts `model` and `thinking_level` for internal-session subtasks.

## Why this works
Profiles continue to supply persona/tool defaults, while model selection is independently controlled by request/session/runtime layers.

## Validation policy
No hard failures for engine/model mismatches yet; warnings only. This avoids breaking existing flows while making conflicts visible.

## Future extensions
- Add strict mode to reject incompatible engine/model combinations.
- Add capability checks (e.g., tool-calling requirements vs selected model).
- Expose model-resolution diagnostics in run inspection APIs.
