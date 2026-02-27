# CodingAgentUi

UI adapter implementations for the `coding_agent` core. This OTP application provides concrete implementations of the `CodingAgent.UI` behaviour, enabling the coding agent to communicate with external user interfaces through JSON-based protocols while keeping the core `coding_agent` app entirely UI-agnostic.

## Architecture

```
coding_agent (defines CodingAgent.UI behaviour + CodingAgent.UI.Context)
      ^
      |  (umbrella dependency)
      |
coding_agent_ui (provides implementations)
  |-- CodingAgent.UI.RPC         GenServer, full JSON-RPC over stdin/stdout
  |-- CodingAgent.UI.DebugRPC    GenServer, typed JSON protocol for debug scripts
  |-- CodingAgent.UI.Headless    Plain module, no-ops for non-interactive contexts
```

The OTP application (`CodingAgentUi.Application`) starts a bare supervisor with no children. UI adapter instances are started on-demand by the consuming code (e.g., a CLI entrypoint or debug script).

### Design Principles

- **Behaviour-driven**: All three adapters implement `CodingAgent.UI`, which defines callbacks for dialogs (`select`, `confirm`, `input`, `editor`), notifications (`notify`), status indicators (`set_status`, `set_widget`, `set_working_message`), layout (`set_title`), editor state (`set_editor_text`, `get_editor_text`), and a capability probe (`has_ui?`).
- **Protocol separation**: `RPC` uses bare JSON objects (`{"id": ..., "method": ...}`), while `DebugRPC` wraps messages in typed envelopes (`{"type": "ui_request", ...}`) so they can coexist with the debug agent protocol on the same stdio channel.
- **No global state**: Each adapter instance is independently configured with its own IO devices, timeouts, and pending-request tracking. Multiple instances can run concurrently.

## Module Inventory

### `CodingAgent.UI.RPC` (`lib/coding_agent/ui/rpc.ex`)

Full-featured JSON-RPC adapter that manages its own stdin/stdout communication. It is a GenServer that:

- Spawns an internal `Task.async` reader loop to poll stdin line-by-line via `IO.gets/2`.
- Sends JSON request objects to stdout for dialog methods (`select`, `confirm`, `input`, `editor`).
- Sends JSON notification objects for fire-and-forget methods (`notify`, `set_status`, `set_widget`, `set_working_message`, `set_title`, `set_editor_text`).
- Tracks pending requests in a UUID-keyed map with per-request timeout timers.
- Handles connection lifecycle: reader restart on transient IO errors, graceful close on EOF (all pending requests fail with `{:error, :connection_closed}`).

**Start options:**
| Option | Default | Description |
|---|---|---|
| `:name` | none | GenServer registered name |
| `:timeout` | 30,000 ms | Internal per-request timeout |
| `:input_device` | `:stdio` | IO device for reading responses |
| `:output_device` | `:stdio` | IO device for writing requests/notifications |

**Protocol -- Requests (stdout):**
```json
{"id": "uuid", "method": "select", "params": {"title": "...", "options": [...], "opts": {}}}
{"id": "uuid", "method": "confirm", "params": {"title": "...", "message": "...", "opts": {}}}
{"id": "uuid", "method": "input", "params": {"title": "...", "placeholder": "...", "opts": {}}}
{"id": "uuid", "method": "editor", "params": {"title": "...", "prefill": "...", "opts": {}}}
```

**Protocol -- Responses (stdin):**
```json
{"id": "uuid", "result": "selected_value"}
{"id": "uuid", "error": "error message"}
```

**Protocol -- Notifications (stdout, no response):**
```json
{"method": "notify", "params": {"message": "...", "type": "info"}}
{"method": "set_status", "params": {"key": "...", "text": "..."}}
{"method": "set_widget", "params": {"key": "...", "content": [...], "opts": {}}}
{"method": "set_working_message", "params": {"message": "..."}}
{"method": "set_title", "params": {"title": "..."}}
{"method": "set_editor_text", "params": {"text": "..."}}
```

### `CodingAgent.UI.DebugRPC` (`lib/coding_agent/ui/debug_rpc.ex`)

