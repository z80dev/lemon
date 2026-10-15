# CodingAgent changelog

## Unreleased

### Added

- Web-search requests sent directly to `api.perplexity.ai` now include an
  `X-Pplx-Integration: lemon` header so Perplexity can attribute Lemon traffic.
  Requests routed through OpenRouter or custom compatible endpoints are
  unchanged.

### Changed

- Consolidate memory tools as `remember` (compact USER.md/MEMORY.md facts) and
  `recall` (past conversations and longer workspace notes); remove the former
  search, topic, and session-browse tool surfaces.

### Fixed

- Grep pages are sorted by path and line across both engines. Partial ripgrep
  errors preserve matches with warnings, and lookaround/backreferences select
  PCRE2 or explain the unsupported Rust-regex construct. The Elixir fallback
  now has a 30-second deadline, a 4 MiB leading-file window with oversized-file
  counts, and stops once the requested page is filled.
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
