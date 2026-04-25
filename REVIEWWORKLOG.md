# Review Work Log

This file tracks the implementation work for `REVIEW.md` / `REVIEWPLAN.md`.

## Coordination Rules

- Main agent owns integration in `/home/z80/dev/lemon`.
- Subagents may read this file for context and should report progress against the sections below.
- Main agent records integrated progress here to avoid concurrent write conflicts.
- Each workstream should list touched files, tests run, and blockers.

## Workstreams

| Stream | Owner | Status | Notes |
| --- | --- | --- | --- |
| M1 router/gateway decoupling | main + subagent | done | `LemonCore.ChatState`; router no longer depends on gateway |
| M2 async delivery receipts | subagent | done | requested/actual/status/fallback receipt fields persisted and rendered |
| M3 reasoning events | subagent | done | canonical `engine_action` reasoning constructor; old `reasoning_status` removed |
| M4 gateway startup shrink | subagent | done | legacy ingress isolated behind `LemonGateway.LegacyIngressSupervisor` |
| M5 architecture policy | subagent | done | current vs target policy drift reported by quality task |
| M6 documentation | main | done | architecture docs, AGENTS, README, and migration plan updated |

## Integrated Progress

- Created `REVIEWPLAN.md` from `REVIEW.md` findings.
- Started implementation pass.
- M1 integrated:
  - Moved gateway chat state struct to `apps/lemon_core/lib/lemon_core/chat_state.ex`.
  - Removed router compile dependency on `lemon_gateway`.
  - Updated router resume/coordinator tests to use local runtime stubs and core chat state.
  - Fixed typed store specs and Telegram struct access regressions.
- M2 integrated:
  - Added `delivery_receipt` with `requested_mode`, `actual_mode`, `status`, `decided_at_ms`, and optional fallback/active run metadata.
  - Updated CodingAgent message rendering/session persistence for the new receipt.
- M3 integrated:
  - Added `LemonCore.Event.engine_reasoning/1`.
  - Routed task async reasoning updates through canonical `:engine_action` events.
  - Removed the unwired `reasoning_status` path.
- M4 integrated:
  - Default gateway app startup is execution-only plus health.
  - Added explicit legacy ingress supervisor for transports, commands, SMS, and voice.
  - Fixed legacy-ingress tests to restart the gateway app before enabling legacy env.
- M5 integrated:
  - Split architecture policy into current allowed dependencies and target allowed dependencies.
  - `mix lemon.quality` now warns on target drift without failing current architecture checks.
- M6 integrated:
  - Updated architecture docs, gateway/core docs, AGENTS references, and the AI boundary extraction plan.
- Cleanup pass:
  - Updated `apps/lemon_router/README.md` to describe `LemonCore.EngineRuntime` and `LemonCore.ExecutionCommand`.
  - Updated `apps/lemon_gateway/AGENTS.md` test/integration guidance to prefer `LemonCore.ExecutionCommand`.

## Subagent Reports

- M1 explorer: confirmed remaining router/gateway coupling, typed store gaps, Telegram struct access issue, and stale docs. Findings addressed in integration.
- M2 worker: implemented delivery receipt semantics and reported targeted router/coding_agent tests passing.
- M3 worker: implemented canonical reasoning events and projection tests.
- M4 worker: implemented legacy ingress supervisor split and reported full gateway test suite passing.
- M5 worker: implemented target architecture drift reporting and focused architecture tests.

## Validation Log

- `mix format` passed.
- Static checks:
  - `rg "\bLemonCore\b" apps/ai/lib` returned no matches.
  - `rg "ProviderConfigResolver|Secrets|Onboarding" apps/ai/lib` returned no matches.
  - `rg "\bLemonGateway\b" apps/lemon_router/lib` returned no matches.
  - `rg "LemonGateway\.ExecutionRequest|ExecutionRequest" apps/lemon_router/lib` returned no matches.
  - `rg "reasoning_status" apps` returned no matches.
- Gateway focused suite passed:
  - `mix test apps/lemon_gateway/test/application_test.exs apps/lemon_gateway/test/command_registry_test.exs apps/lemon_gateway/test/sms/inbox_test.exs apps/lemon_gateway/test/sms/webhook_router_test.exs apps/lemon_gateway/test/transport_registry_test.exs`
  - 121 tests, 0 failures.
- Integrated focused suite passed:
  - `mix test apps/lemon_core/test/lemon_core/chat_state_test.exs apps/lemon_core/test/lemon_core/chat_state_store_test.exs apps/lemon_core/test/lemon_core/store_test.exs apps/lemon_core/test/lemon_core/event_test.exs apps/lemon_core/test/lemon_core/quality/architecture_check_test.exs apps/lemon_core/test/mix/tasks/lemon.quality_test.exs:176 apps/lemon_router/test/lemon_router/resume_resolver_test.exs apps/lemon_router/test/lemon_router/session_transitions_test.exs apps/lemon_router/test/lemon_router/session_coordinator_test.exs apps/lemon_router/test/lemon_router/run_phase_sequence_test.exs apps/lemon_channels/test/lemon_channels/telegram/per_chat_state_test.exs apps/coding_agent/test/coding_agent/tools/task/projection_test.exs apps/lemon_gateway/test/application_test.exs apps/lemon_gateway/test/command_registry_test.exs apps/lemon_gateway/test/sms/inbox_test.exs apps/lemon_gateway/test/sms/webhook_router_test.exs apps/lemon_gateway/test/transport_registry_test.exs apps/lemon_gateway/test/m6_integration_test.exs apps/lemon_gateway/test/run_test.exs apps/lemon_channels/test/lemon_channels/startup_test.exs`
  - 230 tests, 0 failures.
- `mix lemon.quality` passed.
  - Expected warning remains: `lemon_gateway` still directly depends on `lemon_channels` relative to the target policy.
  - Runtime output includes existing unrelated noise from external adapters and missing SQLite database config.
- Cleanup static doc check passed:
  - No remaining matches for stale `LemonGateway.Runtime.submit_execution/1`, `Gateway input is LemonGateway.ExecutionRequest`, or `%ExecutionRequest{}` submission guidance in the touched docs.
