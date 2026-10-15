# CodingAgent changelog

## Unreleased

### Added

- `ast_grep` refuses scopes above `max_files` (default 1000), retains successful
  files alongside bounded per-file parse/CLI errors, and exposes session artifact
  handles for complete spilled match results.

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
- Rewind regression workspaces resolve trusted temporary-directory aliases before
  deriving checkpoint paths, so macOS exercises recursive capture/restore and
  symlink-parent refusal rather than failing on the system temporary-directory alias.
- Native executor turns retain `eval`, debugger and language-server resources
  across successful save/stop/resume boundaries. Durable session registry keys
  remain the owner; reset/delete, explicit abort/stop, unexpected owner death and
  idle expiry still dispose of them.
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
