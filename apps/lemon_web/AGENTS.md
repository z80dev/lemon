# lemon_web AGENTS.md

Phoenix web interface for Lemon with LiveView.

## Purpose and Responsibilities

- **Web UI**: Main dashboard for interacting with Lemon agents
- **LiveView Sessions**: Real-time chat interface with streaming updates
- **File Uploads**: Multi-file uploads (up to 5 files, 20MB each) with progress tracking
- **Message Display**: User messages, assistant responses, system notifications, tool calls
- **Tool Call Visualization**: Collapsible components showing engine actions and results
- **Authentication**: Optional access token protection via Bearer header, query param, or session

## Phoenix Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  Endpoint (LemonWeb.Endpoint)                                 │
│  ├── Socket "/live" → Phoenix.LiveView.Socket                 │
│  ├── Static assets                                            │
│  └── Router (LemonWeb.Router)                                 │
│       └── Pipeline :browser → RequireAccessToken              │
└─────────────────────────────────────────────────────────────┘
```

### OTP Application Structure

- `LemonWeb.Application` - Supervisor with `Telemetry` and `Endpoint`
- `LemonWeb.Endpoint` - HTTP/WebSocket endpoint (uses Bandit)
- `LemonWeb.Router` - Routes: `/` (index), `/sessions/:session_key` (show)
- `LemonWeb.Telemetry` - Phoenix telemetry metrics

## LiveView Structure

### Main LiveView

**`LemonWeb.SessionLive`** - Single LiveView handling both index and show actions:

```elixir
# Routes
live "/", SessionLive, :index        # Auto-generates isolated session
live "/sessions/:session_key", SessionLive, :show  # Specific session
```

**Key assigns:**
- `:session_key` - Current session identifier
- `:agent_id` - Agent handling the session (default: "default")
- `:prompt` - Current input value
- `:messages` - List of message maps (max 250)
- `:last_run_id` - Track current run for delta aggregation
- `:submit_error` - Validation/error message

**PubSub integration:**
- Subscribes to `LemonCore.Bus.session_topic(session_key)` on mount
- Receives events: `:run_started`, `:delta`, `:engine_action`, `:run_completed`

### Message Structure

```elixir
%{
  id: String.t(),        # Unique message ID
  kind: :user | :assistant | :tool_call | :system,
  content: String.t(),   # Display content
  run_id: String.t(),    # For assistant messages, links to run
  pending: boolean(),    # Streaming in progress
  ts_ms: integer(),      # Timestamp
  event: map()           # For tool_call: full engine action event
}
```

### Components

**Function Components (Phoenix.Component):**

| Component | Path | Purpose |
|-----------|------|---------|
| `FileUploadComponent` | `live/components/file_upload_component.ex` | Drag-drop file upload UI |
| `MessageComponent` | `live/components/message_component.ex` | Message bubble rendering |
| `ToolCallComponent` | `live/components/tool_call_component.ex` | Collapsible tool call display |
| `CoreComponents` | `components/core_components.ex` | Shared: `<.button>`, `<.input>`, `<.flash_group>` |
| `Layouts` | `components/layouts.ex` | Root and app layouts |

**Usage pattern:**
```elixir
# In SessionLive.render/1
<MessageComponent.message message={message} />
<FileUploadComponent.file_upload upload={@uploads.files} />
```

## Authentication Flow

**`LemonWeb.Plugs.RequireAccessToken`** - Pipeline plug:

1. If no `:access_token` configured → allow all
2. Token sources (checked in order):
   - `Authorization: Bearer <token>` header
   - Query param `?token=<token>`
   - Session marker (`:lemon_web_auth`)
3. On valid token → set session marker
4. On invalid/missing → 401 Unauthorized

**Configuration:**
```elixir
# config/runtime.exs or config/config.exs
config :lemon_web, :access_token, System.get_env("LEMON_WEB_ACCESS_TOKEN")
```

## File Uploads

**Configured in SessionLive.mount/3:**
```elixir
allow_upload(:files,
  accept: :any,
  max_entries: 5,
  max_file_size: 20_000_000,  # 20MB
  auto_upload: true
)
```

**Upload flow:**
1. Files auto-upload via `live_file_input`
2. `FileUploadComponent` shows progress bars
3. On submit, `persist_uploads/1` consumes entries:
   - Files saved to `Application.get_env(:lemon_web, :uploads_dir)` or system temp
   - Naming: `{timestamp}-{unique_id}-{sanitized_filename}`
   - Returns list of upload metadata maps

**Events:**
- `phx-change="validate"` - Updates prompt value
- `phx-submit="submit"` - Validates and submits to router
- `phx-click="cancel-upload"` - Cancels in-progress upload

## Adding New LiveViews or Components

### New LiveView

```elixir
defmodule LemonWeb.Live.MyNewLive do
  use LemonWeb, :live_view
  
  @impl true
  def mount(params, _session, socket) do
    {:ok, socket}
  end
  
  @impl true
  def handle_event("action", params, socket) do
    {:noreply, socket}
  end
  
  @impl true
  def render(assigns) do
    ~H"""
    <div>Content</div>
    """
  end
