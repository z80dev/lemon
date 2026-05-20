# ACP Preview

Lemon exposes a preview Agent Client Protocol bridge for ACP-shaped clients
that need to create sessions and submit prompt turns into Lemon. The bridge is
intentionally thin: it maps ACP JSON-RPC requests onto the existing Lemon router
run graph instead of creating a separate runtime path.

The current preview is implemented by `LemonControlPlane.ACP`, exposed over HTTP
at `POST /acp`, and packaged for spawned stdio clients through
`scripts/lemon_acp_stdio.exs`. It follows the official ACP JSON-RPC method shape
for the methods it advertises, while keeping unsupported media and editor
features out of the capability response.

## Supported Methods

| Method | Status | Behavior |
| --- | --- | --- |
| `initialize` | Preview | Negotiates protocol version and returns Lemon agent metadata plus honest capabilities and a safe summary of advertised client filesystem capabilities. |
| `session/new` | Preview | Creates a Lemon-backed ACP session for an absolute `cwd`, records safe client filesystem capability booleans, and returns an opaque `sessionId`. |
| `session/resume` | Preview | Recreates a session mapping for an existing ACP `sessionId` and `cwd`, preserving or refreshing safe client filesystem capability booleans. |
| `session/list` | Preview | Lists store-backed ACP sessions, with optional `cwd` filtering and redacted client filesystem capability metadata. |
| `session/prompt` | Preview | Converts ACP `text` and `resource_link` prompt blocks into a Lemon prompt, submits a router run, emits stdio `session/update` notifications while waiting, and returns ACP `stopReason` plus Lemon metadata. |
| `session/cancel` | Preview | Cancels the latest known run for the ACP session through `LemonRouter.abort_run/2`. |
| `session/close` | Preview | Cancels the latest known run and removes the ACP session mapping from the cache and store. |

The bridge advertises `sessionCapabilities.close`, `sessionCapabilities.list`,
and `sessionCapabilities.resume`. It does not advertise image, audio, embedded
resource, MCP HTTP, or MCP SSE support yet.

## Request Shape

`POST /acp` accepts JSON-RPC 2.0 request objects or batches:

```json
{
  "jsonrpc": "2.0",
  "id": "init-1",
  "method": "initialize",
  "params": {
    "protocolVersion": "1",
    "clientInfo": {
      "name": "example-client",
      "version": "0.1.0"
    }
  }
}
```

Create a session:

```json
{
  "jsonrpc": "2.0",
  "id": "new-1",
  "method": "session/new",
  "params": {
    "cwd": "/home/z80/dev/lemon",
    "mcpServers": []
  }
}
```

Submit a prompt:

```json
{
  "jsonrpc": "2.0",
  "id": "prompt-1",
  "method": "session/prompt",
  "params": {
    "sessionId": "acp_...",
    "prompt": [
      {
        "type": "text",
        "text": "Review the current checkout."
      },
      {
        "type": "resource_link",
        "name": "mix.exs",
        "uri": "file:///home/z80/dev/lemon/mix.exs",
        "mimeType": "text/x-elixir"
      }
    ],
    "_meta": {
      "lemon": {
        "timeoutMs": 60000,
        "model": "openai:gpt-5"
      }
    }
  }
}
```

By default, `session/prompt` waits through the same `agent.wait` path used by
the control-plane API. Set `_meta.lemon.wait` to `false` to submit a queued run
and return immediately. The response includes ACP `stopReason` and a
`_meta.lemon` object with `runId`, `sessionId`, `sessionKey`, status, and the
completed answer when a wait succeeds.

## Session Updates

When a stdio `session/prompt` waits for a Lemon run, the NDJSON runner
subscribes to the run topic and emits ACP `session/update` notifications before
the final prompt response:

- Lemon `:delta` events become `agent_message_chunk` updates with text content.
- Lemon `:engine_action` events become `tool_call_update` updates with tool
  call id, title, kind, status, and redacted message content.

