# Lemon Stack Reshape

Status: executed (all workstreams landed on `reshape/stack-2026-07`)

Last reviewed: 2026-07-02

## Thesis

Lemon is the BEAM-native stack for LLM interactions: a layered set of libraries
with two showcase products on top.

```
ai            — provider-agnostic LLM client (standalone; no umbrella deps)
agent_core    — agent loop, tools, CLI-runner protocol (depends on ai, lemon_core)
lemon_core    — true foundation only: config, store, secrets, bus/event, telemetry
──────────────────────────────────────────────────────────────────────────────
products:
  assistant   — channels, gateway, router, control plane, skills, coding agent
  LemonSim    — deterministic model-vs-model simulation arena (the flagship)
```

The sim arena is the differentiator: a deterministic, event-sourced,
replay-verified benchmark harness with 19 scenarios and a spectator UI. The
assistant competes with feature-parity products (Hermes Agent et al.); the
arena competes with nothing comparable. Positioning, docs, and investment lead
with the arena; the assistant demonstrates the same stack in production shape.

## Why reshape

Diagnosis (2026-07-02, whole-repo review):

- `lemon_core` (44k lines) accreted feature logic that belongs above it:
  onboarding wizards, doctor, browser/media/LSP drivers, kanban/goal stores,
  model policy and routing feedback, a Hermes data importer. The
  `router_bridge` shim exists only to call upward without a compile dep —
  direct evidence of inverted layering.
- `lemon_ai_runtime` is a stalled extraction: 2.2k lines of `defdelegate`
  shadowing `Ai.*`, six duplicated OAuth module names, and a provider-routing
  "preview" that was never wired to dispatch.
- Two dependency edges exist for a single call site each:
  `lemon_router → coding_agent` (async task surface projection) and
  `lemon_skills → lemon_channels` (borrowing the X API HTTP client).
- A native run passes through five nested loop layers
  (Gateway.Engine → CliRunner → CodingAgent.Session → AgentCore.Agent →
  AgentCore.Loop); the native engine should not cosplay as a subprocess.
- `coding_agent` (62k lines) is one-third coding agent, two-thirds accreted
  assistant platform (media generation, social tools, PKM/memory).

## Workstreams

Each workstream lands as one verified commit: `mix compile
--warnings-as-errors`, targeted tests, `mix lemon.quality`, and the full
`mix test --exclude integration --cover` suite at milestones.

1. **W1 — remove `lemon_ai_runtime`.** Repoint consumers at `Ai.*`; rehome the
   handful of genuinely new modules (credentials, provider status, stream
   options) where their consumers live. Update architecture policy, AGENTS.md,
   docs.
2. **W2a — router/coding_agent seam.** Define the async-task-surface contract
   in `lemon_core` (struct + bus event); `coding_agent` publishes,
   `lemon_router` consumes; drop the dep.
3. **W2b — X API client extraction.** Move the X/Twitter HTTP client + OAuth
   token manager below both consumers; `lemon_skills` loses its
   `lemon_channels` dep.
4. **W3a — routing intelligence out of `lemon_core`.** Landed with two
   corrections to the original premise: `model_policy*` moved to
   `lemon_channels` (its only runtime consumers are the channel adapters,
   not the router); `routing_feedback_store` + `rollout_gate` moved to
   `lemon_router`, with the store now supervised there (it was previously
   never started — a dormant feature) and fed by a `"routing_feedback"` Bus
   event from `MemoryIngest` instead of a downward call. `router_bridge`
   stays: it is the sanctioned dependency inversion for channels/gateway →
   router upcalls (`lemon_router` already depends on `lemon_channels`, so
   the reverse edge must be runtime-bound). Mix task names `lemon.policy`
   and `lemon.feedback` are unchanged.
5. **W3b — `lemon_cli` app.** Onboarding, setup wizard, doctor, and the Hermes
   importer (a user-facing migration feature, not cruft) move out of
   `lemon_core` into a CLI/ops app at the top of the graph.
6. **W3c+ — capability drivers.** Browser, media jobs, LSP manager move to
   their consumers (mostly `coding_agent`) as follow-ups.
7. **W4 — collapse the native loop path.** `LemonGateway.Engines.Lemon` drives
   `CodingAgent.Session` directly; the CLI-runner protocol remains only for
   actual external CLIs.
8. **W5 — split `coding_agent`.** Media/social/PKM tools out to the skills
   layer; the eval harness to its own app.
9. **W6 — positioning.** Root README rewritten around the stack thesis with
   the arena as flagship; `lemon_sim` README with the scorecard/replay story.
10. **W10 — approvals through native gateway events.** Pending tool
    approvals surface as kind-`approval` action_events (session subscribes
    to `exec_approvals`, RunTranslator maps request/resolve, coalescer +
    renderer display them); the approve/deny round-trip stays on the
    existing `exec_approvals` channel flows.

## Closed decisions

- **Doctor stays in `lemon_core`.** It probes optional capability apps
  (browser/media/LSP) at runtime with unavailable-fallbacks — the one
  sanctioned soft-probe site; moving it to `lemon_cli` would drag runtime
  probing into an ops app for no boundary gain.
- **`RouterBridge` is a port, not a smell.** It is the single sanctioned
  upcall seam from channels/gateway into the router and is configured by
  `LemonRouter.Application` at boot.

## Rules of engagement

- Deletion before restructuring; every new boundary lands in
  `LemonCore.Quality.ArchitecturePolicy` the same change that creates it.
- No new umbrella app unless at least two apps need the code below them.
- Docs that describe moved modules are updated in the same commit
  (`mix lemon.quality` docs checks enforce catalog freshness).
