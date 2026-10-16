# CodingAgent changelog

## [Unreleased]

### Added

- Named workers advertise and execute Codex device login start/poll/cancel plus
  internal single-use completion/settlement on the authenticated destination.
  Writing completion stays bound to the initiating worker/controller generation
  and a five-second authorization; non-writing settlement remains reachable after
  node expiry/re-pairing without gating revocation. Exact binding rejections remain
  provably non-writing through the control-plane adapter. Local execution-directory
  options and exact login bindings are preserved; only public state is returned.

- Opt-in `semantic_find` tool maps a plain-language behavior description to
  `path:line` code locations. It is off by default and registered only when
  `[runtime.tools.semantic_find] enabled = true` and an explicit small model
  (`semantic_find.model`, else `model_roles.tiny`/`smol`) is configured; it never
  uses the active session model. Candidate lines come from a bounded local scan
  (no embedding index or second store), the model only chooses among numbered
  candidates, and `max_tokens` (default 8000) caps every call. Provider-reported
  usage is recorded through `LemonCore.UsageLedger` against the run and session,
  with an unknown price left unknown. Distinct from `find` (file-name globs).
  Complete role chains resolve without fallback. Prompt budgeting reserves a
  byte-level upper bound and message overhead before completion; unaudited
  provider/API pairs (including Codex without an output limit) fail closed.
- `bash` keeps cwd and exported environment between foreground calls within a
  session (in memory, confined to the workspace, fresh for new sessions); `reset:
  true` or resetting the session clears it and invalidates in-flight captures.
  State expires with its owning session, exported functions are excluded, and
  private capture files are cleaned up even after detachment or queued cancellation.
  Saved cwd validation follows symlinks before parent components and fails closed
  on resolution errors, including directories replaced between calls.
  ACP client-terminal calls remain stateless and receive no host-local capture
  redirections, supporting clients with a separate filesystem.
- Named workers advertise owner-authorized provider management methods and execute
  them against destination-local provider configuration and encrypted credentials,
  rejecting writes whose exact target identity belongs to another machine.
  Project credential/default overrides are resolved from the worker's configured
  execution directory; management RPCs cannot supply filesystem paths.
- `CodingAgent.SettingsManager.model_routing` exposes the raw root
  `[model_routing]` table (default `%{}`); sessions show the actual routed model
  per assistant turn with run-unique activity identities, and an explicit model
  choice bypasses automatic routing. Automatic selection provenance survives
  session reset, save, resume, tree/entry navigation, committed rewinds, and plan
  entry/exit or approval (including resume while planning); internal model
  transitions reapply the automatic cost cap or explicit-selection bypass.
  Parentless Coordinator and task callers also retain legacy explicit model
  selections when provenance is omitted or nil; inherited provenance and an
  explicit `false` continue to preserve automatic routing and its cost cap.
  Delegated children preserve inherited selection provenance; persona model/role
  and task-agent config defaults remain automatic rather than bypassing the cap.
  Fallback candidates
  rejected before provider invocation do not appear as the actual model in
  activity events or the usage footer.

- Truncated webfetch and browser snapshot/page-content results retain complete
  sources as session-scoped artifacts and return readable `artifact://` handles.
  Cached fetches register handles in the requesting session, never another caller.

- `ast_grep` refuses scopes above `max_files` (default 1000), retains successful
  files alongside bounded per-file parse/CLI errors, and exposes session artifact
  handles for complete spilled match results.

- `read file.json?q=filter` supports native jq-subset field/index traversal,
  iteration, pipes, keys, length and scalar select comparisons, with ordinary
  read-budget pagination and literal-filename precedence.

- `write archive:member` adds or replaces ZIP/TAR/tar.gz/tgz members atomically,
  preserving unrelated member data and enforcing physical archive mutation guards.

- `write` supports parameterized SQLite row inserts, primary-key/rowid updates
  and keyed deletes in existing databases, with JSON scalar/column validation
  and the normal mutation guards.

- LSP supports preview/apply file renames, server reload, advertised capabilities,
  and bounded workspace diagnostics from running clients. Document language IDs
  now come from the shared LemonLsp server catalog.

- Local Go diagnostics run `go vet ./...` rather than executing tests. External
  diagnostic checker deadlines now terminate the OS process tree on timeout.

