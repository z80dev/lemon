Here’s a meticulous, implementation‑ready plan aimed at a junior dev. It’s organized as phases with concrete file touch‑points, explicit steps, acceptance checks, and test
  guidance. I’m assuming we want to fully leverage BEAM for agents/sessions/subagents and avoid rewrites.

  Assumptions

  - We will keep the existing public APIs intact unless a change is clearly justified.
  - Subagents should be first‑class BEAM processes, not just prompt templates.
  - We will align AgentCore streaming behavior with Ai streaming behavior.
  - We will introduce a coordinator in CodingAgent (not AgentCore) to orchestrate subagents.

  Non‑goals (for now)

  - UI changes (TUI/Web) beyond emitting the necessary events.
  - Multi‑node distribution and cluster discovery.
  - Pricing/model metadata changes.

  ———

  Phase 0 — Document invariants and current behavior (1–2 files, low risk)
  Goal: make behavior explicit so future changes are safe.

  - Add a short “BEAM invariants” section to README.md or a new doc like docs/beam_agents.md.
  - List the invariants we will enforce:
      - Agent loops must be supervised tasks.
      - Agent event streams must be bounded and cancelable.
      - Subagents must be registered, discoverable, and supervised.
      - Coordinators must cancel subagents on timeout or parent termination.
  - Acceptance: doc exists and matches actual behavior after Phases 1–3.

  ———

  Phase 1 — Supervise agent loops and register subagents (core BEAM plumbing)
  Goal: all agent execution is supervised and discoverable.

  1. Add supervision infrastructure in AgentCore.Application

  - Update apps/agent_core/lib/agent_core/application.ex to start:
      - AgentCore.AgentRegistry (a Registry)
      - AgentCore.SubagentSupervisor (a DynamicSupervisor)
      - AgentCore.LoopTaskSupervisor (a Task.Supervisor)
  - This provides the BEAM “backbone” for subagent lifecycle and loop tasks.

  2. Implement AgentCore.AgentRegistry

  - New file apps/agent_core/lib/agent_core/agent_registry.ex.
  - Define functions:
      - register/2 and lookup/1 helpers to wrap Registry calls.
  - Use names like {session_id, role, index} for keys.
  - Acceptance: can register a PID and look it up.

  3. Implement AgentCore.SubagentSupervisor

  - New file apps/agent_core/lib/agent_core/subagent_supervisor.ex.
  - Provide start_subagent/1 to start an AgentCore.Agent with a child spec.
  - Ensure children are :temporary unless you want auto‑restart.

  4. Ensure agent loops are supervised

  - Update apps/agent_core/lib/agent_core/loop.ex:
      - Replace Task.start with Task.Supervisor.start_child(AgentCore.LoopTaskSupervisor, fn -> ... end).
  - Update apps/agent_core/lib/agent_core/agent.ex:
      - Replace Task.async with supervised tasks (use Task.Supervisor.async_nolink/2 or start_child + Task pattern).
      - Store and monitor the task; decide if agent should treat task exits as errors.

  Acceptance

  - If a loop task crashes, it’s visible under the supervisor.
  - If the agent dies, loop tasks terminate cleanly.

  Tests

  - New tests in apps/agent_core/test/agent_core/loop_test.exs or similar to assert supervision behavior.
  - Update existing tests if they assume direct Task.start.

  ———

  Phase 2 — Bring AgentCore.EventStream to parity with Ai.EventStream
  Goal: bounded, cancelable, owner‑monitored stream for agent events.

  1. Decide the strategy

  - Recommended: extend AgentCore.EventStream to mirror the API of Ai.EventStream.
  - Avoid reusing Ai.EventStream directly because event types are different.

  2. Implement features in apps/agent_core/lib/agent_core/event_stream.ex

  - Add options: :owner, :max_queue, :drop_strategy, :timeout.
  - Add attach_task/2 and cancel/2 APIs.
  - Convert push/2 to use GenServer.call for backpressure (like Ai).
  - Keep push_async/2 for fire‑and‑forget.
  - Update events/1 to include terminal events and honor cancellation.
  - Add stats/1 for queue metrics (optional but useful for debugging).

  3. Update call sites

  - apps/agent_core/lib/agent_core/loop.ex should start streams with owner + timeout.
  - apps/agent_core/lib/agent_core/agent.ex should propagate cancel or owner death to the stream.
  - apps/agent_core/lib/agent_core/proxy.ex should use push/2 if it needs backpressure; otherwise keep push_async/2.

  Acceptance

  - Queue is bounded.
  - When owner dies or cancel is invoked, stream terminates and tasks are stopped.
  - result/2 returns error on cancellation/timeout.

  Tests

  - Add/extend tests in apps/agent_core/test/agent_core/event_stream_test.exs:
      - queue overflow behavior
      - cancellation path
      - owner death path
      - timeout handling

  ———

  Phase 3 — Subagents as processes + Coordinator orchestration
  Goal: real subagents with lifecycle, not only prompts.

  1. Add CodingAgent.Coordinator

  - New file apps/coding_agent/lib/coding_agent/coordinator.ex.
  - Responsibilities:
      - Spawn N subagents (AgentCore agents or CodingAgent sessions).
      - Send prompts to each.
      - Collect results with timeout.
      - Aggregate results (best‑of, quorum, merge).
      - Cancel remaining subagents if one wins.

  2. Pick a subagent model (make it explicit in code comments)
     Option A (lighter): Use AgentCore.Agent directly.

  - Faster, no persistence, better for internal orchestration.
    Option B (heavier): Use CodingAgent.Session so tools and persistence are identical.
  - More consistent but slower.

  Recommended initial path: Option B for compatibility.

  - Use CodingAgent.SessionSupervisor to start subagent sessions.
  - Register each subagent session in CodingAgent.SessionRegistry with role metadata.

  3. Wire subagent “roles”

  - Use existing prompt templates from CodingAgent.Subagents:
      - Prepend subagent prompt to task prompt.
  - This keeps behavior compatible with the existing task tool.

  4. Integrate with task tool

  - Update apps/coding_agent/lib/coding_agent/tools/task.ex to optionally route to CodingAgent.Coordinator.
  - If subagent param is set, call coordinator to run that subagent type.
  - Keep current behavior as fallback (feature flag or config guard).

  5. Coordinator details

  - Give each subagent an ID and register it in the registry for tracking.
  - Monitor subagent processes; if parent dies, cancel children.
  - Use timeouts to avoid hanging subagents.

  Acceptance

  - Coordinator can fan‑out to multiple subagents and return aggregate result.
  - Subagents are discoverable via registry keys.
  - Cancel/timeout cleans up subagent processes.

  Tests

  - New tests in apps/coding_agent/test/coding_agent/coordinator_test.exs:
      - spawns N subagents
      - times out and cancels
      - returns results correctly

  ———

  Phase 4 — Centralize provider concurrency / rate limiting
  Goal: BEAM control over outbound calls.

  1. Add dispatcher modules in apps/ai/lib/ai/

  - call_dispatcher.ex, rate_limiter.ex, circuit_breaker.ex (simple GenServers).
  - Start them in Ai.Application.

  2. Route Ai.stream/3 through dispatcher

  - Update apps/ai/lib/ai.ex so stream/3 calls dispatcher.
  - Dispatcher enforces:
      - concurrency caps by provider
      - token bucket rate limit
      - circuit open/half‑open/closed states

  3. Integrate with providers

  - Providers remain unchanged; dispatcher decides whether to invoke them.
  - Return structured errors {:error, :rate_limited} or {:error, :circuit_open}.

  Acceptance

  - Under load, concurrency caps are enforced.
  - Rate limiter prevents abusive bursts.

  Tests

  - Add tests in apps/ai/test/ai/call_dispatcher_test.exs:
      - concurrency cap honored
      - rate limit triggers
      - circuit breaker opens after repeated failures

  ———

  Phase 5 — Telemetry and observability
  Goal: visibility into BEAM behavior.

  - Add :telemetry events for:
      - agent loop start/end
      - subagent spawn/end
      - event stream queue depth
      - dispatcher queue depth and rejection counts
  - Use these in future dashboards or dev logs.

  Acceptance

  - All key lifecycle events emit telemetry.

  ———

  Sequencing and hand‑offs

  - Implement in order: Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 5.
  - After each phase:
      - Update docs.
      - Run targeted tests only, avoid whole umbrella unless needed.

  ———

  Concrete file checklist (minimum)

  - apps/agent_core/lib/agent_core/application.ex
  - apps/agent_core/lib/agent_core/agent_registry.ex (new)
  - apps/agent_core/lib/agent_core/subagent_supervisor.ex (new)
  - apps/agent_core/lib/agent_core/loop.ex
  - apps/agent_core/lib/agent_core/agent.ex
  - apps/agent_core/lib/agent_core/event_stream.ex
  - apps/coding_agent/lib/coding_agent/coordinator.ex (new)
  - apps/coding_agent/lib/coding_agent/tools/task.ex
  - apps/ai/lib/ai/application.ex
  - apps/ai/lib/ai.ex
  - apps/ai/lib/ai/call_dispatcher.ex (new)
  - apps/ai/lib/ai/rate_limiter.ex (new)
  - apps/ai/lib/ai/circuit_breaker.ex (new)
