# Missing Tests Plan

Author: Codex
Last reviewed: 2026-03-16

## Purpose

This is the authoritative implementation backlog for the highest-impact tests still missing from the Lemon repository.

This version reconciles the earlier Codex pass with follow-up Claude findings, then keeps only the candidates that are both:

1. actually under-tested in the current repo, and
2. worth implementing before lower-risk or already-adjacent-covered gaps.

The ranking favors externally exposed behavior, state machines, cleanup/error paths, routing correctness, and security-sensitive boundaries.

## What Was Intentionally Excluded

Some previously suggested items did not make the final top 20 because they were weaker than they first looked:

- `LemonGateway.Engines.CliAdapter`
  - already has substantial direct coverage in `apps/lemon_gateway/test/cli_adapter_test.exs` and engine-specific suites
- control-plane `cron.*` methods
  - already covered at the RPC layer in `apps/lemon_control_plane/test/lemon_control_plane/methods/cron_methods_test.exs`
- control-plane `node.*` methods like `node.list` and `node.describe`
  - already covered in `apps/lemon_control_plane/test/lemon_control_plane/methods/node_methods_test.exs`
- HealthChecker threshold tests for configurable `healthy_threshold` / `unhealthy_threshold`
  - the current module does not implement those knobs

## Recommended First 5

If the goal is fastest reduction of real production risk, start here:

1. `session.detail`
2. `agent.wait`
3. `events.subscribe` / `events.unsubscribe` / `events.subscriptions.list`
4. `LemonServices.Runtime.Server` restart-policy matrix
5. `LemonWeb.SessionLive`

## Final Ranked Backlog

### 1. Control Plane: `session.detail`

- Target: `apps/lemon_control_plane/lib/lemon_control_plane/methods/session_detail.ex`
- Suggested test file: `apps/lemon_control_plane/test/lemon_control_plane/methods/session_detail_test.exs`
- Scenario:
  - Seed run history with long prompt and answer text
  - Include mixed atom/string keyed payloads
  - Include tool/action events and usage data
  - Exercise `includeFullText`, `includeRawEvents`, `includeRunRecord`
  - Assert limit clamping for `limit`, `historyLimit`, `eventLimit`, and `toolCallLimit`
- Why it matters:
  - This is the richest operator/debug endpoint in the control plane
  - It has enough formatting and truncation logic to drift without obvious failures

### 2. Control Plane: `agent.wait`

- Target: `apps/lemon_control_plane/lib/lemon_control_plane/methods/agent_wait.ex`
- Suggested test file: `apps/lemon_control_plane/test/lemon_control_plane/methods/agent_wait_test.exs`
- Scenario:
  - Run already completed in `RunStore`
  - Completion arrives on the bus after subscription
  - Timeout path
  - Verify unsubscribe happens on all exit paths
- Why it matters:
  - Blocking APIs are where hangs and subscription leaks hide

### 3. Control Plane: event subscription lifecycle

- Targets:
  - `apps/lemon_control_plane/lib/lemon_control_plane/methods/events_subscribe.ex`
  - `apps/lemon_control_plane/lib/lemon_control_plane/methods/events_unsubscribe.ex`
  - `apps/lemon_control_plane/lib/lemon_control_plane/methods/events_subscriptions_list.ex`
- Suggested test file: `apps/lemon_control_plane/test/lemon_control_plane/methods/events_subscription_lifecycle_test.exs`
- Scenario:
  - Register a connection process for a real `conn_id`
  - Subscribe to `["system", "run:abc"]`
  - List subscriptions
  - Unsubscribe one topic
  - Unsubscribe all
- Why it matters:
  - The API contract is per-connection subscription state
  - This is easy to regress because current adjacent tests focus on event fanout, not subscription mutation

### 4. Services: restart-policy matrix

- Target: `apps/lemon_services/lib/lemon_services/runtime/server.ex`
- Suggested test file: `apps/lemon_services/test/lemon_services/runtime/server_restart_policy_test.exs`
- Scenario:
  - `:temporary` never restarts
  - `:transient` restarts on abnormal exit but not exit code `0`
  - `:permanent` always restarts
  - Restart count and backoff advance as expected
- Why it matters:
  - This is the core process lifecycle coordinator for long-running external services

### 5. Web: dashboard session flow

- Target: `apps/lemon_web/lib/lemon_web/live/session_live.ex`
- Suggested test file: `apps/lemon_web/test/lemon_web/live/session_live_test.exs`
- Scenario:
  - Empty submit rejected
  - Submit blocked while uploads are still in progress
  - User/system/tool/assistant messages append correctly
  - Deltas aggregate by `run_id`
  - Failed and successful completions finalize correctly
- Why it matters:
  - This is the main web dashboard and currently lacks real behavioral coverage

### 6. Gateway: email inbound correctness