- Debug adds js-debug, CodeLLDB, netcoredbg and Ruby rdbg adapters, loopback
  listening-adapter transport, capability-gated log points, data/instruction
  breakpoints, memory reads and disassembly (128 KiB cap). Timeouts clamp to 5..300s.

- Eval supports bounded rich `display` outputs (PNG/JPEG, Markdown and JSON) over
  a stdout-independent side channel, Python `%pip install` / `%load` magics, and
  interrupt-first timeout handling with a two-second grace before killing kernels.

- Bare reads of source files with at least 300 lines and at most 2 MiB now return
  bounded structural summaries with declarations and explicit omitted ranges.
  Summaries are immutable, omit edit snapshots, and are rejected by overwrite
  safety checks. Selectors, offset/limit, `summary: false`, or the host's
  `structural_summary: false` option retain full reads; ACP unsaved buffers use
  the same outline behavior.

- Task batches honor each child's `async` and `thinking_level` overrides; mixed
  batches join synchronous children while returning background receipts. Wait
  yields a non-cancelling snapshot after 30 minutes or when steering arrives.

- Foreground bash previews retain a 20 KiB head plus tail with an explicit middle
  elision marker. Spill notices prefer session artifact handles over raw paths,
  and unavailable PTYs report their fallback in both output and result details.

- Local edit and patch support the same opt-in formatting as write and return
  post-format snapshot tags. Anchored edits recover recent session/path tags
  only when every referenced original range remains byte-identical and unique;
  snapshot history is bounded, and text-edit staleness checks are unchanged.

- Session-scoped `local://name` scratch files support read, write and bash URL
  expansion. `proc://` lists owned processes; process URLs peek output, write
  stdin or terminate through `/kill`.
- Read supports GitHub `issue://` and `pr://` views and indexed PR diffs, preferring
  authenticated `gh` for private repositories. `history://task_id` shows a bounded
  visible transcript of an owned child task without hidden reasoning.

- Find sorts the complete candidate set before applying `max_results`, with
  `sort: "mtime"` for newest-first (path tie-breaks) or the existing default
  `"path"`. Slash globs use full-path matching in fd as in the fallback;
  scopes exceeding 100,000 candidates fail with a narrowing hint.

- Grep and find accept semicolon-separated roots, merge/deduplicate results before
  paging, and report missing roots without discarding existing ones. Grep long
  lines now show a match-centered 500-character window and the original column.

- Grep supports `output_mode: content|files|count`, with paged paths or per-file
  matching-line counts and a total. Newline patterns search across lines in both backends.

- Background process controls now support exact stdin writes and EOF through
  `process_input`, non-consuming `bash_output` peeks, and graceful `kill_process`
  SIGTERM with a two-second SIGKILL fallback (or explicit immediate kill).

- Web-search requests sent directly to `api.perplexity.ai` now include an
  `X-Pplx-Integration: lemon` header so Perplexity can attribute Lemon traffic.
  Requests routed through OpenRouter or custom compatible endpoints are
  unchanged.
- Read accepts comma-separated line/range/count windows, sorts and merges them,
  and preserves original line numbers with a single snapshot header. Single
  non-raw bounded selectors include one preceding and three following context
  lines; raw and comma-list windows remain exact. Overwrites reject selector
  elision markers rather than copying omitted content into existing files.

### Changed

- Seen-line edit protection now defaults on: anchored edits to lines not shown in
  a numbered read are refused. Disable with `[runtime.tools.edit]
  enforce_seen_lines = false`. The Git guard remains on by default
  (`[runtime.tools.bash] git_guard = false` disables it).
- A native session that shuts down expires the approvals it still has pending
  (`LemonCore.ExecApprovalExpiry.session_ended/1` from `terminate/2`), so an
  orphaned approval is denied instead of staying answerable. An expired
  approval's action reports `ok: false`, "expired because its run ended".

- Normalize module aliases, implicit exception handling and direct function calls
  in recently changed coding-agent modules and tests without changing runtime behavior.

- Deadline-owning task/wait, agent delegation, bash, eval, debug, question and
  browser tools explicitly retain their own limits under the agent runtime's
  new five-minute default tool deadline and eight-call concurrency cap.

- Todo plans preserve `blocked` and `abandoned` statuses, optional phase/blocker
  notes and stable IDs in the journal and client projections. Writes keep only
  the first in-progress task active; progress reports all statuses, and actionable
  tasks exclude blocked/abandoned work. Terminal checklists show phases and notes.

