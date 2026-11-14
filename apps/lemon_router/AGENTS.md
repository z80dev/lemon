# LemonRouter contributor guide

Router owns conversation semantics: request normalization, model/policy/resume
resolution, queues, active runs, compaction and semantic delivery. It does not
parse platform protocols, allocate gateway slots or own message IDs.
See [README](README.md) and [architecture](../../docs/architecture/overview.md).

## Submission and queue ownership

- `RunOrchestrator` builds router `Submission` values wrapping core
  `ExecutionCommand`; submit through configured `LemonCore.EngineRuntime`, not
  `LemonGateway.Runtime` or gateway-private request structs.
- `SessionCoordinator` owns one active pointer/backlog per conversation key,
  follow-up debounce/merge, steering fallback and interrupt semantics. A key is
  `{:resume, engine, token}` for an explicit shared token, otherwise
  `{:session, session_key}` (including auto-resume).
- Task/delegated auto-followups prefer steer with follow-up fallback. Do not merge
  separate provenance-bearing async completions during debounce. Record the final
  delivery disposition/receipt after router mutation, not before.
- `Router.handle_inbound/1` propagates submission errors. Only a non-empty binary
  run ID acknowledges success; malformed acknowledgements are outcome-unknown,
  not permission for an automatic retry.
- Public busy/active queries go through `Router`/`RouterBridge`. Registry and
  read-model failure is unavailable, never an invented idle or empty state.
- Abort/keepalive `:ok` acknowledges dispatch, not synchronous target application.
- Unexpected exceptions in router callbacks/state transitions reach OTP
  supervision, not fabricated `:ok`, nil or unchanged state.

## Cancellation and completion

- Serialize fixed-ID aborts with admission. Durable abort fences prevent later
  execution even after in-memory tombstones expire; accepted work follows normal
  cancellation. Failed fence registration must propagate as an unknown mutation.
- Admission callback crashes/malformed acknowledgements keep the durable submitting
  fence. Only a definite pre-enqueue rejection permits rollback.
- Permanent admission rows retain only state/semantic identity; bounded cleanup
  compacts legacy rows and sanitizes reasons without discarding replay protection.
- A run that never binds to a live executor must still terminalize exactly once
  so its coordinator releases the conversation. Runtime submission retries are
  bounded by a pre-start deadline, not permanent busy state.
- Queued start failure emits one structured completion and advances the queue.
  Adopt an ambiguously started child already in the registry rather than emit a
  second synthetic completion.
- On lost gateway process, allow the bounded completion grace window for a real
  late bus event to win before synthesizing failure. Idle timeout `0` explicitly
  disables the watchdog; cancellation still works.
- Restart drain (`RestartCarryover`, a `LemonCore.Drain` participant): while
  draining, coordinators keep queued work queued; after sealing they refuse new
  submissions. A run is paused cleanly only when no effectful action (tool,
  command, file change, web search, subagent) is executing; a forced pause is
  carried as uncertain and its continuation must tell the model not to repeat
  the cut-off action. Carried items get fixed run IDs when persisted so a
  repeated replay is idempotent; never resubmit them under fresh IDs.

## Output and compaction

- Emit `LemonCore.DeliveryIntent`; channel renderers decide payloads, send/edit,
  truncation, buttons and platform indices. Never construct `OutboundPayload`.
- `SurfaceManager` coordinates answer/status/task surfaces; coalescers aggregate
  semantic output. Preserve parent/task IDs and safe failure metadata upstream,
  rather than reconstructing hierarchy in adapters.
- Finalization is terminal for a stream: late flushes must not overwrite the
  final multi-chunk answer with an old truncated snapshot. If coalescer finalizing
  fails, dispatch the final text directly. Already-streamed answers finalize the
  existing answer surface before clearing coalescer state.
- `SurfaceManager.finalize_answer/3` returns `{:error, {:dispatch_failed, reason}}`
  on rejected final delivery; do not finalize the streamed coalescer after that
  rejection. Best-effort artifact enrichment and termination cancellation must
  not prevent final-answer or terminal-event handling.
- Artifact enrichment failure cannot block answer finalization. Files and
  `MEDIA:` directives reach channels only through checked `auto_send_files`:
  existing files under cwd, no symlink escape. Strip host-only directive text.
- Child task updates stay on their original task surface across later assistant
  turns. Chat status excludes internal reasoning; operator views may expose only
  the intended structured visible action stream.
- Async task-surface subscribers restart transiently after abnormal exit and
  re-subscribe; normal terminal events stop them. This does not replay lost deltas.
- Pending compaction prompt mutation belongs here. Prepare a fresh marker before
  submit and consume only after coordinator acceptance. Submission failure leaves
  it retryable; stale/empty markers may clear eagerly. Preserve secure envelopes
  and whole-entry truncation when rebuilding context.
- Use `PendingCompactionStore` and shared domain wrappers. Channels own Telegram
  state/resume indices; discover human-readable targets through `TargetDirectory`.

## Configuration and verification

Config supplies model/thinking defaults; `LemonCore.PolicyStore` owns effective
session/route/chat policy. Do not read app-env default models or policies as a
second runtime plane. Provider resolution uses `LemonAgent.ProviderConfigResolver`.
Validate configured runtime wiring while preserving router-only startup and
explicit unavailable-runtime behavior.

From the umbrella root: `mix test apps/lemon_router/test`.
Exercise concurrent fixed-ID submit/abort, unknown outcomes, queued start failure,
stream-finalization races and restart cleanup with explicit synchronization.
Changes to dependency boundaries also require the integrated architecture check.