- Target: `apps/lemon_gateway/lib/lemon_gateway/transports/email/inbound.ex`
- Suggested test file: `apps/lemon_gateway/test/email/inbound_routing_test.exs`
- Scenario:
  - Parse a realistic reply email
  - Resolve thread from `message-id` / `in-reply-to`
  - Strip engine directive from body
  - Build `email_reply` metadata
  - Submit the expected `RunRequest`
- Why it matters:
  - Current email tests skew toward hardening and security, not routing correctness

### 7. Telegram: update processing end-to-end

- Target: `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/update_processor.ex`
- Suggested test file: `apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_update_processor_test.exs`
- Scenario:
  - Prepare a real message/update shape
  - Verify dedupe blocks the second delivery
  - Persist and refresh `KnownTargetStore`
  - Preserve `reply_to_text`
  - Confirm changed metadata is written after the persistence interval
- Why it matters:
  - This decides whether Telegram inbound messages route, drop, or store stale chat metadata

### 8. Control Plane: `chat.history`

- Target: `apps/lemon_control_plane/lib/lemon_control_plane/methods/chat_history.ex`
- Suggested test file: `apps/lemon_control_plane/test/lemon_control_plane/methods/chat_history_test.exs`
- Scenario:
  - Seed runs with prompt from summary and event fallback
  - Seed assistant answers and `ok` flags
  - Exercise `beforeId` and `limit`
  - Assert ordering and pagination cutoff
- Why it matters:
  - Client-facing history reconstruction is easy to get subtly wrong

### 9. Control Plane: `run.introspection.list`

- Target: `apps/lemon_control_plane/lib/lemon_control_plane/methods/run_introspection_list.ex`
- Suggested test file: `apps/lemon_control_plane/test/lemon_control_plane/methods/run_introspection_list_test.exs`
- Scenario:
  - Persist introspection events across multiple types and timestamps
  - Filter by `eventTypes`, `sinceMs`, and `untilMs`
  - Toggle `includeRunEvents`
  - Assert truncation and filtering behavior
- Why it matters:
  - This is an incident-response endpoint for run debugging

### 10. Web: access-token enforcement

- Target: `apps/lemon_web/lib/lemon_web/plugs/require_access_token.ex`
- Suggested test file: `apps/lemon_web/test/lemon_web/plugs/require_access_token_test.exs`
- Scenario:
  - Bearer token works
  - Query token works
  - Existing session marker re-authenticates
  - Invalid token clears session and returns `401`
  - No configured token bypasses auth
- Why it matters:
  - This is the only dashboard gate

### 11. Services: health-check hysteresis and recovery

- Target: `apps/lemon_services/lib/lemon_services/runtime/health_checker.ex`
- Suggested test file: `apps/lemon_services/test/lemon_services/runtime/health_checker_test.exs`
- Scenario:
  - One failure does not mark unhealthy
  - Second consecutive failure does
  - Recovery flips back to healthy
  - Correct messages are sent back to the service server
- Why it matters:
  - This logic determines whether the system looks flaky or stable

### 12. Gateway: webhook dispatch cleanup

- Target: `apps/lemon_gateway/lib/lemon_gateway/transports/webhook/invocation_dispatch.ex`
- Suggested test file: `apps/lemon_gateway/test/webhook_invocation_dispatch_test.exs`
- Scenario:
  - Wait setup succeeds but `submit_run/1` fails or raises
  - Assert waiter cleanup
  - Assert normalized `{:submit_failed, ...}` error shape
  - Assert idempotency only persists on success
- Why it matters:
  - This is an externally exposed execution path with cleanup-sensitive failure modes

### 13. Router: delivery-route fallback resolution

- Target: `apps/lemon_router/lib/lemon_router/delivery_route_resolver.ex`
- Suggested test file: `apps/lemon_router/test/lemon_router/delivery_route_resolver_test.exs`
- Scenario:
  - Malformed session keys
  - String and atom meta keys
  - Invalid `peer.kind`
  - Missing `peer.id`
  - `account_id` defaulting
- Why it matters:
  - Incorrect fallback routes cause dropped output or delivery to the wrong peer

### 14. Control Plane: `config.reload`

- Target: `apps/lemon_control_plane/lib/lemon_control_plane/methods/config_reload.ex`
- Suggested test file: `apps/lemon_control_plane/test/lemon_control_plane/methods/config_reload_test.exs`
- Scenario:
  - Param translation for `sources`, `force`, and `reason`
  - `:reload_in_progress`
  - `{:reload_failed, ...}`
  - Unexpected error values
- Why it matters:
  - Admin-only methods need more than smoke coverage because mistakes read like successful ops

### 15. Coding Agent: context guardrails

