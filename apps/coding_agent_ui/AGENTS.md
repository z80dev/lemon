# CodingAgentUi -- Agent Context

UI adapter implementations for `CodingAgent.UI` behaviour. Three adapters: `RPC` (full JSON-RPC over stdin/stdout), `DebugRPC` (typed JSON protocol for debug scripts), `Headless` (no-ops for CI/batch). The OTP app starts an empty supervisor; adapter instances are started on-demand.

## Key Files

| File | Purpose |
|---|---|
| `lib/coding_agent/ui/rpc.ex` | GenServer. Full JSON-RPC adapter with internal stdin reader Task. Manages pending requests, timeouts, connection lifecycle. |
| `lib/coding_agent/ui/debug_rpc.ex` | GenServer. Debug-script adapter. No stdin reader -- responses pushed via `handle_response/2`. Uses typed message envelopes (`ui_request`, `ui_response`, etc.). |
| `lib/coding_agent/ui/headless.ex` | Plain module (not GenServer). No-op returns for all dialogs, Logger output for `notify/2` and `set_working_message/1`. |
| `lib/coding_agent_ui/application.ex` | OTP Application. Empty supervisor, no children. |
| `test/coding_agent/ui/rpc_test.exs` | Tests for RPC with `MockIO` (implements Erlang IO protocol). Async. |
| `test/coding_agent/ui/debug_rpc_test.exs` | Tests for DebugRPC with `MockOutput` (output-only). Async. Each test gets unique server name. |
| `test/coding_agent/ui/headless_test.exs` | Tests for Headless. Synchronous (uses `capture_log`). |

## Behaviour Contract

All adapters implement `CodingAgent.UI` (defined in `apps/coding_agent/lib/coding_agent/ui.ex`). The callbacks:

**Dialog methods** (blocking, return `{:ok, value} | {:error, reason}`):
- `select/3` -- selection from options list
- `confirm/3` -- boolean confirmation
- `input/3` -- text entry
- `editor/3` -- multi-line text editor

**Notification methods** (fire-and-forget, return `:ok`):
- `notify/2` -- user notification with type
- `set_status/2` -- key-value status indicator
- `set_widget/3` -- keyed content widget
- `set_working_message/1` -- progress message
- `set_title/1` -- UI title

**Editor state**:
- `set_editor_text/1` -- set and broadcast editor content
- `get_editor_text/0` -- read cached editor content

**Capability**:
- `has_ui?/0` -- `true` for RPC/DebugRPC, `false` for Headless

Callers typically interact through `CodingAgent.UI.Context` (in `coding_agent` app), which wraps a module reference and delegates all calls.

## Dependencies

- `coding_agent` (umbrella) -- provides `CodingAgent.UI` behaviour and `CodingAgent.UI.Context`
- `jason` (~> 1.4) -- JSON codec
- `uuid` (~> 1.1) -- request ID generation

## Connections to Other Apps

- **coding_agent**: Defines the `CodingAgent.UI` behaviour that this app implements. Also defines `CodingAgent.UI.Context` which wraps any UI module for convenient delegation.
- **Consuming apps** (e.g., CLI entrypoints, debug scripts): Start an adapter instance and pass it as a `CodingAgent.UI.Context` to the coding agent session.

## Modification Patterns

### Adding a New UI Callback

1. Add the `@callback` to `apps/coding_agent/lib/coding_agent/ui.ex`.
2. Add a delegation function to `apps/coding_agent/lib/coding_agent/ui/context.ex`.
3. Implement in all three adapters:
   - `headless.ex` -- add a no-op that returns a sensible default.
   - `rpc.ex` -- add either a `GenServer.call` (dialog) or `GenServer.cast` (notification) handler. Dialog methods send a JSON request object and await a response keyed by UUID. Notification methods send a JSON notification object.
   - `debug_rpc.ex` -- same as RPC but wrap in typed envelope. For dialogs use `{:request, method, params}` call. For notifications use `{:signal, type, params}` cast.
4. Add tests in all three test files.

### Adding a New Adapter

1. Create a module in `lib/coding_agent/ui/` that declares `@behaviour CodingAgent.UI`.
2. Implement all callbacks from the behaviour.
3. If stateful, use GenServer and follow the patterns in `rpc.ex` or `debug_rpc.ex`.
4. Create a corresponding test file in `test/coding_agent/ui/`.

### Modifying the JSON Protocol

The RPC and DebugRPC protocols differ:

- **RPC**: Bare objects. Requests have `id`, `method`, `params`. Notifications have `method`, `params` (no `id`). Responses have `id` and either `result` or `error`.
- **DebugRPC**: Typed envelopes. All messages have a `type` field (`ui_request`, `ui_response`, `ui_notify`, `ui_status`, etc.). Requests also have `id`, `method`, `params`. Responses have `id`, `result`, `error`.