- Consolidate memory tools as `remember` (compact USER.md/MEMORY.md facts) and
  `recall` (past conversations and longer workspace notes); remove the former
  search, topic, and session-browse tool surfaces.

### Fixed

- Interrupted LSP server-requested edits retain captured paths in `affected_paths`
  and warn when a checkpoint's edit outcome is unknown, while preserving confirmed
  `changed_files` and merging affected paths across batches.

- Disclosure telemetry coverage isolates the initializing process and exercises
  a foreign initialization deterministically, preventing unrelated sessions from
  substituting their measurements in the once-per-initialize assertion.
- Shared `webfetch` requests detach cancelled callers independently; when every
  caller aborts, provider requests and PDF extraction stop without paid fallback
  or cache publication. Provider admission and cache publication refresh caller
  cancellation even before the next abort poll; publication is atomic with its
  live-flight authorization, so cancellation cannot detach a flight mid-write.
  Persistence runs outside the shared server so stalled writes cannot block
  unrelated search/fetch admission, cancellation or completion. The original
  flight deadline stops stalled publication; already-completed writes are not
  rolled back. Replacement requests keep their own flight lifecycle.

- Document backend guardians retain a witnessed process-group leader until
  cleanup, so timeout, abort and caller death stop even redirected descendants
  of immediately exiting converters without signaling unrelated processes.

- Native-followup context tests restore their global coordinator even when setup
  fails, preventing foreign submissions and later cron cancellation tests from
  inheriting a fixture dispatcher.

- Native `eval` binds the kernel's reported pid and process group as a
  `ps`-verified witness at startup and, on reset, abort, owner loss, idle
  disposal and crash, stops that group including children reparented after
  their launcher exits. A ready frame naming a foreign group is refused and
  never signalled; unrelated processes are untouched.
- Child clarification requests release a matching task join only after the parent
  acknowledges enqueueing the question. A slow or suspended Session can no longer
  strand the question in an idle Agent or complete the caller before its answer;
  question errors, cancellation and context-overflow recovery retain the normal
  single-invocation lifecycle.
- Managed process capture attachments validate the exact launch owner and
  fingerprint without resetting output or logs. Cleared launches retain durable
  receipts and reject late capture writes; failed accounting or capture cleanup
  releases lifetime capacity once without dropping unreclaimed artifact charges.
  Clearing a process now leaves its reconciliation session alive when the Store
  refuses deletion.
- Sessions retain current-turn error/cancellation terminals until the next turn;
  fenced subscribers classify aborted, failed and length-limited answers truthfully.
  Tagged direct subscriptions fence stale unsubscribe closures by generation.
- Native session death expires pending execution approvals even when the session
  is forcibly killed, including approvals without run IDs or time limits. Late
  answers cannot grant access after the owner dies.
  Ownership survives expiry-worker restarts before the first approval, including
  unregistered sessions and sessions using custom registries.

- Session subscriptions start with a targeted selected-branch journal todo
  snapshot, without emitting empty events for pristine branches or duplicate
  events for unchanged plans. Unsupported or unreadable journal entries report
  unavailable rather than an empty plan; recovery excludes task-child owners and
  fails closed on ambiguity, unavailable registered-owner inspection, or
  unreadable process receipts. Compaction still accepts directly registered
  session owners, and context accounting retains its saved-state fallback when
  a live session retires during the read.

- Patch hunks retry whitespace and typographic-punctuation normalization only
  after an exact miss, reject ambiguous matches, and preserve original context.

- Local overwrite format detection reads only a 64 KiB leading window rather
  than loading the entire existing file.

- Local patches refuse stale updates, deletes, and move sources before writing
  any operation; filesystem errors now use actionable messages without raw terms.

- Grep pages are sorted by path and line across both engines. Partial ripgrep
  errors preserve matches with warnings, and lookaround/backreferences select
  PCRE2 or explain the unsupported Rust-regex construct. The Elixir fallback
  now has a 30-second deadline, a 4 MiB leading-file window with oversized-file
  counts, and stops once the requested page is filled.
- File overwrites reject truncated read output and preserve existing UTF-8 BOMs
  and dominant CRLF endings, including ACP writes with available prior content.

- Named-node file requests no longer return `filesystem_failed` when a parent
  symlink is swapped back to a directory while the path resolves. Each component
  is classified with one descriptor-relative `readlinkat`, so concurrent
  replacement yields `not_found`, `path_not_allowed` or `not_directory`, or acts
  on the directory actually present inside the root; nothing is written outside
  it.
