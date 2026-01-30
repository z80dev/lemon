# BEAM Subagent Architecture Plan (Lemon)

## Executive Summary
Your current implementation is already compatible with BEAM-first goals for coordinating many remote LLM calls: you have GenServers for agents/sessions, supervised streaming tasks, and bounded stream queues in `Ai.EventStream`. The missing pieces for full "subagent + coordinator" flows are:

- A supervised, registered session/agent lifecycle (for discovery, routing, and crash recovery).
- A centralized provider call dispatcher with rate limiting and circuit breaking.
- Consistent backpressure across all event streams (not just provider streams).

This document proposes a minimal, incremental architecture to add those capabilities without a rewrite.

---

## Current Compatibility Snapshot (What You Already Have)

Strong alignment
- Provider streaming is supervised with `Task.Supervisor` and bounded queues (`Ai.EventStream`).
- Agents and sessions are GenServers with queues, abort support, and streaming events.
- Provider registry is fast and crash-resilient via `:persistent_term`.

Gaps
- Sessions are started directly (not under `DynamicSupervisor`), so crash recovery and lifecycle control are limited.
- No `Registry` for session/subagent discovery or routing.
- `AgentCore.EventStream` is unbounded and can grow indefinitely under slow consumers.
- Retry/backoff and concurrency limits are provider-specific, not centralized or policy-driven.

---

## Target Design: Subagents + Coordinator

Conceptual roles
- Coordinator: orchestrates tasks, spawns subagents, aggregates results.
- Subagent: an `AgentCore.Agent` process with isolated state and tools.
- Provider dispatcher: enforces rate limits, concurrency caps, and circuit breaker policy for outbound calls.

High-level flow
1. Coordinator receives a task.
2. Coordinator spawns subagents via a `DynamicSupervisor`.
3. Each subagent streams its own response via `Ai.EventStream`.
4. Coordinator aggregates results and applies policy (quorum, best-of, merge, etc.).
5. Provider dispatcher throttles outbound requests and manages retries/failover.

---

## Proposed Supervision Tree (Umbrella Apps)

apps/ai
```
Ai.Application
  ├─ Ai.StreamTaskSupervisor (existing)
  ├─ Ai.CallDispatcher       (new: GenServer or GenStage)
  ├─ Ai.RateLimiter          (new: GenServer + ETS)
  └─ Ai.CircuitBreaker       (new: GenServer + ETS)
```

apps/agent_core
```
AgentCore.Application
  ├─ AgentCore.AgentRegistry     (new: Registry)
  ├─ AgentCore.SubagentSupervisor (new: DynamicSupervisor)
  └─ AgentCore.LoopTaskSupervisor (new: Task.Supervisor)
```

apps/coding_agent
```
CodingAgent.Application
  ├─ CodingAgent.SessionRegistry   (new: Registry)
  ├─ CodingAgent.SessionSupervisor (existing: DynamicSupervisor)
  └─ CodingAgent.Coordinator       (new: GenServer)
```

Notes
- `SessionSupervisor` already exists; start sessions through it.
- Add `Registry` so sessions and subagents can be addressed by `:via`.
- `LoopTaskSupervisor` makes loop execution supervised and restartable.

---

## Provider Call Dispatcher (Core BEAM Value)

Responsibilities
- Enforce per-provider concurrency caps.
- Apply rate limits per API key / model / provider.
- Implement circuit breaker (open/half-open/closed).
- Normalize retries and backoff across providers.

Where to integrate
- Route `Ai.stream/3` through a dispatcher.
- Dispatcher checks `RateLimiter` and `CircuitBreaker` before calling provider modules.
- On rejection, return structured errors like `{:error, :rate_limited}` or `{:error, :circuit_open}`.

Suggested new modules
- `apps/ai/lib/ai/call_dispatcher.ex`
- `apps/ai/lib/ai/rate_limiter.ex`
- `apps/ai/lib/ai/circuit_breaker.ex`

Backpressure strategy
- Use bounded queues inside dispatcher (per provider or per key).
- Prefer `GenStage` if you want demand-based flow; otherwise a GenServer with `:queue` is enough.

---

## Subagent Spawning and Coordination

Minimal coordinator API
- `Coordinator.run(task, opts)`
  - spawn N subagents
  - await responses with timeout
  - aggregate results

Subagent process model
- Thin wrapper around `AgentCore.Agent` to standardize boot:
  - inherit model/tools from parent
  - set `session_id` and tags
  - optionally restrict tools

Registry usage
- Register subagents by `{session_id, role, index}`:
  - `{:via, Registry, {AgentCore.AgentRegistry, {session_id, role, i}}}`

This enables
- broadcasting to all agents in a session
- lookup by role
- debug introspection

---

## Fix: Unbounded Agent Stream

`AgentCore.EventStream` is unbounded. For parity with provider streams:
- Option A: add `max_queue` and `drop_strategy` options.
- Option B: reuse `Ai.EventStream` and align event types.

Either way, this prevents runaway memory usage during heavy fan-out.

---

## Retry and Backoff Policy (Centralize)

Current: providers implement retries inconsistently.
Target: one retry policy in `Ai.CallDispatcher` (or shared middleware).

Recommended policy
- Exponential backoff with jitter.
- Respect server-provided `retry-after` headers.
- Cap retries per request by settings (from `CodingAgent.SettingsManager`).

This gives consistent behavior regardless of provider-specific code paths.

---

## Practical Subagent Flows (Examples)

1) Fan-out and best response
- Coordinator spawns 3 subagents with different strategies.
- Returns the response with the highest score/heuristic.

2) Parallel tool delegation
- One subagent handles search, another handles file ops, another handles synthesis.
- Coordinator merges results and returns a combined answer.

3) Adaptive provider fallback
- Dispatcher tries primary provider -> fallback provider if circuit open or rate limited.

---

## Minimal Stepwise Implementation Plan

Phase 0: Supervision and registry
- Start sessions under `CodingAgent.SessionSupervisor`.
- Add `CodingAgent.SessionRegistry` and register sessions by `session_id`.
- Add `AgentCore.SubagentSupervisor` and `AgentCore.AgentRegistry`.

Phase 1: Call dispatcher
- Add `Ai.CallDispatcher` and route `Ai.stream/3` through it.
- Implement concurrency caps per provider.

Phase 2: Rate limiter and circuit breaker
- ETS-backed token bucket with per-key/model/provider buckets.
- Circuit breaker state with open/half-open/closed transitions.

Phase 3: Coordinator and subagents
- `CodingAgent.Coordinator` spawns subagents and merges results.
- Add aggregation policies (best-of, quorum, merge).

---

## Suggested Module Layout (New Files)

- `apps/ai/lib/ai/call_dispatcher.ex`
- `apps/ai/lib/ai/rate_limiter.ex`
- `apps/ai/lib/ai/circuit_breaker.ex`
- `apps/agent_core/lib/agent_core/agent_registry.ex`
- `apps/agent_core/lib/agent_core/subagent_supervisor.ex`
- `apps/agent_core/lib/agent_core/subagent.ex`
- `apps/coding_agent/lib/coding_agent/session_registry.ex`
- `apps/coding_agent/lib/coding_agent/coordinator.ex`

---

If you want, I can turn this plan into concrete code changes (supervision tree + dispatcher + registry) as a first PR-sized slice. The smallest impactful change is: SessionRegistry plus supervised session startup, followed by CallDispatcher.