The same stdio transport can also round-trip ACP agent-to-client JSON-RPC
requests while a prompt is waiting. Lemon currently uses this preview bridge
for `session/request_permission`, `fs/read_text_file`, and
`fs/write_text_file`, `fs/delete_file`, and `fs/rename_file` events emitted on
the run bus. It also subscribes to the shared `LemonCore.ExecApprovals` bus for
the active ACP session key and maps matching approval requests to ACP
`session/request_permission` decisions. The final prompt response records only
redacted request summaries, such as method names, permission outcomes, content
byte counts, and content hashes.

During stdio `initialize`, Lemon captures only safe booleans from
`clientCapabilities.fs.readTextFile` and
`clientCapabilities.fs.writeTextFile`, `clientCapabilities.fs.deleteFile`, and
`clientCapabilities.fs.renameFile`. Those booleans are carried into
`session/new` and `session/resume`, surfaced through `session/list`, and copied
into the Lemon run request metadata as `acp_client_fs_read_text_file`,
`acp_client_fs_write_text_file`, `acp_client_fs_delete_file`, and
`acp_client_fs_rename_file`. Raw client capability blobs are not stored in
prompt metadata.

When both the ACP session metadata and tool options show filesystem support,
Lemon's model-facing `read`, `write`, `edit`, and `patch` tools route text file
operations through the ACP client instead of the local filesystem. The bridge
uses the run bus to emit correlated `fs/read_text_file` and
`fs/write_text_file`, `fs/delete_file`, and `fs/rename_file` requests and waits
for the stdio ACP response. `patch` supports add, update, delete, and move-only
operations through ACP when the matching client filesystem capabilities are
available. Update+move patches that change content use read/write/delete because
the target content is rewritten before the old path is removed.

HTTP `/acp` remains a single request/response JSON-RPC endpoint. Use stdio or a
future streaming transport when clients need live ACP update notifications.

## Authentication

Set `:acp_api_token` in `:lemon_control_plane` config or
`LEMON_ACP_API_TOKEN` in the environment to require authentication on `/acp`.
Authenticated clients can send either:

```text
Authorization: Bearer <token>
```

or:

```text
x-api-key: <token>
```

The stdio runner does not perform HTTP header auth. Use it only in contexts
where the spawned local process boundary is already trusted, or wrap it with the
client/editor's own launch policy.

## Stdio Runner

ACP's TypeScript SDK documents newline-delimited JSON as the common stdio stream
format. Lemon's stdio preview uses the same line-oriented shape:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"1"}}' \
  | mix run --no-start scripts/lemon_acp_stdio.exs
```

Each non-empty input line must be a JSON-RPC request or notification. Each
response is emitted as one JSON line. Waiting prompt calls can also emit
intermediate `session/update` notification lines and agent-to-client request
lines before the final response. Clients answer those request lines by sending a
normal JSON-RPC response with the same id. Empty input lines are ignored, parse
errors return JSON-RPC `-32700`, and notifications with no `id` do not emit a
response. The `--no-start` form is useful for protocol-shape smoke tests that do
not submit runs. Spawned clients that need `session/prompt` to reach the router
must run the script in a Lemon runtime where the router is started.

## Boundaries

The preview session store uses Lemon's shared store with an ETS read cache. It
is suitable for early editor/client integration proof, but it is not a full
editor workspace/session index.
Stable ACP support still needs:

- real editor UI compatibility proof against a deployed ACP editor
- raw media/artifact support before advertising image, audio, or embedded
  resource prompt capabilities
- ACP delete/rename compatibility proof against a real editor client

## Proof

Focused tests cover capability negotiation, safe client filesystem capability
capture on sessions and prompt metadata, session creation, router-backed prompt
submission, queued prompt submission, unsupported media rejection, session
list/resume/cancel/close, HTTP bearer-token authentication, NDJSON stdio
message parsing, store-backed session recovery after ETS cache loss, stdio
`session/update` notification projection from Lemon run bus events, and stdio
client request callbacks for `session/request_permission`,
`fs/read_text_file`, `fs/write_text_file`, `fs/delete_file`, and
`fs/rename_file` with redacted result summaries, plus the approval-bus bridge
from `LemonCore.ExecApprovals.request/1` to ACP `session/request_permission`:

```bash
mix test apps/lemon_control_plane/test/lemon_control_plane/acp_test.exs --seed 1
```

The model-facing ACP filesystem bridge is covered by the focused coding-agent
tool lane. It proves `read` line-window routing, `write` remote-only writes,
`edit` read/modify/write flow, `patch` add/update/delete/move routing,
capability-based delete/move rejection, and the ACP control-plane reply
correlation path:

```bash
MIX_ENV=test mix test apps/coding_agent/test/coding_agent/tools/acp_file_bridge_test.exs \
  apps/coding_agent/test/coding_agent/tools/read_test.exs \
  apps/lemon_gateway/test/cli_adapter_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/acp_test.exs --seed 1
