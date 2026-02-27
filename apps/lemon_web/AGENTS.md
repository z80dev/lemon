# lemon_web AGENTS.md

Phoenix web interface for Lemon with LiveView. Provides a real-time agent dashboard, a games lobby, and a game match spectator.

## Quick Orientation

This is a Phoenix 1.7 LiveView app inside the Lemon umbrella. There are no traditional controllers -- every page is a LiveView. The frontend uses Tailwind from CDN and Phoenix/LiveView JS from CDN ESM bundles (no Node.js, no esbuild). The HTTP server is Bandit.

Key entry points:
- **Router**: `lib/lemon_web/router.ex` -- all routes defined here
- **Endpoint**: `lib/lemon_web/endpoint.ex` -- HTTP pipeline and socket config
- **Main LiveView**: `lib/lemon_web/live/session_live.ex` -- the dashboard chat UI
- **Games LiveViews**: `lib/lemon_web/live/games_lobby_live.ex`, `lib/lemon_web/live/game_match_live.ex`
- **Auth plug**: `lib/lemon_web/plugs/require_access_token.ex` -- optional token gate

## Purpose and Responsibilities

- **Web UI**: Main dashboard for interacting with Lemon agents
- **LiveView Sessions**: Real-time chat interface with streaming updates
- **File Uploads**: Multi-file uploads (up to 5 files, 20MB each) with progress tracking
- **Message Display**: User messages, assistant responses, system notifications, tool calls
- **Tool Call Visualization**: Collapsible `<details>` elements showing engine actions and results
- **Games Lobby**: Live listing of public game matches with auto-refresh
- **Game Spectator**: Real-time match viewer with board state and event timeline
- **Authentication**: Optional access token protection via Bearer header, query param, or session

## Phoenix Architecture Overview

```
Endpoint (LemonWeb.Endpoint)
  |-- Socket "/live" -> Phoenix.LiveView.Socket
  |-- Static assets
  |-- Router (LemonWeb.Router)
       |-- Pipeline :public_browser (no token gate)
       |    |-- /games -> GamesLobbyLive :index
       |    |-- /games/:id -> GameMatchLive :show
       |-- Pipeline :browser -> RequireAccessToken
            |-- / -> SessionLive :index
            |-- /sessions/:session_key -> SessionLive :show
```

### OTP Application Structure

- `LemonWeb.Application` - Supervisor with `Telemetry` and `Endpoint` (`:one_for_one`)
- `LemonWeb.Endpoint` - HTTP/WebSocket endpoint (uses Bandit); session stored in signed cookie `_lemon_web_key`
- `LemonWeb.Router` - Routes: public games (`/games`, `/games/:id`) and dashboard (`/`, `/sessions/:session_key`)
- `LemonWeb.Telemetry` - Telemetry supervisor (currently empty, placeholder for metrics)

## Key Files and Purposes

| File | Purpose |
|------|---------|
| `lib/lemon_web.ex` | Module macros: `use LemonWeb, :live_view`, `:router`, `:html`, etc. |
| `lib/lemon_web/application.ex` | OTP app: supervises Telemetry and Endpoint |
| `lib/lemon_web/endpoint.ex` | Plug pipeline, static serving, LiveView socket mount |
| `lib/lemon_web/router.ex` | Route definitions and pipeline plugs |
| `lib/lemon_web/plugs/require_access_token.ex` | Optional auth plug (Bearer/query/session) |
| `lib/lemon_web/live/session_live.ex` | Dashboard LiveView: chat, file upload, PubSub events |
| `lib/lemon_web/live/games_lobby_live.ex` | Games lobby: lists public matches, subscribes to lobby events |
| `lib/lemon_web/live/game_match_live.ex` | Match spectator: board state, event timeline, per-match PubSub |
| `lib/lemon_web/live/components/message_component.ex` | Chat bubble rendering (user, assistant, system, tool call) |
| `lib/lemon_web/live/components/file_upload_component.ex` | File upload UI with progress bars |
| `lib/lemon_web/live/components/tool_call_component.ex` | Collapsible tool call details |
| `lib/lemon_web/components/core_components.ex` | Shared `<.button>`, `<.input>`, `<.flash_group>` |
| `lib/lemon_web/components/layouts.ex` | Layout module (embeds `layouts/` templates) |
| `lib/lemon_web/components/layouts/root.html.heex` | HTML shell: head, Tailwind CDN, app.js |
| `lib/lemon_web/components/layouts/app.html.heex` | App layout (passthrough) |
| `lib/lemon_web/controllers/error_html.ex` | HTML error pages (embeds `error_html/` templates) |
| `lib/lemon_web/controllers/error_json.ex` | JSON error responses |
| `priv/static/assets/app.js` | Client JS: LiveSocket init, per-tab session key, URL cleanup |

## LiveView Structure

### SessionLive

**`LemonWeb.SessionLive`** - Dashboard LiveView handling both index and show actions:

```elixir
# Routes
live "/", SessionLive, :index        # Generates a new isolated session key per tab
live "/sessions/:session_key", SessionLive, :show  # Uses the provided session key
```

**Query params supported on `/`:**
- `?agent_id=<id>` - Sets the agent for the isolated session (default: `"default"`)

**Session key resolution in `mount/3`:**
1. If `params["session_key"]` is present and passes `SessionKey.valid?/1` -> use it directly
2. Otherwise -> generate an isolated key via `SessionKey.channel_peer/1` with `channel_id: "web"`, `account_id: "browser"`, `peer_kind: :unknown`, `peer_id: "tab-<random>"`
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

### Games LiveViews

- `LemonWeb.GamesLobbyLive` (`/games`) shows public matches and live lobby refreshes via `LemonGames.Bus.subscribe_lobby/0`.
- `LemonWeb.GameMatchLive` (`/games/:id`) renders match state + event timeline and subscribes to per-match events via `LemonGames.Bus.subscribe_match/1`.

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

# tool_call -- note: no :content field
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
- `event.action.title` or `event.action.kind` -> displayed as title
- `event.action.detail` -> shown as preformatted JSON/text
- `event.phase` -> shown as label; controls `open?` (`started`/`updated` = open)
- `event.ok` -> shows "ok" or "failed" status
- `event.message` -> additional preformatted output

All field access uses `LemonCore.MapHelpers.get_key/2` for atom-or-string key lookup.

## Authentication Flow

**`LemonWeb.Plugs.RequireAccessToken`** - Pipeline plug:

1. If no `:access_token` configured (nil or `""`) -> allow all
2. Token sources (checked in order):
   - `Authorization: Bearer <token>` header
   - Query param `?token=<token>`
   - Session marker (`:lemon_web_auth`)
3. On valid token -> store SHA256 hash of token in session under `:lemon_web_auth`
4. On invalid/missing -> 401 Unauthorized (halts pipeline)

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

## How to Add New Routes/Pages

### Add a New LiveView

1. Create the LiveView module:

```elixir
# lib/lemon_web/live/my_new_live.ex
defmodule LemonWeb.MyNewLive do
  use LemonWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "My Page")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-slate-100">
      <div class="mx-auto w-full max-w-3xl px-3 py-4">
        <h1 class="text-xl font-semibold text-slate-900">My Page</h1>
      </div>
    </main>
    """
  end
end
```

2. Add to router in `LemonWeb.Router`:

```elixir
# For public pages (no auth):
scope "/", LemonWeb do
  pipe_through(:public_browser)
  live("/my-path", MyNewLive, :index)
end

# For authenticated pages:
scope "/", LemonWeb do
  pipe_through(:browser)
  live("/my-path", MyNewLive, :index)
end
```

### Add a New Function Component

```elixir
# lib/lemon_web/live/components/my_component.ex
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

Use in a LiveView:
```elixir
alias LemonWeb.Live.Components.MyComponent

# In render/1:
<MyComponent.my_component data={@some_data} />
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

Use in any LiveView as `<.my_button>`.

### Subscribe to PubSub Events

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

### Handle Bus Events

```elixir
def handle_info(%LemonCore.Event{type: :delta, payload: payload, meta: meta}, socket) do
  run_id = Map.get(payload, :run_id) || Map.get(meta, :run_id)
  text = Map.get(payload, :text) || ""
  # Process the delta text...
  {:noreply, socket}
end
```

## `use LemonWeb, :live_view` Macro

Calling `use LemonWeb, :live_view` in a LiveView module sets up:
- `use Phoenix.LiveView, layout: {LemonWeb.Layouts, :app}`
- `use Gettext, backend: LemonWeb.Gettext`
- `import Phoenix.HTML`
- `import LemonWeb.CoreComponents` (all core components available as `<.button>` etc.)
- `alias Phoenix.LiveView.JS`
- `use Phoenix.VerifiedRoutes` (verified path helpers like `~p"/games/#{id}"`)

Other available macros: `:router`, `:controller`, `:live_component`, `:html`.

## Testing Guidance

### Test Location

`apps/lemon_web/test/`

### Running Tests

```bash
# Run all lemon_web tests
mix test apps/lemon_web

# Run a specific test file
mix test apps/lemon_web/test/lemon_web/live/games_live_test.exs
```

### Existing Tests

- `test/lemon_web_test.exs` -- Smoke tests: application starts, endpoint config present, router and SessionLive modules load
- `test/lemon_web/live/games_live_test.exs` -- LiveView integration tests for games lobby and match pages using `Phoenix.LiveViewTest`

### Writing LiveView Tests

```elixir
defmodule LemonWeb.Live.MyLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint LemonWeb.Endpoint

  test "renders the page" do
    {:ok, _view, html} = live(build_conn(), "/my-path")
    assert html =~ "Expected content"
  end
end
```

### Key Testing Considerations

