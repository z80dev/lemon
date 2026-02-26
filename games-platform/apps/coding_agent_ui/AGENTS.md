# CodingAgentUi

UI adapters and RPC interfaces for the `coding_agent` core. This app provides UI implementations that communicate with external clients via JSON protocols, while keeping `coding_agent` UI-agnostic.

## Purpose and Responsibilities

This app hosts three UI implementations of the `CodingAgent.UI` behaviour:

1. **CodingAgent.UI.RPC** - Full JSON-RPC interface over stdin/stdout for TUI/web clients
2. **CodingAgent.UI.DebugRPC** - Debug-specific RPC adapter for `debug_agent_rpc.exs` integration
3. **CodingAgent.UI.Headless** - No-op implementation for headless/CI environments

The OTP application (`CodingAgentUi.Application`) starts with no children - UI instances are started on-demand by clients.

**Dependencies:**
- `coding_agent` (umbrella) - provides the `CodingAgent.UI` behaviour
- `jason` - JSON encoding/decoding
- `uuid` - Request ID generation

## RPC Interface Usage

`CodingAgent.UI.RPC` is a GenServer that implements a JSON-RPC protocol over stdin/stdout. It spawns a reader Task internally to poll stdin line-by-line.

### Starting the RPC

```elixir
# Start with a registered name (required for module-level API calls)
{:ok, pid} = CodingAgent.UI.RPC.start_link(name: MyUI)

# Start with custom devices for testing
{:ok, pid} = CodingAgent.UI.RPC.start_link(
  input_device: my_input,
  output_device: my_output,
  timeout: 30_000
)
```

The `:name` option registers the process. Module-level functions like `notify/2`, `set_status/2`, etc. (those without an `opts` arg) default to `__MODULE__` as the server, so the process must be registered under `CodingAgent.UI.RPC` for them to work without a `server:` opt.

Interactive methods (`select/3`, `confirm/3`, `input/3`, `editor/3`) accept a `server:` keyword opt to target a specific pid or name. The `server:` and `timeout:` opts are stripped from params before being sent over the wire.

### Protocol

**Requests** (RPC → Client via stdout):
```json
{"id": "uuid", "method": "select", "params": {"title": "Choose", "options": [...], "opts": {}}}
{"id": "uuid", "method": "confirm", "params": {"title": "Confirm?", "message": "...", "opts": {}}}
{"id": "uuid", "method": "input", "params": {"title": "Enter", "placeholder": "...", "opts": {}}}
{"id": "uuid", "method": "editor", "params": {"title": "Edit", "prefill": "...", "opts": {}}}
```

The `options` array for `select` has the shape `[%{label: "...", value: "...", description: "..."}]`.

**Responses** (Client → RPC via stdin):
```json
{"id": "uuid", "result": "selected_value"}
{"id": "uuid", "error": "error_message"}
```

**Notifications** (RPC → Client, no response expected):
```json
{"method": "notify", "params": {"message": "Hello", "type": "info"}}
{"method": "set_status", "params": {"key": "mode", "text": "Running"}}
{"method": "set_widget", "params": {"key": "files", "content": ["a.ex"], "opts": {}}}
{"method": "set_working_message", "params": {"message": "Processing..."}}
{"method": "set_title", "params": {"title": "My App"}}
{"method": "set_editor_text", "params": {"text": "code here"}}
```

### Configuration Options

- `:timeout` - Response timeout in milliseconds (default: 30_000)
- `:input_device` - IO device for reading input (default: :stdio)
- `:output_device` - IO device for writing output (default: :stdio)

### Reader Task Lifecycle

The RPC server starts a `Task.async` reader on init that loops over `IO.gets/2`. On error it sends `{:reader_error, reason}` and the server restarts it. On EOF it sends `{:reader_closed}` and the server fails all pending requests with `{:error, :connection_closed}` and sets `input_closed: true`. Subsequent requests while closed return `{:error, :connection_closed}` immediately. The reader is killed on `terminate/2`.

### editor_text Tracking

`set_editor_text/1` sends the notification over the wire AND caches the value in GenServer state. `get_editor_text/0` returns the cached value without a round-trip.

## Debug RPC Capabilities

`CodingAgent.UI.DebugRPC` is designed for integration with `debug_agent_rpc.exs`. It shares the same JSON line protocol but uses typed messages to coexist with debug protocol messages. Unlike RPC, it has no stdin reader - responses are routed externally via `handle_response/2`.

**Default registered name**: `CodingAgent.UI.DebugRPC` (unlike RPC which has no default).

### Key Differences from RPC