- Target: `apps/coding_agent/lib/coding_agent/context_guardrails.ex`
- Suggested test file: `apps/coding_agent/test/coding_agent/context_guardrails_test.exs`
- Scenario:
  - Truncate multi-byte UTF-8 safely
  - Strip thinking blocks when configured to zero
  - Spill oversized tool output to disk with stable metadata
  - Cap oversized tool-call arg strings inside nested maps/lists
  - Preserve image MIME handling and spill/keep behavior
- Why it matters:
  - This path sits in front of LLM submission and has no dedicated direct test coverage
  - Invalid truncation here can silently corrupt model input

### 16. Services: port lifecycle and signal handling

- Target: `apps/lemon_services/lib/lemon_services/runtime/port_manager.ex`
- Suggested test file: `apps/lemon_services/test/lemon_services/runtime/port_manager_test.exs`
- Scenario:
  - Spawn a simple process and verify stdout/stderr forwarding
  - Graceful shutdown with SIGTERM
  - Forced shutdown after timeout
  - Exit code propagation
  - Working directory and environment injection
- Why it matters:
  - `lemon_services` depends on this module for all OS process interaction
  - The current app-level tests barely exercise it

### 17. Services: config persistence

- Target: `apps/lemon_services/lib/lemon_services/config.ex`
- Suggested test file: `apps/lemon_services/test/lemon_services/config_test.exs`
- Scenario:
  - Save, load, and remove persistent service definitions
  - Include tags, env, health checks, and `persistent: true`
  - Assert round-trip fidelity through `config/services.d/*.yml`
- Why it matters:
  - This is the persistence layer behind long-lived service definitions

### 18. Telegram: message-buffer debounce semantics

- Target: `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/message_buffer.ex`
- Suggested test file: `apps/lemon_channels/test/lemon_channels/adapters/telegram/message_buffer_test.exs`
- Scenario:
  - Multiple rapid messages in one scope
  - Timer replacement
  - Joined text ordering
  - Last-message `reply_to_text` and `user_msg_id` propagation
  - `drop_buffer_for/2` cancel behavior
- Why it matters:
  - Buffering changes the actual prompt shape seen by the router

### 20. Discord: outbound delivery matrix

- Target: `apps/lemon_channels/lib/lemon_channels/adapters/discord/outbound.ex`
- Suggested test file: `apps/lemon_channels/test/lemon_channels/adapters/discord/outbound_test.exs`
- Scenario:
  - Text send
  - Edit
  - Delete
  - Reaction add/remove
  - File notice
  - ID normalization and invalid peer handling
- Why it matters:
  - Discord currently has inbound coverage, but outbound behavior is effectively unpinned

## Strong Candidates Just Outside The Top 20

These are still good additions, but they come after the ranked backlog above:

- `apps/lemon_control_plane/lib/lemon_control_plane/methods/node_pair_approve.ex`
- `apps/lemon_control_plane/lib/lemon_control_plane/methods/node_pair_verify.ex`
- `apps/lemon_channels/lib/lemon_channels/telegram/api.ex`
- `apps/lemon_channels/lib/lemon_channels/presentation_state.ex`
- `apps/lemon_gateway/lib/lemon_gateway/transports/email/outbound.ex`

## Shared Helpers Worth Adding Early

These helpers will pay off immediately across the first implementation wave:

- `run_store_fixture/2`
  - seed `RunStore` history with summary, events, and completed payloads
- `connection_registry_fixture/1`
  - stand up a fake control-plane connection process for subscription tests
- `telegram_update_fixture/1`
  - build realistic Telegram Bot API update maps
- `service_definition_fixture/1`
  - construct service definitions with small shell commands for runtime tests
- `live_run_event/3`
  - push `LemonCore.Event` payloads into LiveViews
- `utf8_payload_fixture/1`
  - generate deterministic multi-byte strings for guardrail truncation tests
- `port_process_fixture/1`
  - tiny shell script or helper process that exits with a configurable code and emits stdout/stderr

## Implementation Phases

### Phase 1: core operator and runtime safety

- `session.detail`
- `agent.wait`
- event subscription lifecycle
- services restart-policy matrix
- web session dashboard flow

### Phase 2: ingress, routing, and auth

- email inbound correctness
- Telegram update processor
- `chat.history`
- `run.introspection.list`
- web access-token plug

### Phase 3: infrastructure boundaries

- services health-check hysteresis
- webhook dispatch cleanup
- delivery-route fallback resolution
- `config.reload`
- context guardrails
- port manager

### Phase 4: remaining product-facing gaps

- services config persistence
- games visibility rules
- Telegram message buffer
- Discord outbound

## Notes For Follow-Up Reviews

When revisiting this list, only promote a new candidate into the top 20 if it beats an existing item on at least one of these axes:

1. larger user-visible blast radius
2. weaker current adjacent coverage
3. more stateful failure mode
4. higher cleanup/security risk
