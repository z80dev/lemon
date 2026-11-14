# LemonMCP contributor guide

`lemon_mcp` implements MCP clients for stdio, Streamable HTTP and legacy HTTP+SSE.
It connects Lemon to external tools/resources/prompts. Protocol structures and
encoding are shared; the host app owns client lifecycle. See [README](README.md)
and [skills integration](../../docs/skills.md#mcp-model-context-protocol-server-integration).

## Lifecycle

- This is a library application with no application callback or supervisor.
  Consuming apps start and supervise every client/transport they need.
- Runtime releases include `lemon_mcp: :load` before dynamic consumers such as
  `LemonSkills.McpSource`; do not change it to a permanently started empty app.
- Handshake is asynchronous; respect the client's ready/call-timeout contract.
  Transport loss must fail waiting calls and clean up owned subprocesses.
  The stdio transport traps exits and, on `close/1`/`terminate/2`, terminates the
  server's whole process group via `LemonCore.ProcessGroup.terminate/2` (TERM,
  bounded grace, KILL); closing the Port alone only sends stdin EOF.
- Stdio currently merges stderr into stdout; startup logs can be non-JSON lines.
  Do not expose raw process output in public errors or confuse it with protocol
  success. Maintain bounded parsing and request identity.

## Authentication and sampling

- HTTP OAuth discovers protected-resource/authorization metadata with
  metadata-only headers. Never forward configured MCP auth headers or bearer
  tokens to metadata URLs.
- Prefer refresh-token grant after an eligible 401; preserve rotated refresh
  tokens. Fall back to client credentials only according to the existing flow.
- Public-client PKCE uses the explicit authorization-code callback boundary.
  Validate returned state; low-level clients do not own UI, callback listeners or
  Lemon secret storage. Higher layers inject those services.
- Tokens are process-local unless the caller supplies token-cache load/save
  callbacks. Persist successful exchanges/rotations through that boundary.
- Stdio sampling is opt-in. Advertise it only when `sampling_policy` or an
  explicit handler can answer requests. Prefer reviewed-model policy with local
  model/token bounds and redacted review before a delegate sees raw params.
- `LemonSkills.McpSource` may bridge review to `ExecApprovals`. Approval metadata
  contains hashes, model/token/message counts and kinds, not raw request text.
  A low-level `sampling_handler` caller owns equivalent review/policy itself.
- Unsupported remote resources/prompts return protocol errors; do not fabricate
  support or silently reinterpret failures as valid empty results.

## Verification

From the umbrella root: `mix test apps/lemon_mcp/test`.
Use existing HTTP/SSE fixtures and controlled stdio processes. Test auth header
isolation, PKCE state mismatch, token rotation, disconnect and call timeout.
Bandit/Plug are test dependencies, not client runtime dependencies.
Release smoke checks should confirm clients/source modules load, MCP feature
recognition works, and the library has no application callback or running empty
supervisor. See [release flows](../../docs/release/deployment_flows.md).
