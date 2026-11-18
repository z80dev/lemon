# LemonRouter

`lemon_router` owns request normalization, conversation identity, queue semantics, and semantic output tracking.
It sits between channel transports and `lemon_gateway`.

## Current Flow

```text
Channel transport or gateway-native ingress
  -> LemonChannels.Runtime.submit_inbound/2 (RunRequestBuilder.from_inbound/1)
  -> LemonCore.RouterBridge.submit_run/1
  -> LemonRouter.RunOrchestrator
  -> LemonRouter.SessionCoordinator
  -> LemonRouter.RunProcess
  -> configured LemonCore.EngineRuntime.submit_execution/1
  -> gateway Runtime -> Run -> EngineSessionClaim -> Slots -> executor
  -> LemonCore.Bus run events
  -> LemonRouter semantic coalescers / output tracking
  -> LemonCore.DeliveryIntent
  -> LemonChannels.Dispatcher
  -> channel-specific renderer / outbox
```

## Supervision tree

```text
LemonRouter.Supervisor (one_for_one)
  +-- RestartCarryover (drain admission owner)
  +-- AgentProfiles
  +-- CoalescingSupervisor (rest_for_one)
  |     +-- CoalescerRegistry
  |     +-- CoalescerSupervisor (DynamicSupervisor)
  +-- ToolStatusTree (rest_for_one)
  |     +-- ToolStatusRegistry
  |     +-- ToolStatusSupervisor (DynamicSupervisor)
  +-- AsyncTaskSurfaceTree (rest_for_one)
  |     +-- AsyncTaskSurfaceRegistry
  |     +-- AsyncTaskSurfaceSupervisor (DynamicSupervisor)
  +-- RoutingFeedbackStore
  +-- ConversationSupervisor (rest_for_one)
  |     +-- RunRegistry, SessionRegistry, ConversationRegistry
  |     +-- RunSupervisor (DynamicSupervisor, run_process_limit)
  |     +-- SessionCoordinatorSupervisor (DynamicSupervisor)
  |     +-- RunCountTracker
  |     +-- RunOrchestrator
  |     +-- AgentMessaging
  |     +-- RestartCarryover.Replayer
  +-- Health.Server (optional)
```

Every dependency subtree has its own budget of 10 restarts per 5 seconds
(caller containment policy, not a measured capacity). Registry failure stops
later dependants in reverse order and restarts them in list order. Conversation
registries therefore cannot disappear while old runs/coordinators remain alive.
Temporary run children are never replayed by supervision; the graceful-restart
replayer retains its explicit durable carryover contract. Coalescing/surface
failures are isolated from the conversation subtree and from each other.

## Ownership

- Router owns:
  - `RunRequest` normalization
  - policy, model, and engine resolution
  - resume resolution and conversation-key selection
  - queue semantics: `collect`, `followup`, `steer`, `steer_backlog`, `interrupt`
  - transactional pending-compaction prompt rewriting
  - semantic stream and tool-status coalescing
- Router does not own:
  - Telegram or Discord rendering details
  - `OutboundPayload` construction
  - Telegram message-id presentation state
  - gateway slot scheduling or engine lifecycle

## Key Modules

