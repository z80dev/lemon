# CodingAgent changelog

## Unreleased

### Fixed

- Tool approval requests now fail closed on exceptions, exits, throws,
  malformed responses, and unsupported scopes instead of auto-authorizing
  execution. Raw service error payloads are excluded from results and logs.
  Explicit supported approvals still execute exactly once; errors raised by
  the approved tool remain outside the approval failure boundary.
- Approval timeout results no longer raise when the configured wait is infinite.