- Uses typed messages (`ui_request`, `ui_response`, `ui_notify`, etc.)
- No input reader Task - responses are pushed in via `handle_response/2`
- No `input_closed` state - connections cannot be "closed" from this adapter's perspective
- `notify/3` has a 3-arity form accepting opts (including `server:`)
- `cancel_timeout/2` flushes any already-delivered timeout message from mailbox after cancelling
- Error takes precedence over result in `parse_response/1` (if both fields present, error wins)
- `{result: nil, error: nil}` is treated as `{:ok, nil}` (user cancellation)

### Protocol

**Requests** (DebugRPC → Client):
```json
{"type": "ui_request", "id": "uuid", "method": "select", "params": {...}}
```

**Responses** (Client → DebugRPC via handle_response/2):
```json
{"type": "ui_response", "id": "uuid", "result": "...", "error": null}
```

`handle_response/2` is a cast (async), so it returns immediately.

**Notifications** (DebugRPC → Client):
```json
{"type": "ui_notify", "params": {"message": "...", "notify_type": "info"}}
{"type": "ui_status", "params": {"key": "...", "text": "..."}}
{"type": "ui_widget", "params": {"key": "...", "content": "...", "opts": {}}}
{"type": "ui_working", "params": {"message": "..."}}
{"type": "ui_set_title", "params": {"title": "..."}}
{"type": "ui_set_editor_text", "params": {"text": "..."}}
```

Note: `notify_type` in `ui_notify` (not `type`) to avoid collision with the top-level `"type"` field.

### opts Handling in set_widget/3

`set_widget/3` accepts extra keyword opts (e.g., `position: :above`). The `:server` key is stripped and remaining opts are normalized from a keyword list to a map before being sent on the wire.

```elixir
DebugRPC.set_widget("files", ["a.txt"], server: rpc, position: :above)
# Sends: {"type": "ui_widget", "params": {"key": "files", "content": [...], "opts": {"position": "above"}}}
```

### Usage in Debug Scripts

```elixir
# Start the adapter
{:ok, ui_pid} = CodingAgent.UI.DebugRPC.start_link(name: CodingAgent.UI.DebugRPC)

# Route incoming ui_response messages from stdin
CodingAgent.UI.DebugRPC.handle_response(ui_pid, %{
  "type" => "ui_response",
  "id" => request_id,
  "result" => result,
  "error" => nil
})
```

## Headless Mode

`CodingAgent.UI.Headless` is a plain module (not a GenServer) with no-op implementations for non-interactive environments.

### Behavior

| Method | Return Value | Side Effect |
|--------|--------------|-------------|
| `select/3` | `{:ok, nil}` | None |
| `confirm/3` | `{:ok, false}` | None |
| `input/3` | `{:ok, nil}` | None |
| `editor/3` | `{:ok, nil}` | None |
| `notify/2` | `:ok` | Logs via Logger (`:info`/`:warning`/`:error` map directly; `:success` logs as info with `[SUCCESS]` prefix) |
| `set_status/2` | `:ok` | None |
| `set_widget/3` | `:ok` | None |
| `set_working_message/1` | `:ok` | Logs `[WORKING] message` at debug level (nil is a silent no-op) |
| `set_title/1` | `:ok` | None |
| `set_editor_text/1` | `:ok` | None |
| `get_editor_text/0` | `""` | None |
| `has_ui?/0` | `false` | None |

Use this when running in CI, automated tests, or any non-interactive context.

## Integration with coding_agent

The `coding_agent` app defines the `CodingAgent.UI` behaviour. This app provides the implementations.

### Creating a UI Context

```elixir
# Interactive mode with RPC
ui_context = CodingAgent.UI.Context.new(CodingAgent.UI.RPC)

# Debug mode with DebugRPC
ui_context = CodingAgent.UI.Context.new(CodingAgent.UI.DebugRPC)

# Headless mode
ui_context = CodingAgent.UI.Context.new(CodingAgent.UI.Headless)
```

### Runtime UI Detection

```elixir
if CodingAgent.UI.has_ui?() do
  # Show interactive dialog
else
  # Use defaults or skip
end
```

## Common Tasks and Examples

### Testing with Mock IO

See `test/coding_agent/ui/rpc_test.exs` for the full `MockIO` implementation. Key functions:

```elixir
{:ok, input} = MockIO.start_link()
{:ok, output} = MockIO.start_link()
{:ok, rpc} = CodingAgent.UI.RPC.start_link(
  input_device: input,
  output_device: output,
  timeout: 1_000
)

# Simulate client response (queued, delivered when RPC reads)
MockIO.put_input(input, ~s({"id": "...", "result": "value"}))

# Read output lines written by RPC
lines = MockIO.get_output(output)         # all lines (oldest first)
json  = MockIO.get_last_json(output)      # decoded last line
MockIO.close(input)                        # simulate EOF / disconnect
```