Debug-specific RPC adapter designed for integration with `debug_agent_rpc.exs`. Unlike `RPC`, this adapter does not manage its own stdin reader. Instead, responses are pushed into it via the `handle_response/2` cast. This allows it to share the same stdio channel with the debug protocol.

**Key differences from RPC:**
- Uses typed message envelopes: `ui_request`, `ui_response`, `ui_notify`, `ui_status`, `ui_widget`, `ui_working`, `ui_set_title`, `ui_set_editor_text`.
- No internal reader task -- the debug script routes `ui_response` messages to the adapter.
- No `input_closed` state.
- Default registered name is `CodingAgent.UI.DebugRPC` (RPC has no default).
- Error field takes precedence over result in response parsing (if both are present, error wins).
- `{result: nil, error: nil}` is treated as `{:ok, nil}` (user cancellation).
- `notify/3` has a 3-arity form accepting a keyword list with `:server` option.
- `cancel_timeout/2` flushes any already-delivered timeout message from the process mailbox.

**Protocol -- Requests (stdout):**
```json
{"type": "ui_request", "id": "uuid", "method": "select", "params": {"title": "...", "options": [...]}}
```

**Protocol -- Responses (via `handle_response/2`):**
```json
{"type": "ui_response", "id": "uuid", "result": "...", "error": null}
```

**Protocol -- Notifications (stdout):**
```json
{"type": "ui_notify", "params": {"message": "...", "notify_type": "info"}}
{"type": "ui_status", "params": {"key": "...", "text": "..."}}
{"type": "ui_widget", "params": {"key": "...", "content": "...", "opts": {}}}
{"type": "ui_working", "params": {"message": "..."}}
{"type": "ui_set_title", "params": {"title": "..."}}
{"type": "ui_set_editor_text", "params": {"text": "..."}}
```

Note: The notification type field is `notify_type` (not `type`) to avoid collision with the envelope's `type` field.

### `CodingAgent.UI.Headless` (`lib/coding_agent/ui/headless.ex`)

A plain module (not a GenServer) providing no-op implementations for non-interactive environments such as CI pipelines, automated tests, and headless batch processing.

| Callback | Return Value | Side Effect |
|---|---|---|
| `select/3` | `{:ok, nil}` | None |
| `confirm/3` | `{:ok, false}` | None |
| `input/3` | `{:ok, nil}` | None |
| `editor/3` | `{:ok, nil}` | None |
| `notify/2` | `:ok` | Logs via Logger (`:info`/`:warning`/`:error` directly; `:success` logs at info with `[SUCCESS]` prefix) |
| `set_status/2` | `:ok` | None |
| `set_widget/3` | `:ok` | None |
| `set_working_message/1` | `:ok` | `nil` is a silent no-op; any other value logs at debug level with `[WORKING]` prefix |
| `set_title/1` | `:ok` | None |
| `set_editor_text/1` | `:ok` | None |
| `get_editor_text/0` | `""` | None |
| `has_ui?/0` | `false` | None |

### `CodingAgentUi.Application` (`lib/coding_agent_ui/application.ex`)

Standard OTP application module. Starts a `:one_for_one` supervisor with no children. UI adapter processes are started on-demand outside the supervision tree.

## Dependencies

| Dependency | Source | Purpose |
|---|---|---|
| `coding_agent` | Umbrella | Provides the `CodingAgent.UI` behaviour and `CodingAgent.UI.Context` |
| `jason` | Hex (~> 1.4) | JSON encoding/decoding for the RPC protocols |
| `uuid` | Hex (~> 1.1) | UUID v4 generation for request correlation IDs |

## Usage Examples

### Starting an Interactive RPC Session

```elixir
# Start with a registered name for module-level API calls
{:ok, _pid} = CodingAgent.UI.RPC.start_link(name: CodingAgent.UI.RPC)

# Create a UI context for the coding agent
ui_context = CodingAgent.UI.Context.new(CodingAgent.UI.RPC)

# Use through the context
{:ok, selection} = CodingAgent.UI.Context.select(ui_context, "Choose a model", [
  %{label: "Claude Sonnet", value: "sonnet", description: "Fast and capable"},
  %{label: "Claude Opus", value: "opus", description: "Most intelligent"}
])
```