```

The combined control-plane adapter lane also reruns the OpenAI-compatible HTTP
adapter tests:

```bash
mix test apps/lemon_control_plane/test/lemon_control_plane/acp_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/http/router_test.exs --seed 1
```

The stdio bridge has a focused deterministic smoke that exercises the same
NDJSON handler used by spawned editor-style clients. It verifies
`initialize`, `session/new`, queued prompts, waiting prompt calls with
`session/update` notifications, list/resume/close lifecycle, parse-error
handling, and redacted proof output:

```bash
LEMON_CONTROL_PLANE_PORT=0 \
LEMON_WEB_PORT=0 \
LEMON_SIM_UI_PORT=0 \
LEMON_GATEWAY_HEALTH_PORT=0 \
LEMON_ROUTER_HEALTH_PORT=0 \
mix run scripts/live_acp_stdio_smoke.exs
```

The smoke writes `.lemon/proofs/acp-stdio-smoke-latest.json` plus a timestamped
archive proof. It passed locally on 2026-05-17 with `completed_count: 6` and
`failed_count: 0`.

There is also an external Node client proof that spawns the stdio bridge as a
child process and talks to it over newline-delimited JSON:

```bash
node scripts/live_acp_stdio_external_client.mjs
```

The external client runs with `LEMON_ACP_STDIO_FAKE_RUNTIME=1`, which keeps the
proof deterministic while still exercising a separate client process, child
stdio transport, ACP initialize/session lifecycle, safe client filesystem
capability capture across `initialize` and `session/new`, queued prompt,
waiting prompt with `session/update` notifications, `session/request_permission`,
`fs/read_text_file`, `fs/write_text_file`, `fs/delete_file`, `fs/rename_file`,
approval-bus permission bridging, unsupported-image rejection, parse-error
handling, and redacted proof output. It writes
`.lemon/proofs/acp-stdio-external-client-latest.json` plus a timestamped
archive proof. The latest ACP delete/rename refresh passed at
`2026-05-17T11:12:43.029Z` with
`completed_count: 9`, `failed_count: 0`, `update_count: 2`, and
`client_request_count: 6`.

The official ACP TypeScript SDK compatibility proof uses
`@zed-industries/agent-client-protocol@0.4.5` and its `ClientSideConnection`
against Lemon's stdio bridge:

```bash
node scripts/live_acp_official_sdk_client.mjs
```

The proof installs the SDK under ignored `tmp/acp-official-sdk-client/`, spawns
`scripts/lemon_acp_stdio.exs` with a deterministic fake runtime, and exercises
the official SDK path for `initialize`, `session/new`, queued prompt,
waited prompt `session/update` notifications, `session/load`, `session/cancel`,
unsupported-image rejection, spec-compatible `session/request_permission`,
`fs/read_text_file`, and `fs/write_text_file`. The official SDK does not expose
delete/rename filesystem callbacks in version `0.4.5`, so Lemon keeps
delete/rename covered by the separate external Node proof above. The latest
official SDK proof passed at `2026-05-17T11:12:42.429Z` with
`completed_count: 8`, `failed_count: 0`, `update_count: 2`, and
`client_request_count: 4`.

`proofs.status`, support bundles, and `mix lemon.doctor --verbose` consume the
three ACP proof artifacts as `acp_stdio_*`, `acp_stdio_external_*`, and
`acp_official_sdk_*` checks. The doctor check is `acp.preview`; rerun the three
smoke/client commands above if it warns or skips.