For DebugRPC tests, `MockOutput` (output-only) is used - it has `get_output/1`, `get_last_json/1`, `get_all_json/1`, and `clear/1`.

### Handling Concurrent Requests

Both RPC and DebugRPC handle concurrent requests via UUID-keyed pending_requests map:

```elixir
task1 = Task.async(fn -> CodingAgent.UI.RPC.select("First", options, server: rpc) end)
task2 = Task.async(fn -> CodingAgent.UI.RPC.confirm("Second", "Sure?", server: rpc) end)
results = Task.await_many([task1, task2])
```

Responses can arrive out of order - each is matched by ID.

### Timeout Handling

The `timeout` opt on individual calls sets the `GenServer.call` timeout (default: `state.timeout + 5000`). The `state.timeout` value controls the internal `Process.send_after` timer that sends `{:timeout, request_id}` to the server. When the timer fires, the server replies `{:error, :timeout}` and removes the pending request.

```elixir
# Per-call server-side timeout (controls internal timer)
{:ok, rpc} = CodingAgent.UI.RPC.start_link(timeout: 60_000)

# Per-call GenServer.call timeout via opts (should exceed server timeout)
result = CodingAgent.UI.RPC.select("Choose", options, server: rpc, timeout: 65_000)
```

### Error Handling

```elixir
case CodingAgent.UI.RPC.select("Choose", options, server: rpc) do
  {:ok, nil}                        -> :cancelled
  {:ok, value}                      -> value
  {:error, :timeout}                -> :timed_out
  {:error, :connection_closed}      -> :connection_lost
  {:error, :server_shutdown}        -> :server_died
  {:error, :invalid_response}       -> :bad_response
  {:error, message} when is_binary(message) -> {:user_error, message}
end
```

## Testing Guidance

### Running Tests

```bash
# Run all coding_agent_ui tests
mix test apps/coding_agent_ui

# Run specific test file
mix test apps/coding_agent_ui/test/coding_agent/ui/rpc_test.exs
mix test apps/coding_agent_ui/test/coding_agent/ui/debug_rpc_test.exs
mix test apps/coding_agent_ui/test/coding_agent/ui/headless_test.exs
```

### Test Structure

- **rpc_test.exs** (`async: true`) - Tests for `CodingAgent.UI.RPC` with `MockIO`; uses `wait_for_output/2` and `wait_for_output_count/3` polling helpers
- **debug_rpc_test.exs** (`async: true`) - Tests for `CodingAgent.UI.DebugRPC` with `MockOutput`; each test gets a uniquely named server via `:erlang.unique_integer/1`
- **headless_test.exs** (`async: false`) - Tests for `CodingAgent.UI.Headless`; must be synchronous due to `capture_log/1` being global

### Key Testing Patterns

1. **Mock IO Devices**: GenServer processes that implement the Erlang IO protocol (`{:io_request, from, reply_as, request}` / `{:io_reply, reply_as, data}`). For RPC: separate `input` and `output` devices. For DebugRPC: output-only `MockOutput`.

2. **Async responses**: RPC tests respond to requests in a `spawn`'d process that waits for the request to appear in output, then calls `MockIO.put_input/2`. DebugRPC tests call `DebugRPC.handle_response/2` directly.

3. **Unique server names**: DebugRPC tests use `:"debug_rpc_test_#{:erlang.unique_integer([:positive])}"` to prevent name collisions between async tests.

4. **Timeout Testing**: Tests use short timeouts (50-500ms). The RPC server's internal timeout and the GenServer.call timeout are separate - set both appropriately.

5. **Edge Cases Covered**:
   - Invalid/truncated/missing-id JSON responses (gracefully logged, request remains pending)
   - Connection closed mid-request (`{:error, :connection_closed}`)
   - Out-of-order responses (matched by UUID)
   - Duplicate response IDs (second is logged as warning and ignored)
   - Reader task restart after transient IO errors
   - Server shutdown with pending requests (`{:error, :server_shutdown}`)
   - Large payloads and many concurrent requests

### Adding New Tests

1. Add tests to the appropriate `*_test.exs` file
2. Use the existing `MockIO` or `MockOutput` helpers
3. Test both success and error paths
4. For RPC tests, always send responses asynchronously (use `spawn` or `Task.async`) since the `select/confirm/input/editor` calls block
5. Use `wait_for_output/2` instead of `Process.sleep` to avoid flakiness

### Debugging Test Failures

If tests are flaky:
- Use `wait_for_output/2` instead of `Process.sleep` before reading output
- Ensure proper cleanup in `on_exit` callbacks (stop RPC before closing MockIO)
- Check for mailbox leakage (unhandled messages) with `:sys.get_state/1`
- Verify `on_exit` guards with `Process.alive?/1` before stopping processes
