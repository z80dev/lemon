# LemonLsp changelog

## [Unreleased]

### Added

- Configured language-server launches use the core native-process seam for
  opt-in durable local process-group ownership tracking, preserving session and
  protocol bounds.
- `LemonLsp.WorkspaceRoot.detect/3` picks a file's workspace root: the
  outermost Mix umbrella, Cargo, npm/yarn/pnpm, Go or uv workspace inside the
  working directory, else the nearest root marker (#690).

### Changed

- `LemonLsp.ServerManager` keeps at most eight sessions live. Acquiring a new
  pool beyond that stops the least-recently-used session with no in-flight
  request (status `:evicted`, owners get `:server_stopped`) or fails with
  `{:error, :lsp_session_limit}` when every session is busy. `status/0` reports
  `max_active_count`; `:workspace_root_detection` moved from
  `planned_capabilities` to `capabilities`, joined by `:live_session_cap` (#690).

### Fixed

- Non-UTF-8 document text, URIs and language ids are refused with
  `{:error, :invalid_document_encoding}` (or `:invalid_document_uri` /
  `:invalid_language_id`) instead of crashing the shared session; transport
  failures return error replies such as `{:error, :invalid_message_encoding}`.
  Session calls catch every exit: abnormal exits and call timeouts return
  `{:error, {:session_crashed, :abnormal_exit | :timeout}}` without the raw
  reason (#663).
