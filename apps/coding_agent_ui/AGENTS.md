# CodingAgentUi

UI adapters and RPC interfaces for the `coding_agent` core. This app provides UI implementations that communicate with external clients via JSON protocols, while keeping `coding_agent` UI-agnostic.

## Purpose and Responsibilities

This app hosts three UI implementations of the `CodingAgent.UI` behaviour:

1. **CodingAgent.UI.RPC** - Full JSON-RPC interface over stdin/stdout for TUI/web clients
2. **CodingAgent.UI.DebugRPC** - Debug-specific RPC adapter for `debug_agent_rpc.exs` integration
3. **CodingAgent.UI.Headless** - No-op implementation for headless/CI environments

The OTP application (`CodingAgentUi.Application`) currently starts with no children - UI instances are started on-demand by clients.

**Dependencies:**
- `coding_agent` (umbrella) - provides the `CodingAgent.UI` behaviour
- `jason` - JSON encoding/decoding
- `uuid` - Request ID generation

## RPC Interface Usage

`CodingAgent.UI.RPC` implements a JSON-RPC protocol over stdin/stdout for external UI clients.

### Starting the RPC

```elixir
# Start with default settings (uses :stdio)
{:ok, pid} = CodingAgent.UI.RPC.start_link(name: MyUI)

# Start with custom devices for testing
{:ok, pid} = CodingAgent.UI.RPC.start_link(
  input_device: my_input,
  output_device: my_output,
  timeout: 30_000
)
```

### Protocol

**Requests** (RPC → Client via stdout):
```json
{"id": "uuid", "method": "select", "params": {"title": "Choose", "options": [...]}}
{"id": "uuid", "method": "confirm", "params": {"title": "Confirm?", "message": "..."}}
{"id": "uuid", "method": "input", "params": {"title": "Enter", "placeholder": "..."}}
{"id": "uuid", "method": "editor", "params": {"title": "Edit", "prefill": "..."}}
```

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

## Debug RPC Capabilities

`CodingAgent.UI.DebugRPC` is designed for integration with `debug_agent_rpc.exs`. It shares the same JSON line protocol but with different message types to coexist with debug protocol messages.

### Key Differences from RPC

- Uses typed messages (`ui_request`, `ui_response`, `ui_notify`, etc.)
- Does not manage its own input reader - responses are routed via `handle_response/2`
- Designed to be embedded within a larger debug protocol

### Protocol

**Requests** (DebugRPC → Client):
```json
{"type": "ui_request", "id": "uuid", "method": "select", "params": {...}}
```

**Responses** (Client → DebugRPC via handle_response):
```json
{"type": "ui_response", "id": "uuid", "result": "...", "error": null}
```

**Notifications** (DebugRPC → Client):
```json
{"type": "ui_notify", "params": {"message": "...", "notify_type": "info"}}
{"type": "ui_status", "params": {"key": "...", "text": "..."}}
{"type": "ui_widget", "params": {"key": "...", "content": "...", "opts": {}}}
{"type": "ui_working", "params": {"message": "..."}}
{"type": "ui_set_title", "params": {"title": "..."}}
{"type": "ui_set_editor_text", "params": {"text": "..."}}
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

`CodingAgent.UI.Headless` is a no-op implementation for non-interactive environments.

### Behavior

| Method | Return Value | Side Effect |
|--------|--------------|-------------|
| `select/3` | `{:ok, nil}` | None |
| `confirm/3` | `{:ok, false}` | None |
| `input/3` | `{:ok, nil}` | None |
| `editor/3` | `{:ok, nil}` | None |
| `notify/2` | `:ok` | Logs to console |
| `set_status/2` | `:ok` | None |
| `set_widget/3` | `:ok` | None |
| `set_working_message/1` | `:ok` | Logs debug message |
| `set_title/1` | `:ok` | None |
| `set_editor_text/1` | `:ok` | None |
| `get_editor_text/0` | `""` | None |
| `has_ui?/0` | `false` | None |

Use this when running in CI, automated tests, or any non-interactive context where UI interaction is not possible.

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

### Passing UI to CodingAgent

```elixir
# When starting a coding agent session
{:ok, session} = CodingAgent.start_link(
  ui: ui_context,
  # ... other options
)
```

### Runtime UI Detection

Use `has_ui?/0` to check if the UI is interactive:

```elixir
if CodingAgent.UI.has_ui?() do
  # Show interactive dialog
