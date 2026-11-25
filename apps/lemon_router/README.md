# LemonRouter

`lemon_router` owns request normalization, conversation ordering, top-level
run execution, and semantic output tracking.

## Current Flow

```text
LemonChannels.Runtime.submit_inbound/2 (via RunRequestBuilder), or other product ingress
  -> LemonCore.RouterBridge.submit_run/1
  -> LemonRouter.RunOrchestrator
  -> LemonRouter.SessionCoordinator
  -> LemonRouter.RunProcess (engine-session claim, terminal fence, then FIFO permit)
  -> CodingAgent.Executor (LemonCore.ExecutionCommand)
  -> engine events and deltas directly back to RunProcess
  -> LemonCore.Bus observers and router semantic output tracking
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
  |     +-- EngineSessionRegistry
  |     +-- Slots
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
  - engine-session ownership, FIFO execution permits and run lifecycle
- Router does not own:
  - Telegram or Discord rendering details
  - `OutboundPayload` construction
  - Telegram message-id presentation state

## Key Modules

| Module | Responsibility |
| --- | --- |
| `LemonRouter.Router` | Main inbound entrypoint, session-key resolution, pending-compaction preparation, control-plane abort/keepalive hooks |
| LemonRouter.RunOrchestrator (internal) | Durably claims fixed run IDs, rejects conflicting reuse, serializes abort registration with cancellation dispatch, and hands accepted work to `SessionCoordinator` |
| `LemonRouter.SessionCoordinator` | Single owner of per-conversation queue semantics and active-run handoff |
| Router internal session read model | Internal read model over coordinator-owned active session state |
| `LemonRouter.ConversationKey` | Canonical conversation-key selection from structured resume or session key |
| `LemonRouter.ResumeResolver` | Structured resume resolution before runtime submission |
| `LemonRouter.RunProcess` | `gen_statem` and sole owner of a live run, its executor, claim, and permit |
| `LemonRouter.RunCompletion` | Router's terminal commit entry point; hands off the persisted attempt to `LemonCore.TerminalOutbox` for notification and replay |
| `LemonRouter.Slots` | Global FIFO permits, including permit lending for blocked delegation |
| `LemonRouter.Health` | Router health, including execution-slot counters |
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

`SurfaceManager.finalize_answer/3` finalizes every answer, streamed or not, through
`StreamCoalescer`: the final `:stream_finalize` intent is queued behind every delta the
coalescer already admitted, so it is the last write and a late snapshot cannot overwrite a
multi-chunk final. A direct `:final_text` fallback is dispatched only if the coalescer
finalize fails (rejected dispatch, resync without the owner's text, exit or timeout). Completion-time artifact
metadata enrichment is best-effort and must not block the final answer path.
`RunProcess.ArtifactTracker` also supports Hermes-style final-answer media
directives: a line containing `MEDIA:<project-relative-path>` is converted into
an explicit `auto_send_files` entry after existing-file, cwd, and symlink escape
checks pass. The directive line is removed from the final text before channel
rendering, and Telegram/Discord delivery still goes through the normal
attachment policy.

## Important Contracts

- Production runs use `CodingAgent.Executor` directly. Tests driving public router
  submission may set `config :lemon_router, :test_executor, MyExecutor`;
  a directly started `RunProcess` can take an executor override.
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
- `LemonChannels.RunRequestBuilder.from_inbound/1` derives `meta.channel_context` and `meta.channel_identity` from the transport-normalized message (caller meta cannot supply them), so group chats require approval for every `bash`, `write`, `edit`, `patch`, and `hashline_edit` call.
- The approval floor follows provenance, not origin: whenever a request carries `meta.channel_context` with any peer kind but `:dm`, `Policy` applies the group approval floor. The only stored policy layer is the `LemonCore.PolicyStore` session row, read once per admission and shared by model, thinking-level and tool-policy resolution. Webhook ingress (`:webhook`) and A2A ingress (`meta.a2a`) derive `webhook`/`a2a` provenance from the authenticated integration or peer, classified `peer_kind: :automation` (so the floor applies) unless the operator's global config marks that integration or peer `trusted_automation = true` (then `:dm`); the A2A peer allow-list still intersects as the request override.
- `SubmissionBuilder` refuses a channel-origin request without that provenance, and a webhook or A2A request without provenance naming its own channel (`{:error, :missing_channel_provenance}`). Graceful restart carryover counts it as rejected and crash recovery abandons it; work persisted before provenance existed is never run unrestricted.
- `SessionKey.channel_peer/1` writes a routing component containing `:` as a colon-free `~sha256-` digest and never decodes components. `DeliveryRouteResolver` takes the delivery target for a hashed component from the run's transport `meta.peer`, and only when it hashes back to the key.
- Router emits `LemonCore.DeliveryIntent`, not `LemonChannels.OutboundPayload`.
- Tool-status failure summaries preserve safe structured fields from
  `action.detail.result_meta`, including `error_type`, tool name, timeout,
  command exit code, exception class/name, status, reason, message, and
  validation errors.
- Cron/channel-origin summary delivery may cross router through the internal LemonRouter.ChannelsDelivery bridge, but the bridge must stay narrow. Router must not construct `LemonChannels.OutboundPayload`; `LemonChannels` remains responsible for enqueue semantics, retries, chunking, and adapter delivery.
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
The router's run-process limit bounds both permit waiters and executing runs;
`[gateway].max_concurrent_runs` independently limits concurrent execution.
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

`RunProcess` claims the native session through `EngineSessionClaim` and
`EngineSessionRegistry`. Session contention (`:session_in_use`) retries within
the 30-second submission deadline without using a permit. Once claimed, it checks
the durable `RunStore` terminal fence, waits for a FIFO permit, and rechecks
terminal/cancellation state before invoking the executor.

Executor `{:engine_event, …}` and `{:engine_delta, …}` messages arrive directly
at the owner. It persists events and publishes run-topic updates, including
`run_started`, `delta`, `engine_*`, and `checkpoint_*`. `SessionCoordinator`
uses `RunProcess.steer/5` for steer or redirect. Cancellation, idle watchdog
expiry, and restart drain are handled by the owner; cancellation requests the
executor to stop and allows up to 15 seconds for it to drain.

`RunCompletion.finalize/3` handles owned runs, `publish/2` handles dropped
submissions without an owner, and `abandon/2` handles crash recovery. An executor
exit without completion yields the structured error `executor_down` with a
reason class. An owner crash terminalizes once with `:run_owner_terminated`.
Registered children are adopted after ambiguous supervisor errors rather than
started twice.

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
acknowledging a rejected delivery: when neither the coalescer nor the fallback delivered the
answer it returns `{:error, reason}` and records `:answer_finalize_failed`. A rejected
coalescer dispatch leaves the stream unfinalized but drops its pending transient text, and a
crashed finalize call is reported separately. Completion-time
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