When modifying the protocol, update the `send_json/2` calls and corresponding `handle_info/handle_cast` handlers, then update any external clients that speak the protocol.

### Internal Options Handling

Dialog methods in both RPC and DebugRPC accept keyword `opts` that may include internal keys (`:server`, `:timeout`). The `clean_opts/1` function strips these before sending over the wire. `set_widget/3` in DebugRPC uses `extract_server/1` to separate `:server` from widget-specific opts.

When adding new internal-only keys, add them to the `Keyword.drop` list in `clean_opts/1`.

## Testing Guidance

### Running Tests

```bash
mix test apps/coding_agent_ui
mix test apps/coding_agent_ui/test/coding_agent/ui/rpc_test.exs
mix test apps/coding_agent_ui/test/coding_agent/ui/debug_rpc_test.exs
mix test apps/coding_agent_ui/test/coding_agent/ui/headless_test.exs
```

### Test Helpers

**`MockIO`** (in `rpc_test.exs`): A GenServer that implements the Erlang IO protocol. Supports both input (stdin simulation via `put_input/2`) and output (stdout capture via `get_output/1`, `get_last_json/1`). Also supports `close/1` to simulate EOF and `closed?/1` to check state.

**`MockOutput`** (in `debug_rpc_test.exs`): Output-only GenServer for capturing JSON written to the output device. Provides `get_output/1`, `get_last_json/1`, `get_all_json/1`, and `clear/1`.

### Key Testing Patterns

1. **Async response delivery**: For RPC tests, spawn a process that waits for the request to appear in output, then calls `MockIO.put_input/2`. For DebugRPC tests, call `DebugRPC.handle_response/2` directly after a short sleep.

2. **Polling for output**: Use `wait_for_output/2` (polls every 10ms with a timeout) instead of `Process.sleep` to avoid flakiness.

3. **Unique server names**: DebugRPC tests use `:"debug_rpc_test_#{:erlang.unique_integer([:positive])}"` for async isolation.

4. **Headless tests are synchronous**: `headless_test.exs` uses `async: false` because `capture_log/1` is a global operation.

5. **Cleanup**: Both RPC and DebugRPC tests use `on_exit` callbacks that guard with `Process.alive?/1` before stopping servers and mock devices.

### Writing New Tests

- **Dialog methods**: Start a request in `Task.async`, wait for it to appear in output, send a response, then `Task.await` for the result.
- **Notification methods**: Call the method, sleep briefly (or use `wait_for_output`), then inspect the mock output device.
- **Timeout tests**: Use short server-level timeouts (50-500ms) in test setup. The internal timer and `GenServer.call` timeout are separate -- set both appropriately.
- **Edge cases**: Test invalid JSON, missing IDs, duplicate response IDs, out-of-order responses, connection close mid-request, and server shutdown with pending requests.

### Common Failure Modes

- **Flaky timing**: Replace `Process.sleep` with `wait_for_output/2` or `wait_for_output_count/3`.
- **Name collisions**: Use unique atom names via `:erlang.unique_integer([:positive])`.
- **Mailbox leaks**: Unhandled messages can cause unexpected behavior. Use `:sys.get_state/1` to inspect GenServer state during debugging.
- **Cleanup order**: Stop the RPC server before closing the MockIO device to avoid reader task errors during shutdown.

## Architecture Notes

### Request Lifecycle (RPC)

1. Caller invokes `select/3` (or similar) which calls `GenServer.call`.
2. Server generates UUID, sends JSON request to output device, starts timeout timer, stores `{from, timer_ref}` in `pending_requests` map, returns `{:noreply, ...}`.
3. Reader task reads response line from input device, sends `{:response, json_line}` to server.
4. Server decodes JSON, looks up request ID in `pending_requests`, cancels timer, calls `GenServer.reply` with parsed result.
5. On timeout: server sends `{:error, :timeout}` reply and removes from pending map.
6. On EOF: server fails all pending requests with `{:error, :connection_closed}`, sets `input_closed: true`.

### Request Lifecycle (DebugRPC)

Same as RPC steps 1-2 and 4-5, but step 3 is replaced by external code calling `DebugRPC.handle_response/2` (a cast). There is no reader task and no EOF handling.

### editor_text Caching

Both RPC and DebugRPC cache the last `set_editor_text` value in GenServer state. The `get_editor_text/0` call reads from this cache (a synchronous `GenServer.call`), avoiding a round-trip to the client. Headless always returns `""`.

### opts Wire Format

Internal keyword opts (`:server`, `:timeout`) are stripped by `clean_opts/1` before serialization. Remaining opts are converted from a keyword list to a map for JSON encoding. In `set_widget/3` of DebugRPC, `extract_server/1` is used to separate `:server` from widget opts before cleaning.