else
  # Use defaults or skip
end
```

## Common Tasks and Examples

### Testing with Mock IO

See `test/coding_agent/ui/rpc_test.exs` for a complete `MockIO` implementation:

```elixir
defmodule MockIO do
  use GenServer
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end
  
  def put_input(device, line) do
    GenServer.call(device, {:put_input, line})
  end
  
  def get_output(device) do
    GenServer.call(device, :get_output)
  end
  
  # ... implement IO protocol callbacks
end

# Usage in test
{:ok, input} = MockIO.start_link()
{:ok, output} = MockIO.start_link()
{:ok, rpc} = CodingAgent.UI.RPC.start_link(
  input_device: input,
  output_device: output
)

# Simulate client response
MockIO.put_input(input, ~s({"id": "...", "result": "value"}))

# Call UI method
{:ok, result} = CodingAgent.UI.RPC.select("Choose", options, server: rpc)
```

### Handling Concurrent Requests

Both RPC and DebugRPC handle concurrent requests with unique UUIDs:

```elixir
# These can be called concurrently - each gets its own request ID
task1 = Task.async(fn -> CodingAgent.UI.RPC.select("First", options) end)
task2 = Task.async(fn -> CodingAgent.UI.RPC.confirm("Second", "Sure?") end)

results = Task.await_many([task1, task2])
```

### Timeout Handling

```elixir
# Per-call timeout override
result = CodingAgent.UI.RPC.select(
  "Choose",
  options,
  timeout: 60_000  # 60 seconds
)

# Handle timeout error
case result do
  {:ok, value} -> value
  {:error, :timeout} -> :timed_out
  {:error, reason} -> raise "UI error: #{reason}"
end
```

### Error Handling

```elixir
case CodingAgent.UI.RPC.select("Choose", options) do
  {:ok, nil} -> :cancelled
  {:ok, value} -> value
  {:error, :timeout} -> :timed_out
  {:error, :connection_closed} -> :connection_lost
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

- **rpc_test.exs** - Tests for `CodingAgent.UI.RPC` with MockIO
- **debug_rpc_test.exs** - Tests for `CodingAgent.UI.DebugRPC` with MockOutput
- **headless_test.exs** - Tests for `CodingAgent.UI.Headless` (async: false due to capture_log)

### Key Testing Patterns

1. **Mock IO Devices**: Both RPC and DebugRPC tests use GenServer-based mock IO devices that implement the Erlang IO protocol.

2. **Async Testing**: RPC tests simulate concurrent client responses using `Task.async`.

3. **Timeout Testing**: Tests use very short timeouts (50-500ms) to avoid slow tests.

4. **Edge Cases Covered**:
   - Invalid JSON responses
   - Connection closed scenarios
   - Out-of-order responses
   - Duplicate response IDs
   - Concurrent request handling

### Adding New Tests

When adding features:

1. Add tests to the appropriate `*_test.exs` file
2. Use the existing `MockIO` or `MockOutput` helpers
3. Test both success and error paths
4. For RPC tests, remember to send responses asynchronously
5. Use `wait_for_output/2` helpers to avoid race conditions

### Debugging Test Failures

If tests are flaky:
- Check timing - increase `Process.sleep` durations in tests
- Ensure proper cleanup in `on_exit` callbacks
- Verify mock devices are stopped after use
- Check for mailbox leakage (unhandled messages)
