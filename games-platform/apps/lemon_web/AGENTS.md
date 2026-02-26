# lemon_web AGENTS.md

Phoenix web interface for Lemon with LiveView.

## Purpose and Responsibilities

- **Web UI**: Main dashboard for interacting with Lemon agents
- **LiveView Sessions**: Real-time chat interface with streaming updates
- **File Uploads**: Multi-file uploads (up to 5 files, 20MB each) with progress tracking
- **Message Display**: User messages, assistant responses, system notifications, tool calls
- **Tool Call Visualization**: Collapsible `<details>` elements showing engine actions and results
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

- `LemonWeb.Application` - Supervisor with `Telemetry` and `Endpoint` (`:one_for_one`)
- `LemonWeb.Endpoint` - HTTP/WebSocket endpoint (uses Bandit); session stored in signed cookie `_lemon_web_key`
- `LemonWeb.Router` - Routes: `/` (index), `/sessions/:session_key` (show)
- `LemonWeb.Telemetry` - Phoenix telemetry metrics

## LiveView Structure

### Main LiveView

**`LemonWeb.SessionLive`** - Single LiveView handling both index and show actions:

```elixir
# Routes
live "/", SessionLive, :index        # Generates a new isolated session key per tab
live "/sessions/:session_key", SessionLive, :show  # Uses the provided session key
```

**Query params supported on `/`:**
- `?agent_id=<id>` - Sets the agent for the isolated session (default: `"default"`)

**Session key resolution in `mount/3`:**
1. If `params["session_key"]` is present and passes `SessionKey.valid?/1` → use it directly
2. Otherwise → generate an isolated key via `SessionKey.channel_peer/1` with `channel_id: "web"`, `account_id: "browser"`, `peer_kind: :unknown`, `peer_id: "tab-<random>"`
3. `agent_id` is derived from the session key via `SessionKey.agent_id/1`, falling back to `"default"`

**Key assigns:**
- `:session_key` - Current session identifier
- `:agent_id` - Agent handling the session
- `:prompt` - Current textarea value
- `:messages` - List of message maps (max 250, newest kept on overflow)
- `:last_run_id` - Tracks current run for delta aggregation
- `:submit_error` - Validation/error string shown above submit button

**PubSub integration:**
- Subscribes to `LemonCore.Bus.session_topic(session_key)` on mount (only when `connected?/1`)
- Receives events: `:run_started`, `:delta`, `:engine_action`, `:run_completed`
- Unknown `%LemonCore.Event{}` types are silently ignored

### Message Structure

Messages are plain maps. Different kinds have different shapes:

```elixir
# user / system
%{
  id: String.t(),         # e.g. "user-12345" or "system-12346"
  kind: :user | :system,
  content: String.t(),
  ts_ms: integer()
}

# assistant (streaming or final)
%{
  id: String.t(),         # e.g. "assistant-12347"
  kind: :assistant,
  run_id: String.t(),
  content: String.t(),    # Accumulated delta text; may be "" during streaming
  pending: boolean(),     # true while streaming, false when finalized
  ts_ms: integer()
}

# tool_call — note: no :content field
%{
  id: String.t(),         # e.g. "tool-12348"
  kind: :tool_call,
  event: map(),           # Full engine_action payload from the Bus event
  ts_ms: integer()
}
```

**Message list management:**
- Messages prepended for O(1) then reversed; max 250 kept (newest)
- `upsert_assistant_delta/3` finds an existing `:pending` assistant message by `run_id` and appends text, or creates a new one
- `finalize_assistant_message/3` marks the matching assistant message as `pending: false`; if none exists and `answer` is non-nil, appends a new final message

### Components

**Function Components (Phoenix.Component):**

| Component | Module | Purpose |
|-----------|--------|---------|
| `FileUploadComponent` | `LemonWeb.Live.Components.FileUploadComponent` | Drag-drop file upload UI with progress bars |
| `MessageComponent` | `LemonWeb.Live.Components.MessageComponent` | Message bubble rendering (delegates tool_call to ToolCallComponent) |
| `ToolCallComponent` | `LemonWeb.Live.Components.ToolCallComponent` | `<details>` element; auto-open when phase is `started` or `updated` |
| `CoreComponents` | `LemonWeb.CoreComponents` | `<.button>`, `<.input>`, `<.flash_group>` |
| `Layouts` | `LemonWeb.Layouts` | Root and app layouts via `embed_templates "layouts/*"` |

**Usage pattern:**
```elixir
# In SessionLive.render/1
<MessageComponent.message message={message} />
<FileUploadComponent.file_upload upload={@uploads.files} />
```

**ToolCallComponent fields read from `event` map:**
- `event.action.title` or `event.action.kind` → displayed as title
- `event.action.detail` → shown as preformatted JSON/text
- `event.phase` → shown as label; controls `open?` (`started`/`updated` = open)
- `event.ok` → shows "ok" or "failed" status
- `event.message` → additional preformatted output

All field access uses atom-or-string key lookup (maps may use either).

## Authentication Flow

**`LemonWeb.Plugs.RequireAccessToken`** - Pipeline plug:

1. If no `:access_token` configured (nil or `""`) → allow all
2. Token sources (checked in order):
   - `Authorization: Bearer <token>` header
   - Query param `?token=<token>`
   - Session marker (`:lemon_web_auth`)