### Starting a Debug Script Session

```elixir
{:ok, ui_pid} = CodingAgent.UI.DebugRPC.start_link(name: CodingAgent.UI.DebugRPC)
ui_context = CodingAgent.UI.Context.new(CodingAgent.UI.DebugRPC)

# In the debug script's stdin handler, route ui_response messages:
CodingAgent.UI.DebugRPC.handle_response(ui_pid, %{
  "id" => request_id,
  "result" => user_selection,
  "error" => nil
})
```

### Headless / CI Mode

```elixir
ui_context = CodingAgent.UI.Context.new(CodingAgent.UI.Headless)

# All dialog methods return safe defaults
{:ok, nil} = CodingAgent.UI.Context.select(ui_context, "Choose", options)
{:ok, false} = CodingAgent.UI.Context.confirm(ui_context, "Sure?", "Dangerous operation")
```

### Runtime UI Detection

```elixir
if CodingAgent.UI.Context.has_ui?(ui_context) do
  {:ok, choice} = CodingAgent.UI.Context.select(ui_context, "Pick one", options)
  # use choice
else
  # fall back to default behavior
end
```

### Error Handling

```elixir
case CodingAgent.UI.RPC.select("Choose", options, server: rpc_pid) do
  {:ok, nil}                              -> :user_cancelled
  {:ok, value}                            -> {:selected, value}
  {:error, :timeout}                      -> :request_timed_out
  {:error, :connection_closed}            -> :client_disconnected
  {:error, :server_shutdown}              -> :server_stopped
  {:error, :invalid_response}             -> :malformed_response
  {:error, msg} when is_binary(msg)       -> {:client_error, msg}
end
```

### Testing with Mock IO Devices

```elixir
# See test/coding_agent/ui/rpc_test.exs for full MockIO implementation
{:ok, input} = MockIO.start_link()
{:ok, output} = MockIO.start_link()

{:ok, rpc} = CodingAgent.UI.RPC.start_link(
  input_device: input,
  output_device: output,
  timeout: 1_000
)

# Queue a response before making the call
spawn(fn ->
  Process.sleep(50)
  lines = MockIO.get_output(output)
  request = Jason.decode!(List.last(lines))
  MockIO.put_input(input, Jason.encode!(%{"id" => request["id"], "result" => "a"}))
end)

{:ok, "a"} = CodingAgent.UI.RPC.select("Pick", options, server: rpc)
```

### Concurrent Requests

Both `RPC` and `DebugRPC` support concurrent requests. Each request is assigned a UUID and responses are matched by ID, so they can arrive out of order.

```elixir
task1 = Task.async(fn -> CodingAgent.UI.RPC.select("First", opts_a, server: rpc) end)
task2 = Task.async(fn -> CodingAgent.UI.RPC.confirm("Second", "Sure?", server: rpc) end)
[result1, result2] = Task.await_many([task1, task2])
```

### Timeout Configuration

```elixir
# Server-level timeout (controls internal Process.send_after timer)
{:ok, rpc} = CodingAgent.UI.RPC.start_link(timeout: 60_000)

# Per-call GenServer.call timeout via opts (should exceed server timeout)
result = CodingAgent.UI.RPC.select("Choose", options, server: rpc, timeout: 65_000)
```

## editor_text Tracking

Both `RPC` and `DebugRPC` track `editor_text` locally in GenServer state. When `set_editor_text/1` is called, the text is both sent over the wire as a notification and cached in state. `get_editor_text/0` returns the cached value without a round-trip to the client. The `Headless` adapter always returns `""`.

## Running Tests

```bash
# All tests in this app
mix test apps/coding_agent_ui

# Individual test files
mix test apps/coding_agent_ui/test/coding_agent/ui/rpc_test.exs
mix test apps/coding_agent_ui/test/coding_agent/ui/debug_rpc_test.exs
mix test apps/coding_agent_ui/test/coding_agent/ui/headless_test.exs
```