- Swarm nodes inherit the execution context captured when the swarm launched
  instead of re-reading parent session state per node, and persona `spawns`
  keeps its `task` grant under preset tool-policy floors while other
  leaf-worker denials remain.
- Session rewind ignores checkpoint inspection IDs as restore sources and refuses
  filesystem restoration across manual, unknown, or interrupted checkpoint
  restores, including bridged and historical filesystem-checkpoint calls.
  Persisted conversation-only `checkpoint(goal)` calls remain safe to rewind,
  including direct, bridged, and interrupted calls following recoverable edits.
- Rewind regression workspaces resolve trusted temporary-directory aliases before
  deriving checkpoint paths, so macOS exercises recursive capture/restore and
  symlink-parent refusal rather than failing on the system temporary-directory alias.
- Native executor turns retain `eval`, debugger and language-server resources
  across successful save/stop/resume boundaries. Durable session registry keys
  remain the owner; reset/delete, explicit abort/stop, unexpected owner death and
  idle expiry still dispose of them.
- Native tool-resource handoff requires a successful save; uncertain handoffs
  explicitly dispose resources. Abort signals blocked tools before disposal,
  and reset rebuilds tool closures and approval/hook contexts for the fresh ID.
- Debug servers stop when their owner exits during adapter disposal, including
  teardown with child sessions. WASM host-call cancellation is invocation-local:
  a timed-out sibling does not abort the parent, while parent abort cancels all
  outstanding calls.
- Debug adapter waits also observe the originating invocation worker's lifetime,
  so a cancelled WASM host call releases the debug server even after its local
  abort signal has been reclaimed; the parent and sibling calls remain usable.
- Eval cleanup retains the exited kernel's process-group identity so crashed
  roots cannot orphan subprocesses; JavaScript uses a detached group host with
  pipe-EOF teardown. Kernel input preserves UTF-8 across reads and output spills
  become private before content is written.
- Debugpy port attach connects to the existing DAP endpoint instead of starting
  another local adapter; attached targets are disconnected without being killed.
- Filesystem rewind refuses arbitrary `eval` and executing or unknown `debug`
  effects even after errors or interruption; shell-only partial consent cannot
  claim those effects were restored. Explicit debug inspection stays read-only.
- Rewind consumes all chronological LSP checkpoint receipts, including failed
  batches, in reverse order so overlapping file/directory edits restore correctly.
- SQLite regression coverage separates fragment rejection from real-engine
  readonly/query-only CTE write refusal; text primary keys preserve leading zeros.
- Rich `read` line selectors honor `:raw`, grep byte-capped pages advance only
  past emitted matches, and fallback searches honor hierarchical `.ignore` rules.
- Bash approval and operator action projections omit all env values, including
  malformed data and bridged `tool_invoke` arguments, without changing execution.
- PDF `webfetch` no longer probes or executes automatically discovered project
  or ancestor read-format virtual environments. It uses system backends or an
  explicitly operator-trusted `:pdf_python`, rejecting relative/project PATH
  resolution and project symlink targets, with isolated Python imports;
  extracted page text remains untrusted web content.
- Bridged tool invocation retains its outer transcript identity while rewind
  classifies the actual target's mutations and shell commands.
- `BashExecutor` keeps output that races an abort or timeout: a chunk that
  arrives after the abort flag is set, or is already in the mailbox when the
  process tree is killed, is now part of the partial result instead of being
  dropped.
- Tool approval requests now fail closed on exceptions, exits, throws,
  malformed responses, and unsupported scopes instead of auto-authorizing
  execution. Raw service error payloads are excluded from results and logs.
  Explicit supported approvals still execute exactly once; errors raised by
  the approved tool remain outside the approval failure boundary.
- Approval timeout results no longer raise when the configured wait is infinite.
- Restricted tool profiles deny `hashline_edit`, `remember`, and `task`,
  closing alternate editor, memory mutation, and child-delegation gaps.
  Full-access and orchestrator profiles are unchanged. These remain tool-name
  restrictions, not a sandbox or classification of arbitrary extension tools.
- Bash streaming previews now retain only the most recent 50,000 output bytes
  plus a fixed omission marker, rather than growing an unbounded duplicate of
  all command output. UTF-8 boundaries and small-binary ownership are preserved.
  Final results and full-output files are unchanged; this does not implement
  end-to-end mailbox or Port backpressure.