| Module | Responsibility |
| --- | --- |
| `LemonRouter.Router` | Main inbound entrypoint, session-key resolution, pending-compaction preparation, control-plane abort/keepalive hooks |
| LemonRouter.RunOrchestrator (internal) | Durably claims fixed run IDs, rejects conflicting reuse, serializes abort registration with cancellation dispatch, and hands accepted work to `SessionCoordinator` |
| `LemonRouter.SessionCoordinator` | Single owner of per-conversation queue semantics and active-run handoff |
| Router internal session read model | Internal read model over coordinator-owned active session state |
| `LemonRouter.ConversationKey` | Canonical conversation-key selection from structured resume or session key |
| `LemonRouter.ResumeResolver` | Structured resume resolution before runtime submission |
| `LemonRouter.RunProcess` | Active-run lifecycle wrapper around one execution |
| `LemonRouter.MediaJobRecorder` | Records generated final-answer files into redacted media job metadata before channel delivery |
| LemonRouter.ChannelsDelivery (internal) | Narrow bridge from router-adjacent automation delivery requests into `LemonChannels`; must not construct `OutboundPayload` or own channel rendering |
| `LemonRouter.StreamCoalescer` | Semantic answer coalescing that emits `DeliveryIntent` snapshots/finalization |
| `LemonRouter.ToolStatusCoalescer` | Semantic tool-status coalescing that emits `DeliveryIntent` snapshots/finalization; chat surfaces hide reasoning-only actions and fixed engine provenance while operator surfaces retain structured reasoning |
| `LemonRouter.PendingCompaction` | Shared pending-compaction preparation, injection-safe JSONL history envelopes, whole-entry truncation, and post-submit marker consumption |
| `LemonRouter.PendingCompactionStore` | Router-owned typed wrapper for pending-compaction markers |
| `LemonRouter.AgentDirectory` | Active/durable session discovery |

Agent profile configuration uses `:agent_profiles_cwd` from the `:lemon_router`
application environment, then the declared `LEMON_AGENT_PROFILES_CWD` environment
variable, falling back to the process working directory. Health extensions accept
a list of `{name, zero_arity_function}` checks. Delivery metadata must specify a
supported peer kind (`dm`, `group`, or `channel`); unknown kinds are not DM routes.

`SurfaceManager.finalize_answer/3` dispatches `:stream_finalize` first for runs that already
streamed answer deltas, then finalizes `StreamCoalescer` state so late flushes cannot overwrite
the final. For non-streamed completions it still finalizes through `StreamCoalescer`, with a direct
`:final_text` fallback if the coalescer finalize call exits or times out. Completion-time artifact
metadata enrichment is best-effort and must not block the final answer path.
`RunProcess.ArtifactTracker` also supports Hermes-style final-answer media
directives: a line containing `MEDIA:<project-relative-path>` is converted into
an explicit `auto_send_files` entry after existing-file, cwd, and symlink escape
checks pass. The directive line is removed from the final text before channel
rendering, and Telegram/Discord delivery still goes through the normal
attachment policy.

## Important Contracts

- Router startup validates the configured `:engine_runtime` through
  `LemonCore.EngineRuntime.validate/1`. Invalid wiring is logged once and its
  binding is disabled without changing the router-only degraded mode: the
  router still boots and runtime operations retain their existing
  unavailable-runtime handling.
- Inbound callers should provide structured resume data through `LemonCore.RunRequest.resume` when they already know it.
- `ResumeResolver.bind/3` also binds each native session to the session key of the run that first binds it (`LemonCore.NativeSessionOwner`, first write wins). Explicit and automatic resumes are admitted only for that session key; requests carrying channel provenance also refuse unbound (pre-binding) native sessions and start a fresh one instead.
- `RouterBridge.submit_run/1` returns the exact `RunOrchestrator.submit/1` error
  when submission is rejected. Inbound transports must not acknowledge a
  message as accepted after that error, and pending-compaction markers remain
  available for a later valid submission. A malformed acknowledgement is
  `{:error, :outcome_unknown}` because submission may already have happened
  without returning a usable run id; it is not automatically retry-safe.
- Abort and keep-alive `:ok` results mean the router accepted or dispatched the
  decision. A run-specific abort is not acknowledged unless its serialization
  tombstone was registered; an unknown registration outcome is propagated to
  the bridge. These commands do not wait for synchronous application by every
  target run process.
