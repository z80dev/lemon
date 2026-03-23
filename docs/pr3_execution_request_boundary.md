# PR3 Router/Gateway Boundary Simplification

Date: 2026-03-23

## Scope

This change implements PR3 for the router/gateway boundary:

- `%LemonGateway.ExecutionRequest{}` is now the only outer/public run contract across the router -> gateway handoff.
- `LemonRouter.RunProcess` no longer accepts `job:` init args.
- `LemonGateway.RunSupervisor.start_run/1` no longer accepts `%{job: ...}` input.
- `%LemonGateway.Types.Job{}` remains gateway-internal for engine execution compatibility.
- The gateway submission edge now enforces router-owned `conversation_key`.
- Request-shaped helpers that still used `job` naming were renamed.

Precondition check passed before implementation:

- `apps/lemon_router/lib/lemon_router/submission.ex`
- `apps/lemon_router/lib/lemon_router/submission_builder.ex`
- `apps/lemon_router/lib/lemon_router/phase_publisher.ex`
- `apps/lemon_router/lib/lemon_router/queue_effect.ex`
- `apps/lemon_router/lib/lemon_router/run_starter.ex`

## Files Changed

- `apps/lemon_gateway/lib/lemon_gateway.ex`
- `apps/lemon_gateway/lib/lemon_gateway/execution_request.ex`
- `apps/lemon_gateway/lib/lemon_gateway/run_supervisor.ex`
- `apps/lemon_gateway/lib/lemon_gateway/runtime.ex`
- `apps/lemon_gateway/lib/lemon_gateway/scheduler.ex`
- `apps/lemon_gateway/lib/lemon_gateway/types.ex`
- `apps/lemon_gateway/test/queue_mode_test.exs`
- `apps/lemon_gateway/test/run_supervisor_test.exs`
- `apps/lemon_gateway/test/run_test.exs`
- `apps/lemon_router/lib/lemon_router/channel_context.ex`
- `apps/lemon_router/lib/lemon_router/run_process.ex`
- `apps/lemon_router/lib/lemon_router/run_process/output_tracker.ex`
- `apps/lemon_router/test/lemon_router/channel_context_test.exs`
- `apps/lemon_router/test/lemon_router/introspection_test.exs`
- `apps/lemon_router/test/lemon_router/run_process_test.exs`

## Exact Behavior Changes

1. `ExecutionRequest` and `Job` docs now describe the intended boundary:
   - `ExecutionRequest` is the public queue-semantic-free submission contract.
   - `Job` is the internal engine-facing compatibility type.
   - `ExecutionRequest.from_job/1` remains supported as a migration helper.

2. `LemonRouter.RunProcess` now requires `execution_request: %ExecutionRequest{}` in `start_link/1` / `init/1`.
   - Legacy `job:` init input is rejected.
   - Invalid or missing execution requests fail fast with `{:stop, {:invalid_execution_request, run_id}}`.
   - `RunProcess` no longer derives canonical conversation identity with `ConversationKey.resolve/2`.
   - It may still backfill `session_key` and `conversation_key` from explicit init opts, then validates via `ExecutionRequest.ensure_conversation_key/1`.

3. Request-shaped helper naming is corrected:
   - `coalescer_meta_from_job/1` -> `coalescer_meta_from_request/1`

4. The public gateway submission edge now enforces router-owned `conversation_key`:
   - `LemonGateway.Runtime.submit_execution/1` calls `ExecutionRequest.ensure_conversation_key/1`
   - `LemonGateway.Scheduler.submit_execution/1` calls `ExecutionRequest.ensure_conversation_key/1`

5. `LemonGateway.RunSupervisor.start_run/1` now accepts only:
   - `%{execution_request: %ExecutionRequest{}, ...}`
   - Invalid input, including `%{job: ...}`, returns `{:error, :invalid_execution_request}`

6. `LemonGateway.Run` remains engine-internal:
   - It still converts `ExecutionRequest -> Job`
   - Engine interfaces were not changed

## Intentionally Deferred To PR4

- Removing `%LemonGateway.Types.Job{}` entirely
- Changing engine behaviour signatures away from `Job`
- Removing `ExecutionRequest.from_job/1` / `to_job/1`
- Any broader gateway/runtime architecture cleanup
- Any broader queue semantics changes
- Any broad router/gateway documentation rewrite

## Validation

Targeted formatting run:

- `mix format apps/lemon_gateway/lib/lemon_gateway/execution_request.ex apps/lemon_gateway/lib/lemon_gateway/types.ex apps/lemon_gateway/lib/lemon_gateway/runtime.ex apps/lemon_gateway/lib/lemon_gateway/scheduler.ex apps/lemon_gateway/lib/lemon_gateway/run_supervisor.ex apps/lemon_gateway/lib/lemon_gateway.ex apps/lemon_router/lib/lemon_router/run_process.ex apps/lemon_router/lib/lemon_router/channel_context.ex apps/lemon_router/lib/lemon_router/run_process/output_tracker.ex apps/lemon_router/test/lemon_router/channel_context_test.exs apps/lemon_router/test/lemon_router/run_process_test.exs apps/lemon_router/test/lemon_router/introspection_test.exs apps/lemon_gateway/test/run_supervisor_test.exs apps/lemon_gateway/test/queue_mode_test.exs`
- `mix format apps/lemon_gateway/test/run_test.exs`
- `mix format apps/lemon_router/test/lemon_router/run_process_test.exs`

Tests run:

- `mix test apps/lemon_router/test/lemon_router/run_process_test.exs apps/lemon_router/test/lemon_router/channel_context_test.exs apps/lemon_router/test/lemon_router/introspection_test.exs`
  - Passed
- `mix test apps/lemon_gateway/test/run_supervisor_test.exs apps/lemon_gateway/test/queue_mode_test.exs apps/lemon_gateway/test/scheduler_test.exs`
  - Passed
- `mix test apps/lemon_gateway/test/run_test.exs apps/lemon_gateway/test/lemon_gateway_test.exs apps/lemon_gateway/test/thread_worker_test.exs apps/lemon_gateway/test/run_transport_agnostic_test.exs`
  - Passed

Quality run:

- `mix lemon.quality`
  - Failed due to unrelated pre-existing repo issues outside PR3 scope
  - Final reported blocker: `apps/lemon_router/lib/lemon_router/tool_status_coalescer.ex` violates `router_telegram_dependency`

Static acceptance grep:

- No `opts[:job]` path remains in `apps/lemon_router/lib/lemon_router/run_process.ex`
- No `%{job: ...}` normalization remains in `apps/lemon_gateway/lib/lemon_gateway/run_supervisor.ex`
- No `ConversationKey.resolve(...)` remains in `apps/lemon_router/lib/lemon_router/run_process.ex`
- No production code in `apps/lemon_router/lib` references `LemonGateway.Types.Job`

## Follow-Up Risks / Notes

- Some tests that previously relied on implicit conversation identity now need explicit `conversation_key`; that is intentional and part of the PR3 contract tightening.
- The repo-wide quality harness is not clean enough to use as a PR3 signal without separating unrelated existing failures.
