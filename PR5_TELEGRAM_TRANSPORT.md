# PR5 Telegram Transport Seam

## Baseline check

Verified before implementation that this branch is already on the post-PR4 shape and that PR5 can stay on the stable channel/router boundary:

- `LemonCore.RouterBridge`
- `LemonChannels.Dispatcher`
- `LemonChannels.PresentationState`
- `LemonChannels.Outbox`

No router-internal dependency was introduced from the Telegram transport.

## Files changed

Modified:

- `apps/lemon_channels/AGENTS.md`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/commands.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/message_buffer.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/poller.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/update_processor.ex`

Added:

- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/action_runner.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/inbound_context.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/normalize.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/pipeline.ex`
- `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/runtime_state.ex`
- `apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_message_buffer_test.exs`
- `apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_pipeline_test.exs`
- `apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_update_processor_test.exs`

## Exact behavior changes introduced

- Added a Telegram-local normalized inbound boundary via `InboundContext` and `Normalize`.
- Added a Telegram-local `Pipeline` that turns normalized inbound events into adapter-local actions.
- Added a Telegram-local `ActionRunner` that executes those actions through the existing transport callbacks instead of doing side effects deep in the pipeline.
- Moved poll/update dispatch in `poller.ex` onto `Normalize -> Pipeline -> ActionRunner`.
- Moved timer/event ingress in `transport.ex` onto the same `Normalize -> Pipeline -> ActionRunner` path.
- Kept router submission on `LemonCore.RouterBridge`; no router internal calls were introduced.
- Kept known-target indexing in `UpdateProcessor`, including callback-query refresh behavior.
- Strengthened `MessageBuffer` so it owns debounce merge behavior, timer replacement, flush building, and scope drop behavior.
- Preserved newest `reply_to_text`, newest `reply_to_id`, and newest `user_msg_id` when coalescing buffered messages.
- Preserved topic-scoped buffering by continuing to scope buffers by `{chat_id, thread_id}`.
- Added `RuntimeState` helpers for default transport-owned state, allowed chat parsing, initial offset selection, and stale/current timer entry extraction.
- Narrowed `UpdateProcessor` to focused authorization/dedupe/known-target/reply-to/router-enrichment helpers and exposed a side-effect-light routing decision API for the pipeline.
- Updated Telegram adapter docs in `apps/lemon_channels/AGENTS.md` to describe the shell, normalize/pipeline/action-runner, and message buffer shape.
- `transport.ex` now delegates the new ingress seam and dropped from 3891 lines at `HEAD` to 3817 lines in the working tree.

## Intentionally deferred to PR6

- Any cross-channel shared inbound abstraction under `lemon_channels`
- Generic action framework shared with Discord/WhatsApp
- Deeper extraction of Telegram-specific UX branches like model picker, approval, resume selection, or session routing into additional modules
- Any redesign of `Dispatcher`, `PresentationState`, `Outbox`, or renderer semantics
- Any polling/webhook architecture changes

## Review workflow

- Spark implementation work was split into dedicated worktrees for core refactor and tests.
- `gpt-5.4-mini` review passes were used to look for regressions around callback handling, buffering, stale timer behavior, reply metadata propagation, topic scoping, and AGENTS drift.
- A final `gpt-5.4` review pass was requested on the integrated diff before closeout, followed by another validation pass in the main checkout.

## Validation

Commands run:

- `mix format apps/lemon_channels/AGENTS.md apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport.ex apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/commands.ex apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/message_buffer.ex apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/poller.ex apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/update_processor.ex apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/action_runner.ex apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/inbound_context.ex apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/normalize.ex apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/pipeline.ex apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/runtime_state.ex apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_message_buffer_test.exs apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_pipeline_test.exs apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_update_processor_test.exs`
  - passed
- `mix test apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_update_processor_test.exs apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_message_buffer_test.exs apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_pipeline_test.exs`
  - passed
- `mix test apps/lemon_channels/test/lemon_channels/adapters/telegram`
  - passed, `89 tests, 0 failures`
- `mix test apps/lemon_channels`
  - passed
- `mix lemon.quality`
  - failed due existing environment/repo-level issues outside PR5, including `:eaddrinuse` while starting `LemonGateway.Health.Server`, an already-running Telegram poller for `account_id="default"`, and unrelated environment/service startup problems

## Risks / edge cases noticed

- `transport.ex` is meaningfully slimmer around ingress, but it is still a very large Telegram adapter file; PR6 can continue slicing specialized flows without changing the seam introduced here.
- `mix lemon.quality` is noisy and environment-sensitive in this checkout because it boots broader application surfaces; PR5-specific Telegram tests are green, but umbrella quality still depends on external runtime conditions unrelated to this seam.
