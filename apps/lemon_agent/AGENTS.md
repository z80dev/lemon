# LemonAgent contributor guide

`lemon_agent` owns the agent loop, supervised agents/tools, context projection,
model runtime and credential resolution. Provider wire protocols live in
`lemon_ai`; coding session persistence and filesystem tools live in `coding_agent`.
See [README](README.md) for usage and [BEAM invariants](../../docs/beam_agents.md).

## Boundaries

- `LemonAgent` is the lifecycle facade; `LemonAgent.Agent` owns steering,
  follow-up queues and state mutation. Supply a `convert_to_llm` callback when
  custom message types need explicit projection; the default filters ordinary
  user/assistant/tool-result roles.
- `ModelRuntime` resolves Lemon config and concrete credentials before calling
  `lemon_ai`. Provider OAuth helpers may refresh encoded payloads, but credential
  persistence is injected here. Do not teach provider modules about Lemon config.
- Workspace goal/kanban state belongs here, not in core's generic Store API.
  Optional integrations register through `ContextRegistry` and `ToolRegistry`;
  the platform must not depend on a satellite integration.

## Lifecycle and trust

- Agent loops and tools run under `LoopTaskSupervisor` and `ToolTaskSupervisor`.
  Tool crashes become tool errors, not agent-loop crashes or implicit retries.
- Abort is cooperative: tools check `AbortSignal.aborted?/1`; loops check before
  model calls and tool batches. Cleanup must account for external work that can
  briefly outlive the signal.
- `AbortSignal.TableOwner` owns the ETS table; preserve table ownership across
  restart rather than letting an arbitrary short-lived caller own it.
- Event streams are bounded and owned. Owner death cancels the attached task;
  consumers that outlive a producer must choose the caller as owner.
- `{:agent_end, messages}` contains only the new messages, not full history.
- Steering/follow-up polling calls back into the Agent. Preserve the bounded
  queue-call timeout and acknowledge follow-up enqueueing before returning.
  Callers that must release a blocked join only after delivery rely on that
  acknowledgement; queueing does not start a new loop after a terminal event.
- Context truncation preserves chronological order. Assistant tool calls and
  contiguous results are one unit: keep or drop the whole unit. Bookends obeys
  both message and character hard limits.
- Tool invocation does not confer trust. Mark data-bearing output using
  `ToolResultTrust`; the coding-session pre-LLM transform applies the fence.
  Tool-returned metadata is not evidence that the transform has run.
- Introspection records lifecycle metadata, never prompt/response content.

## Workspace and contributor invariants

- Kanban terminal writes require the exact lease ID. Complete/fail/reclaim via
  the lease-guarded APIs; stale workers must not mutate newly leased tasks.
  Board-scoped locking serializes task read-modify-write and claim operations.
- A restarting dispatcher reclaims only unsubmitted leases. Tracked kanban router
  runs retain their exact lease until completion or confirmed cancellation.
- Context contributors are bounded in time and size. Stable session context
  belongs in the system prefix; volatile turn-local context belongs on the user
  message. Do not let network latency or a cache refresh block every turn.

## Package and verification

This is one of the five package targets. The repository has 0.2.0; it is not yet
published. Keep `mix.exs` self-contained in its tarball: no reads outside the app.
Sibling dependencies use the existing `lemon_deps/1` rewrite for consumers.
See [package status](../../docs/platform-split.md) and
[release checks](../../docs/release/hex-packages.md).

From the umbrella root:

```bash
mix test apps/lemon_agent/test
```

Prefer isolated supervised agents and deterministic providers. Restore any
shared application env/registries modified by tests; tag live-provider cases as
integration. For package metadata changes, use `scripts/verify_packages`.