- LiveView integration tests need `Phoenix.LiveViewTest` and `Phoenix.ConnTest`
- Set `@endpoint LemonWeb.Endpoint` in test modules
- PubSub subscriptions are skipped when `connected?/1` is false (static render), so event handling requires a connected LiveView test
- File upload testing uses `file_input/4` and `render_upload/3` from `Phoenix.LiveViewTest`
- Session key is auto-generated per mount; use `/sessions/:session_key` route in tests to control it
- Games tests depend on `LemonGames.Matches.Service` for creating test fixtures
- The test endpoint runs on port 4082 with `server: false`

### Testing the Auth Plug

When testing routes behind `RequireAccessToken`, either:
- Set `config :lemon_web, :access_token, nil` in test config (disables the gate)
- Pass `Authorization: Bearer <token>` header in test requests
- Pass `?token=<token>` query parameter

## Connections to Other Apps

### lemon_core

- `LemonCore.Bus` -- PubSub: `subscribe/1`, `session_topic/1` for session events
- `LemonCore.Event` -- Event struct received in `handle_info/2` callbacks; has `:type`, `:payload`, `:meta`
- `LemonCore.SessionKey` -- Session key generation and parsing: `channel_peer/1`, `valid?/1`, `agent_id/1`
- `LemonCore.MapHelpers` -- `get_key/2` for atom-or-string map key access
- `LemonCore.PubSub` -- The PubSub server process (configured as endpoint's `pubsub_server`)

### lemon_games

- `LemonGames.Bus` -- PubSub for games: `subscribe_lobby/0`, `subscribe_match/1`
- `LemonGames.Matches.Service` -- Match CRUD: `list_lobby/0`, `get_match/2`, `list_events/4`, `create_match/2`

### lemon_router

- `LemonRouter.submit/1` -- Submits a prompt to be routed to the appropriate agent. Returns `{:ok, run_id}` or `{:error, reason}`.
- `LemonRouter.abort/1` -- Aborts the active run for a session key.
- `LemonRouter.abort_run/1` -- Aborts a specific run by ID.

## Configuration Reference

| Config Key | Env Var | Default | Purpose |
|------------|---------|---------|---------|
| `:access_token` | `LEMON_WEB_ACCESS_TOKEN` | `nil` | Dashboard auth token |
| `:uploads_dir` | `LEMON_WEB_UPLOADS_DIR` | `System.tmp_dir! <> "/lemon_web_uploads"` | File upload storage |
| Endpoint `:url` | `LEMON_WEB_HOST` | `"localhost"` | Production hostname |
| Endpoint `:http` | `LEMON_WEB_PORT` | `4080` | HTTP listen port |
| Endpoint `:secret_key_base` | `LEMON_WEB_SECRET_KEY_BASE` | (required in prod) | Cookie signing |
| Endpoint `:server` | `PHX_SERVER` | `false` | Enable HTTP server |

## File Organization

```
apps/lemon_web/
|-- lib/lemon_web.ex                    # __using__ macros: :live_view, :router, :html, etc.
|-- lib/lemon_web/application.ex        # OTP application (Telemetry + Endpoint)
|-- lib/lemon_web/endpoint.ex           # Phoenix endpoint (Bandit, session cookie)
|-- lib/lemon_web/router.ex             # Routes + :browser pipeline
|-- lib/lemon_web/telemetry.ex          # Telemetry supervisor
|-- lib/lemon_web/gettext.ex            # i18n backend
|-- lib/lemon_web/plugs/
|   |-- require_access_token.ex         # Auth plug (optional token gate)
|-- lib/lemon_web/live/
|   |-- session_live.ex                 # Main dashboard LiveView
|   |-- games_lobby_live.ex             # Games lobby listing
|   |-- game_match_live.ex              # Match spectator view
|   |-- components/
|       |-- file_upload_component.ex    # Upload UI with progress bars
|       |-- message_component.ex        # Chat message bubbles
|       |-- tool_call_component.ex      # Collapsible tool call details
|-- lib/lemon_web/components/
|   |-- core_components.ex              # button/1, input/1, flash_group/1
|   |-- layouts.ex                      # embeds layouts/* templates
|   |-- layouts/
|       |-- root.html.heex             # HTML document shell (head, CDN links)
|       |-- app.html.heex             # App layout (passthrough)
|-- lib/lemon_web/controllers/
|   |-- error_html.ex                   # HTML error pages
|   |-- error_json.ex                   # JSON error responses
|   |-- error_html/
|       |-- 404.html.heex             # Not found page
|       |-- 500.html.heex             # Server error page
|-- priv/
|   |-- static/assets/app.js           # Client JS (LiveSocket init, session keys)
|   |-- gettext/.keep                   # i18n placeholder
|-- test/
    |-- test_helper.exs
    |-- lemon_web_test.exs              # Smoke tests
    |-- lemon_web/live/
        |-- games_live_test.exs         # Games LiveView integration tests
```