end
```

**Add to router:**
```elixir
live "/new-path", MyNewLive, :index
```

### New Function Component

```elixir
defmodule LemonWeb.Live.Components.MyComponent do
  use Phoenix.Component
  
  attr :data, :map, required: true
  
  def my_component(assigns) do
    ~H"""
    <div>{@data.value}</div>
    """
  end
end
```

**File naming:** `snake_case.ex` → module `PascalCase`

## Common Tasks and Examples

### Subscribe to Bus Events

```elixir
alias LemonCore.Bus

if connected?(socket) do
  Bus.subscribe(Bus.session_topic(session_key))
end
```

### Submit to Router

```elixir
LemonRouter.submit(%{
  origin: :control_plane,
  session_key: socket.assigns.session_key,
  agent_id: socket.assigns.agent_id,
  prompt: prompt,
  meta: %{source: :lemon_web, uploads: uploads}
})
```

### Handle Bus Events

```elixir
def handle_info(%LemonCore.Event{type: :delta, payload: payload}, socket) do
  text = payload[:text] || ""
  # Append to streaming message
  {:noreply, socket}
end
```

### Add Core Component

Add to `LemonWeb.CoreComponents` using `Phoenix.Component` patterns:
```elixir
attr :rest, :global
slot :inner_block

def my_button(assigns) do
  ~H"""
  <button {@rest}>{render_slot(@inner_block)}</button>
  """
end
```

## Testing Guidance

**Test location:** `apps/lemon_web/test/`

**Basic patterns:**

```elixir
defmodule LemonWeb.Live.SessionLiveTest do
  use ExUnit.Case
  import Phoenix.LiveViewTest
  
  test "mounts with session key", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert view |> element("h1") |> render() =~ "Session Console"
  end
end
```

**Run tests:**
```bash
mix test apps/lemon_web
```

**Key testing considerations:**
- LiveView tests need `Phoenix.LiveViewTest` imported
- PubSub subscriptions require `connected?/1` check in tests
- File upload testing uses `file_input/4` and `render_upload/3`

## Dependencies

**Umbrella:** `lemon_core`, `lemon_router`

**External:**
- `phoenix` ~> 1.7.14
- `phoenix_live_view` ~> 1.0
- `phoenix_html` ~> 4.1
- `bandit` ~> 1.5 (HTTP server)
- `jason` ~> 1.4 (JSON)
- `gettext` ~> 0.26 (i18n)

## File Organization

```
apps/lemon_web/
├── lib/lemon_web.ex                    # Main module with __using__ macros
├── lib/lemon_web/application.ex        # OTP application
├── lib/lemon_web/endpoint.ex           # Phoenix endpoint
├── lib/lemon_web/router.ex             # Routes
├── lib/lemon_web/telemetry.ex          # Telemetry
├── lib/lemon_web/gettext.ex            # i18n
├── lib/lemon_web/plugs/
│   └── require_access_token.ex         # Auth plug
├── lib/lemon_web/live/
│   ├── session_live.ex                 # Main LiveView
│   └── components/
│       ├── file_upload_component.ex
│       ├── message_component.ex
│       └── tool_call_component.ex
├── lib/lemon_web/components/
│   ├── core_components.ex              # Shared components
│   └── layouts.ex                      # Layout module
├── lib/lemon_web/controllers/
│   ├── error_html.ex                   # Error page renderer
│   └── error_json.ex                   # JSON error responses
└── priv/
    ├── static/assets/app.js            # Generated JS
    └── gettext/                        # i18n files
```
