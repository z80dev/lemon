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
- Coordinators have no idle-stop path or population cap: distinct conversation
  keys accumulate processes for the VM lifetime. Per-conversation backlog bounds
  do not bound this population. See the
  [admission inventory](../../docs/architecture/admission-gates.md).
- Task/delegated auto-followups prefer steer with follow-up fallback. Do not merge
  separate provenance-bearing async completions during debounce. Record the final
  delivery disposition/receipt after router mutation, not before.
- Channel ingress is `LemonChannels.Runtime.submit_inbound/2` ->
  `RunRequestBuilder.from_inbound/1` -> `RouterBridge.submit_run/1`; there is no
  router-side inbound entry point. Only a non-empty binary run ID acknowledges
  success; malformed acknowledgements are outcome-unknown, not permission for
  an automatic retry.
- Public busy/active queries go through `Router`/`RouterBridge`. Registry and
  read-model failure is unavailable, never an invented idle or empty state.
- Abort/keepalive `:ok` acknowledges dispatch, not synchronous target application.
- Unexpected exceptions in router callbacks/state transitions reach OTP
  supervision, not fabricated `:ok`, nil or unchanged state.

## Receipt barrier failure model: power loss

The user chose **power loss, done cheaper**, not just VM restart protection.
SQLite receipt/admission writes use the explicit-server Store mutation API with
`durable: true`. Store serializes the entire scope: switch this connection to
`synchronous=FULL`, enable `fullfsync=1` on Darwin, commit the mutation, then
restore NORMAL and disable fullfsync. The commit is the acknowledgement barrier.
Ordinary writes (sessions, chat, runs, etc.) remain NORMAL; do not make FULL a
backend-wide default. Non-SQLite backends retain their sync barrier on durable
writes and authority reads (`Store.confirm_durable/1`); that confirmation is a
no-op on SQLite, never a checkpoint. Failed durable writes/barriers return
`:outcome_unknown`, never automatic retry.

Receipt reads, existing-record lookups and `presence_snapshot` do not checkpoint.
Keep `Store.sync/1` / `TRUNCATE` for the graceful-drain seal. VM restart alone
would require only commit, but losing an acknowledged fence after power loss
could repeat an external side effect, so that weaker option was rejected.

Measured on the implementation host: NORMAL commit plus TRUNCATE took p50
18.3 ms; FULL plus fullfsync commit took p50 6.5 ms / p95 9.5 ms. The earlier
empty-WAL optimization was rejected (empty checkpoint p50 7 µs versus 32 µs
for a filesystem-stat fast path). These are host/filesystem-specific results,
not universal latency guarantees.

Measure on the target filesystem from the umbrella root with
`MIX_ENV=test mix run --no-start apps/lemon_core/bench/sqlite_sync.exs`. It reports
realistic non-empty WAL latency, empty-WAL checkpoint latency, and single-receipt
NORMAL-plus-checkpoint, FULL-commit-only and NORMAL-commit-only p50/p95
microseconds, including the connection's `fullfsync` setting. Record the measured
revision alongside results; timings are host/filesystem-specific.

## Cancellation and completion

- Serialize fixed-ID aborts with admission. Durable abort fences prevent later
  execution even after in-memory tombstones expire; accepted work follows normal
  cancellation. Failed fence registration must propagate as an unknown mutation.
- Admission callback crashes/malformed acknowledgements keep the durable submitting
  fence. Only a definite pre-enqueue rejection permits rollback.
- Permanent admission rows retain only state/semantic identity; bounded cleanup
  compacts legacy rows and sanitizes reasons without discarding replay protection.
- A run that never binds to a live executor must still terminalize exactly once
  so its coordinator releases the conversation. Retry only runtime unavailability,
  bounded by the pre-start deadline; definite rejection terminalizes once.
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
