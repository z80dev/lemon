# BEAM Agent + Session Improvements Plan

## Goals
- Strengthen BEAM usage for tools, session events, and agent discovery.
- Improve fault isolation and backpressure without rewriting core APIs.
- Keep changes incremental and testable.

## Non-Goals (for this plan)
- Reworking provider APIs or model config.
- UI/CLI redesigns.
- Large protocol changes in RPC.

## Scope
Focus areas:
1) Supervised tool execution
2) Backpressure for session event fan-out
3) Registry coverage for primary agents
4) Optional per-session supervision tree
5) Telemetry and diagnostics

---

## Phase 0 — Baseline Inventory (1–2 commits)
**Outcome:** Concrete understanding of current behavior and risks.

Tasks:
- Document current tool execution path and failure handling.
- Document session event fan-out behavior and potential mailbox growth.
- Add a short checklist for regression testing in `docs/beam_agents.md`.

Files:
- `docs/beam_agents.md`
- `apps/agent_core/lib/agent_core/loop.ex`
- `apps/coding_agent/lib/coding_agent/session.ex`

Acceptance:
- Documentation updated with current flows and risks.

---

## Phase 1 — Supervise Tool Execution (High ROI)
**Problem:** Tool execution uses `spawn/1` and manual monitors; failures are not supervised.

**Solution:** Run tool tasks under a supervisor and link them to the loop/stream lifecycle.

Tasks:
- Add a dedicated supervisor (preferred) or reuse `AgentCore.LoopTaskSupervisor`.
- Replace `spawn/1` with `Task.Supervisor.start_child/2` and retain monitor tracking.
- Ensure abort/cancel triggers `Task.shutdown/2` or task termination when possible.
- Emit telemetry for tool task start/end/aborts.

Implementation details:
- `apps/agent_core/lib/agent_core/loop.ex`
  - Replace tool task spawn with:
    - `Task.Supervisor.start_child(AgentCore.LoopTaskSupervisor, fn -> ... end)`
  - Store task pid and monitor ref in `pending_by_ref`.
  - On `abort`, terminate any remaining tool tasks.
- `apps/agent_core/lib/agent_core/application.ex`
  - (If desired) add `AgentCore.ToolTaskSupervisor` and use it for tool tasks.

Acceptance:
- Tool tasks show up under a supervisor in `:observer`/`Supervisor.which_children/1`.
- Tool failures are visible to supervision tooling and do not leak processes.

Tests:
- New test that forces a tool task crash and asserts cleanup.
- New test that aborts mid-tools and verifies tasks are terminated.

---

## Phase 2 — Backpressure for Session Event Fan-Out
**Problem:** `CodingAgent.Session` broadcasts directly via `send/2`. Slow listeners can bloat mailboxes.

**Solution A (preferred, minimal API change):** Per-subscriber event stream.

Tasks:
- Add a lightweight `SessionEventStream` wrapper (or reuse `AgentCore.EventStream`).
- When a subscriber registers, spawn an event stream with bounded queue.
- On `broadcast_event/2`, push into each subscriber stream.
- Expose events to consumers by returning the stream pid (or keep existing subscribe API but add opt-in).

Implementation details:
- `apps/coding_agent/lib/coding_agent/session.ex`
  - Add `:event_streams` to state.
  - Add new API (or optional argument): `subscribe(session, mode: :stream)`.
  - For legacy behavior, keep `send/2` path behind default.
- `apps/agent_core/lib/agent_core/event_stream.ex`
  - Ensure `max_queue`/`drop_strategy` used for session fan-out.

Acceptance:
- Under a slow subscriber, queue stays bounded and does not grow mailboxes unboundedly.
- Legacy subscribe behavior still works.

Tests:
- Simulate slow consumer; verify `AgentCore.EventStream.stats/1` shows bounded queue.
- Verify events arrive in order and terminal events propagate.

---

## Phase 3 — Register Main Agents in AgentRegistry
**Problem:** Subagents are registered; main agents are not, limiting introspection and routing.

**Solution:** Register main agent on session startup with `{session_id, :main, 0}`.

Tasks:
- Register main agent using `AgentCore.AgentRegistry.via/1` when starting the agent.
- Add optional metadata (model id, cwd, tools count).
- Unregister on termination (or rely on registry cleanup on process exit).

Implementation details:
- `apps/coding_agent/lib/coding_agent/session.ex`
  - Pass `name: AgentCore.AgentRegistry.via({session_id, :main, 0})` to `AgentCore.Agent.start_link/1`.

Acceptance:
- `AgentCore.AgentRegistry.list_by_session(session_id)` includes `{:main, 0, pid}`.

Tests:
- Test that main agent is registered and listed.

---

## Phase 4 — Per-Session Supervision Tree (Optional)
**Problem:** Session currently starts `AgentCore.Agent` directly; limited isolation of subcomponents.

**Solution:** Add a `CodingAgent.SessionRootSupervisor` per session.

Tasks:
- Introduce `SessionRootSupervisor` to supervise:
  - `CodingAgent.Session`
  - `AgentCore.Agent` (or a small adapter)
  - optional `CodingAgent.Coordinator` for subagents
- Adjust `SessionSupervisor.start_session/1` to start `SessionRootSupervisor` instead of session directly.
- Provide lookup helpers to get session pid.

Implementation details:
- New file: `apps/coding_agent/lib/coding_agent/session_root_supervisor.ex`
- Update: `apps/coding_agent/lib/coding_agent/session_supervisor.ex`
- Update: `apps/coding_agent/lib/coding_agent/session.ex` (start agent under root supervisor or via `start_link` adapter).

Acceptance:
- Session has a visible supervision subtree.
- Session crash does not bring down unrelated processes.

Tests:
- Start a session and assert child spec tree exists.
- Force agent crash; session remains alive (or recovers based on restart strategy).

---

## Phase 5 — Telemetry & Observability
**Problem:** We lack visibility into fan-out queues and tool task churn.

Tasks:
- Add telemetry for:
  - `[:agent_core, :tool_task, :start|:end|:error]`
  - `[:coding_agent, :session, :event_stream, :queue_depth]`
- Add optional `:telemetry_poller` for periodic queue and mailbox stats.

Files:
- `apps/agent_core/lib/agent_core/loop.ex`
- `apps/coding_agent/lib/coding_agent/session.ex`
- `apps/agent_core/lib/agent_core/event_stream.ex`

Acceptance:
- Metrics visible in `:telemetry` and can be observed in `tools/debug_cli`.

---

## Rollout Strategy
- Ship Phase 1 and Phase 2 first (largest reliability wins).
- Keep Phase 3 in same release if low-risk.
- Phase 4 and 5 can follow once metrics confirm behavior.

## Risk Notes
- Phase 1 may change tool task timing; ensure tool result ordering remains stable.
- Phase 2 introduces optional new API or behavior; keep legacy path default.
- Phase 4 introduces supervision changes; do this behind a feature flag if desired.

## Verification Checklist
- Start a session, run parallel tool calls, and verify no orphaned tasks.
- Add a slow subscriber and verify bounded event queues.
- Confirm main agent appears in registry.
- Ensure coordinator still spawns subagent sessions cleanly.

