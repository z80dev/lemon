# CodingAgent contributor guide

`coding_agent` owns native coding sessions, tool execution/policy, JSONL session
history, compaction and supervised delegation. The loop/model runtime comes from
`lemon_agent`; provider protocols come from `lemon_ai`. See [README](README.md).

## Session and prompt boundaries

- Keep `CodingAgent.Session` as the public GenServer; lifecycle, persistence,
  notifier, compaction and overflow helpers own their internal concerns.
- JSONL history is a tree of entries with stable IDs/parents. Preserve branch,
  compaction and async-followup provenance when restoring context. Unknown retired
  custom entries may be skipped; do not rewrite old history destructively.
- Profiles derive assistant workspace from validated `meta.profile_id` through
  `ProfileStore`, never a caller-supplied path. Default workspace is
  `~/.lemon/agent/workspace/`; profile homes stay isolated.
- Main bootstrap includes identity/user/memory files. Subagents receive only
  `AGENTS.md` and `TOOLS.md`; do not leak personal workspace memory to children.
- Main personal-memory bootstrap projections carry deterministic capacity labels;
  labels do not modify files or bypass the subagent bootstrap allowlist.
- Compose static system prefix before volatile context. Capture environment once
  per session, not on every refresh. Stable skill metadata belongs in the prefix;
  turn-local relevance and recall do not. Preserve model replay bytes while
  stripping injected recall from user-visible transcripts/hooks.
- `remember` writes workspace `USER.md`/`MEMORY.md`; `recall` searches scoped past
  runs and workspace notes. Automatic recall is bounded local volatile context,
  skips short/subagent/unscoped requests and makes no model call. See
  [memory](../../docs/user-guide/memory.md).

## Tools and trust

- Register coding tools in the existing tool registry; assistant-platform tools
  belong in `lemon_skills`. Reuse common tool/result types and abort signals.
- Policy/approval checks run before execution. Tool precedence and extension
  conflict behavior belong to the registry, not per-tool fallback logic.
- Pre-LLM composition is guardrails → untrusted boundary → custom transform.
  Bound oversized output with stable spill references, fence external/file/shell/
  community-skill data, strip unsafe controls, and keep the entire envelope inside
  its budget. An opaque ephemeral marker provides idempotence; tool-returned
  metadata cannot claim wrapping already happened. Persisted output is unchanged.
- Background process ownership is session-scoped. Keep terminal backends under
  `ProcessManager` so policy, logs, cancellation and restart lineage are shared.
- Validate backend allow/deny policy and Docker/SSH settings before launch.
  Approvals expose command/cwd hashes and env keys, not commands, raw targets or
  env values. Validate env names/string values and checkpoint path lists first.
  Risky-command checkpoints occur before process start.

## Tasks and background work

- `task`/`@name` personas launch native in-process sessions via `Coordinator`;
  `agent` delegates through router and can choose a named node. Do not restore
  vendor CLI runners or another agent engine.
- Async launch receipts are not completed answers. Explicit joins suppress the
  corresponding followup; `wait_any` suppresses only its completed winner and
  releases other reservations. Crashed joiners cannot suppress completion forever.
- `TaskStoreServer` serializes event/suppression/lifecycle writes. Terminal result
  is first-writer-wins; late running events cannot revive it. RunGraph persistence
  loads before accepting writes, not in a later fold that can overwrite them.
- Supervisor admission failure terminalizes task/graph/budget/progress state.
  Worker/session death must end bounded waits. Completion followup failure does
  not turn a completed task into a failed worker.
- Delegated router watcher timeout is tracking loss, not proof that the remote
  run failed. Preserve fixed task/run identity for reconciliation.
- `BackgroundRun` gives `/bg` its own full-tool session without appending to a
  parent. Channel callers use scoped APIs and receive not-found for foreign IDs.
  Unresumable queued/running work becomes lost on restart.
- `SideQuery` uses an atomic frozen snapshot, no tools and a distinct ephemeral
  session. It never mutates/steers its source conversation. Public background/
  side-query failures are bounded classifications, not raw provider/store terms.
- Parent questions bind parent session/agent and child run lineage. Creation and
  terminal transitions are serialized; joins yield on pending questions rather
  than deadlock parent and child. Only the authorized parent can answer.
- Public task results contain visible assistant output and safe metadata, not
  hidden thinking, raw event history or tool-call internals.

## Named execution nodes

- Pairing stores session/recovery credentials in private node-ID-keyed records
  (0700 directory, 0600 files) bound to the exact controller URL. ID lookup without
  that URL returns no credentials. Re-pair renews the same identity; legacy repair
  requires explicit operator authorization.
- Prefer `LEMON_NODE_OPERATOR_TOKEN` / `LEMON_NODE_TOKEN` to flags. Off-loopback
  uses `wss://`; plaintext requires explicit opt-in over a verified secure overlay.
- The worker accepts the native run method, validates local cwd and strips routing
  `meta.node`. Only JSON-safe execution data crosses the wire; source callbacks,
  executor options, provider credentials and BEAM state never do.
- Destination credentials/cwd are local. Relative cwd resolves from worker cwd.
  Disconnect, caller death, explicit cancel, timeout or node replacement cancels
  destination work. Steer/redirect text is bounded and invocation/session-bound;
  acknowledge only after the live native session accepts it.
- Respect payload/depth/item limits and bounded streaming accumulation. Preserve
  protocol ping/idle-timeout compatibility without another session-liveness API.
  See [CLI](../../docs/user-guide/cli.md) for launch commands.

## Verification

From the umbrella root: `mix test apps/coding_agent/test`.
Use temporary workspaces, controlled providers and supervised process cleanup.
Tests touching global extension caches/process stores/env run non-async and
restore state. Globally named test recorders must not be linked to a dying test;
use monitor-confirmed teardown rather than `whereis`/stop races.
Test user-visible output/details, policy refusal, cancellation, restart and
cross-session access. See [bootstrap](../../docs/assistant_bootstrap_contract.md)
and [parent questions](../../docs/subagent-parent-questions.md) for detailed contracts.
