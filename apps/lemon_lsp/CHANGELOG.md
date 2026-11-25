# LemonLsp changelog

## [Unreleased]

### Added

- Configured language-server launches use the core native-process seam for
  opt-in durable local process-group ownership tracking, preserving session and
  protocol bounds.

### Fixed

- Non-UTF-8 document text, URIs and language ids are refused with
  `{:error, :invalid_document_encoding}` (or `:invalid_document_uri` /
  `:invalid_language_id`) instead of crashing the shared session; transport
  failures return error replies such as `{:error, :invalid_message_encoding}`.
  Session calls catch every exit: abnormal exits and call timeouts return
  `{:error, {:session_crashed, :abnormal_exit | :timeout}}` without the raw
  reason (#663).