- Top-level runs always use the native executor; model validation belongs to `LemonAi`, and default cwd resolution should use `LemonCore.Cwd` (channel-origin runs default to the assistant home, not `$HOME`).
- `LemonChannels.RunRequestBuilder.from_inbound/1` derives `meta.channel_context` and `meta.channel_identity` from the transport-normalized message (caller meta cannot supply them), so `channel_policies` rows apply and group chats require approval for every `bash`, `write`, `edit`, `patch`, and `hashline_edit` call.
- `SubmissionBuilder` refuses a channel-origin request without that provenance (`{:error, :missing_channel_provenance}`). Graceful restart carryover counts it as rejected and crash recovery abandons it; work persisted before provenance existed is never run unrestricted.
- `SessionKey.channel_peer/1` writes a routing component containing `:` as a colon-free `~sha256-` digest and never decodes components. `DeliveryRouteResolver` takes the delivery target for a hashed component from the run's transport `meta.peer`, and only when it hashes back to the key.
- Router emits `LemonCore.DeliveryIntent`, not `LemonChannels.OutboundPayload`.
- Tool-status failure summaries preserve safe structured fields from
  `action.detail.result_meta`, including `error_type`, tool name, timeout,
  command exit code, exception class/name, status, reason, message, and
  validation errors.
- Cron/channel-origin summary delivery may cross router through the internal LemonRouter.ChannelsDelivery bridge, but the bridge must stay narrow. Router must not construct `LemonChannels.OutboundPayload`; `LemonChannels` remains responsible for enqueue semantics, retries, chunking, and adapter delivery.
- Runtime input is `LemonCore.ExecutionCommand`; gateway-private adapters may translate it to `LemonGateway.ExecutionRequest`.
- Telegram-specific state is owned by `lemon_channels` wrappers:
  - `LemonChannels.Telegram.StateStore`
  - `LemonChannels.Telegram.ResumeIndexStore`
- External apps must query busy/active session state through `LemonRouter.Router` or `LemonCore.RouterBridge`, not router-internal read-model or registry details. Registry/read-model failures propagate as errors rather than false idle/empty answers.

## Session And Queue Semantics

`SessionCoordinator` serializes by conversation key:

- `{:resume, engine, token}` for explicit shared resume tokens
- `{:session, session_key}` for ordinary sessions, including automatic resume

Queue-mode behavior lives here:

- `:collect` appends
- `:followup` debounces/merges recent followups, except async task/delegated followups which stay separate
- `:steer` attempts in-run steer and falls back to followup
- `:steer_backlog` attempts in-run steer and falls back to collect
- active async task/delegated auto-followups are promoted to `:steer` so completions try to reach the live parent run before falling back to a queued followup
- `:interrupt` cancels the active run and inserts the new request at the front

When the target runtime registry or lookup process is absent, steering uses the
same queued fallback. Redirect also queues the correction as a follow-up and
notifies the channel that it could not redirect the in-flight run. Unexpected
runtime lookup or notification-dispatch exceptions still propagate.

Conversation backlogs are bounded to 128 queued/pending submissions, 1 MiB
of pending prompt text and 16 MiB of encoded pending image data. A new submission
exceeding a bound returns `:session_queue_full` without mutating the queue or
interrupting the active run;
replaying an already retained fixed run ID remains an acknowledgement lookup.
Gateway bounds executing Runs, not its waiter population. Router's run-process
limit bounds normal routed waiters; direct runtime submissions bypass that cap.
Coordinators are never stopped on idle and their supervisor is uncapped: one
process remains per distinct conversation for the VM lifetime. See the canonical
[admission inventory](../../docs/architecture/admission-gates.md).

Each accepted submission retains a durable terminal receipt even if it never
starts an executor. A merged followup ends with `error.type: :superseded` and its
`replacement_run_id`; the replacement executes the merged prompt in order.
An accepted steer ends with `ok: true`, `meta.disposition: :steered` and its
`active_run_id`; that active run owns the eventual answer. Queued cancellation
publishes a failed completion with the cancellation reason. These receipts are
persisted before terminal notifications, so `agent.wait` also works after the
event was delivered. Queue counts reflect live coordinator backlogs, not
submit/start telemetry that can drift after merges or cancellation.

Queued automatic-resume requests resolve their native token again when they
start, after the prior turn persisted its resume state. They retain the session
conversation owner while the backlog drains, preventing split queues and fresh
sessions caused by a token that was unavailable at enqueue time.

