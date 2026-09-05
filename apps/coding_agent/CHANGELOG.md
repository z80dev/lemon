# CodingAgent changelog

## Unreleased

### Fixed

- Tool approval requests now fail closed on exceptions, exits, throws,
  malformed responses, and unsupported scopes instead of auto-authorizing
  execution. Raw service error payloads are excluded from results and logs.
  Explicit supported approvals still execute exactly once; errors raised by
  the approved tool remain outside the approval failure boundary.
- Approval timeout results no longer raise when the configured wait is infinite.
- Restricted tool profiles now deny `hashline_edit`, `memory_topic`, and `task`,
  closing alternate editor, topic-memory mutation, and child-delegation gaps.
  Full-access and orchestrator profiles are unchanged. These remain tool-name
  restrictions, not a sandbox or classification of arbitrary extension tools.
- Bash streaming previews now retain only the most recent 50,000 output bytes
  plus a fixed omission marker, rather than growing an unbounded duplicate of
  all command output. UTF-8 boundaries and small-binary ownership are preserved.
  Final results and full-output files are unchanged; this does not implement
  end-to-end mailbox or Port backpressure.