3. On valid token → store SHA256 hash of token in session under `:lemon_web_auth`
4. On invalid/missing → 401 Unauthorized (halts pipeline)

**Configuration:**
```elixir
config :lemon_web, :access_token, System.get_env("LEMON_WEB_ACCESS_TOKEN")
```

## File Uploads

**Configured in `SessionLive.mount/3`:**
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
2. `FileUploadComponent` shows per-entry progress bars and cancel buttons
3. On submit, `persist_uploads/1` consumes entries:
   - Files saved to `Application.get_env(:lemon_web, :uploads_dir)` or `System.tmp_dir!/0 <> "/lemon_web_uploads"`
   - Naming: `{timestamp_ms}-{unique_id}-{sanitized_filename}`
   - Returns list of upload metadata maps: `%{name:, path:, content_type:, size:}` (or `%{name:, path: nil, error:}` on failure)
4. `build_submission_prompt/2` appends file paths to the prompt text sent to the router
5. `build_user_message/2` constructs the display-only text (shows filenames, not paths)

**Events:**
- `phx-change="validate"` - Updates `:prompt` assign
- `phx-submit="submit"` - Validates and submits; blocked if any upload is in progress
- `phx-click="cancel-upload"` - Cancels in-progress upload entry

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
  meta: %{source: :lemon_web, web_dashboard: true, uploads: uploads}
})
# Returns {:ok, run_id} | {:error, reason}
```

### Abort a Run

```elixir
LemonRouter.abort(session_key)               # abort active run for session
LemonRouter.abort_run(run_id)                # abort specific run
```

### Handle Bus Events

```elixir
def handle_info(%LemonCore.Event{type: :delta, payload: payload, meta: meta}, socket) do
  run_id = Map.get(payload, :run_id) || Map.get(meta, :run_id)
  text = Map.get(payload, :text) || ""
  # upsert_assistant_delta(socket, run_id, text)
  {:noreply, socket}
end
```

### Add a New LiveView

```elixir
defmodule LemonWeb.MyLive do
  use LemonWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>Content</div>
    """
  end
end
```

Add to router in `LemonWeb.Router`:
```elixir
live "/my-path", MyLive, :index
```

### Add a New Function Component

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

### Add a Core Component

Add to `LemonWeb.CoreComponents` (auto-imported in all LiveViews via `html_helpers`):
```elixir
attr :rest, :global
slot :inner_block

def my_button(assigns) do
  ~H"""
  <button {@rest}>{render_slot(@inner_block)}</button>
  """
end
```

## `use LemonWeb, :live_view` Macro

Calling `use LemonWeb, :live_view` in a LiveView module sets up:
- `use Phoenix.LiveView, layout: {LemonWeb.Layouts, :app}`
- `use Gettext, backend: LemonWeb.Gettext`
- `import Phoenix.HTML`
- `import LemonWeb.CoreComponents` (all core components available as `<.button>` etc.)
- `alias Phoenix.LiveView.JS`
- `use Phoenix.VerifiedRoutes` (verified path helpers)

## Testing Guidance

**Test location:** `apps/lemon_web/test/`

**Current tests** (`test/lemon_web_test.exs`) are basic smoke tests:
- Application starts successfully
- Endpoint config is present
- Router module loads
- `LemonWeb.SessionLive` module loads

**Run tests:**
```bash
mix test apps/lemon_web
```

**Key testing considerations:**
- LiveView integration tests need `Phoenix.LiveViewTest` and a `ConnCase`/`LiveViewCase` setup
- PubSub subscriptions are skipped when `connected?/1` is false (static render), so event handling requires a connected LiveView test
- File upload testing uses `file_input/4` and `render_upload/3` from `Phoenix.LiveViewTest`
- Session key is auto-generated per mount; use `/sessions/:session_key` route in tests to control it

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
├── lib/lemon_web.ex                    # __using__ macros: :live_view, :router, :html, etc.
├── lib/lemon_web/application.ex        # OTP application (Telemetry + Endpoint)
├── lib/lemon_web/endpoint.ex           # Phoenix endpoint (Bandit, session cookie)
├── lib/lemon_web/router.ex             # Routes + :browser pipeline
├── lib/lemon_web/telemetry.ex          # Telemetry
├── lib/lemon_web/gettext.ex            # i18n backend
├── lib/lemon_web/plugs/
│   └── require_access_token.ex         # Auth plug (optional token gate)
├── lib/lemon_web/live/
│   ├── session_live.ex                 # Main LiveView (LemonWeb.SessionLive)
│   └── components/
│       ├── file_upload_component.ex    # (LemonWeb.Live.Components.FileUploadComponent)
│       ├── message_component.ex        # (LemonWeb.Live.Components.MessageComponent)
│       └── tool_call_component.ex      # (LemonWeb.Live.Components.ToolCallComponent)
├── lib/lemon_web/components/
│   ├── core_components.ex              # button/1, input/1, flash_group/1
│   └── layouts.ex                      # embeds priv/static/layouts/
├── lib/lemon_web/controllers/
│   ├── error_html.ex                   # HTML error pages
│   └── error_json.ex                   # JSON error responses
└── priv/
    ├── static/assets/app.js            # Compiled JS (esbuild output)
    └── gettext/                        # i18n files
```