Pending compaction is coupled to this submission boundary. Fresh markers remain
stored while the compacted prompt is prepared and are deleted only after the
coordinator accepts the submission, so admission/start errors remain retryable.
Stale markers and markers with no usable history clear eagerly. Prior run
summaries are carried as JSONL with escaped envelope characters and are bounded
by dropping complete oldest run entries rather than slicing through role data.

`RunProcess` retries runtime unavailability only, until its pre-start deadline;
definite gateway rejection terminalizes immediately rather than retrying admission.
Persistent unavailability emits one structured synthetic `:run_completed` event
so the active conversation is released. If a queued child
cannot start later, `SessionCoordinator` emits the corresponding structured
start-failure completion before cleaning up its event-bridge subscription and
continues with the next queued submission. A child already registered after an
ambiguous supervisor error is adopted to avoid double completion.

Fixed run IDs are router idempotency keys, not merely correlation labels. The
orchestrator writes a durable request-identity claim before queue mutation;
concurrent or crash-replayed copies of the same request resolve to the original
active, queued, or completed run, while reuse for another session or payload is
rejected. A pending claim is reconciled against surviving `RunRegistry` state
and the durable terminal `RunStore` record before any retry can enqueue work.
`SessionRegistry` is the unique, lifecycle-owned session index: each `RunProcess`
registers its own key during initialization and process death releases it.
A restarted coordinator discovers and monitors the surviving owner through this
Registry before accepting more work. Registry loss follows OTP's links to its
registered owners rather than leaving independent runs behind.

### Failure boundaries

Unexpected exceptions in router callbacks and internal state transitions propagate
to OTP instead of being converted into successful acknowledgements, empty policy,
or unchanged state. Coalescer crashes are visible to their callers and supervisors;
async task-surface subscribers restart after abnormal exits, but stop normally on
terminal task events. A restart resumes future events, not a replay of lost deltas.

Expected failures remain distinct: unavailable registry reads return explicit
errors, store/process exits at admission boundaries retain an outcome-unknown
result, and malformed enqueue acknowledgements retain the durable submitting
fence. A callback crash also leaves that fence intact, so supervisor recovery
cannot accidentally enqueue the same fixed run ID twice. Definite pre-enqueue
rejections still roll back the claim for retry.

`SurfaceManager.finalize_answer/3` returns final-dispatch errors rather than
acknowledging a rejected delivery, and does not mark streamed coalescer state
finalized after that rejection. `StreamCoalescer` preserves explicit dispatch
errors for retry and reports a crashed finalize call separately. Completion-time
artifact enrichment and termination-time cancellation remain best-effort so a
secondary failure cannot suppress the final answer or terminal event.

Restart admission (`:open`, `:holding`, `:sealed`) lives in a protected ETS
table owned by the supervised `RestartCarryover` process, not in
`persistent_term` or a drain caller. Missing ownership refuses new work and
holds queues. An owner restarted during a runtime drain starts sealed;
ordinary app startup starts open. Durable carryover records remain in Store.

## Output Semantics

Router coalescers only track semantic state:

- accumulated text
- sequence numbers
- semantic tool/action state
- run/session metadata needed for `DeliveryIntent`

Channels decides:

- send vs edit
- truncation
- reply markup
- media batching
- Telegram resume indexing by platform message id

## Testing

Run the app suite from the umbrella root:

```bash
mix test apps/lemon_router
```

Useful focused suites during refactors:

```bash
mix test apps/lemon_router/test/lemon_router/router_test.exs
mix test apps/lemon_router/test/lemon_router/run_orchestrator_test.exs
mix test apps/lemon_router/test/lemon_router/session_coordinator_test.exs
mix test apps/lemon_router/test/lemon_router/run_process_test.exs
mix test apps/lemon_router/test/lemon_router/stream_coalescer_test.exs
mix test apps/lemon_router/test/lemon_router/tool_status_coalescer_test.exs
```

Run architecture checks after boundary changes:

```bash
mix lemon.quality
```
