# CodingAgent changelog

## Unreleased

### Changed

- Consolidate memory tools as `remember` (compact USER.md/MEMORY.md facts) and
  `recall` (past conversations and longer workspace notes); remove the former
  search, topic, and session-browse tool surfaces.

### Fixed

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
