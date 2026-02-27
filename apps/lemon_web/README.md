# LemonWeb

Phoenix web interface for the Lemon platform. Provides a real-time dashboard for interacting with Lemon agents via LiveView, a games lobby and match spectator UI, and optional token-based access control.

## Architecture Overview

LemonWeb is a Phoenix 1.7 application inside an Elixir umbrella project. It uses Phoenix LiveView for all interactive pages (no traditional controller-rendered views), Bandit as the HTTP server, and Tailwind CSS (loaded from CDN) for styling. Phoenix and LiveView client libraries are loaded from CDN ESM bundles rather than a local Node.js build pipeline.

### OTP Supervision Tree

```
LemonWeb.Application (:one_for_one)
  |-- LemonWeb.Telemetry     (telemetry supervisor)
  |-- LemonWeb.Endpoint       (Bandit HTTP + LiveView WebSocket)
```

### Request Pipeline

```
HTTP Request
  |
  v
LemonWeb.Endpoint
  |-- Plug.Static          (serves /assets, favicon.ico, robots.txt)
  |-- Phoenix.CodeReloader (dev only)
  |-- Phoenix.LiveReloader (dev only)
  |-- Plug.RequestId
  |-- Plug.Telemetry
  |-- Plug.Parsers         (urlencoded, multipart, JSON)
  |-- Plug.MethodOverride
  |-- Plug.Head
  |-- Plug.Session         (cookie store, key: "_lemon_web_key")
  |-- LemonWeb.Router
```

### WebSocket

A single LiveView socket is mounted at `/live` with cookie-based session info:

```elixir
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [session: @session_options]],
  longpoll: false
```

All LiveView pages communicate over this socket. There are no custom Phoenix Channels.

## Route Inventory

### Public Browser Pipeline (`:public_browser`)

No authentication required. Standard browser plugs (session, CSRF, secure headers).

| Path | LiveView | Action | Description |
|------|----------|--------|-------------|
| `/games` | `GamesLobbyLive` | `:index` | Lists public game matches with live updates |
| `/games/:id` | `GameMatchLive` | `:show` | Spectates a specific match with board state and event timeline |

### Authenticated Browser Pipeline (`:browser`)

Includes `RequireAccessToken` plug. When `LEMON_WEB_ACCESS_TOKEN` is set, requests must present a valid token.

| Path | LiveView | Action | Description |
|------|----------|--------|-------------|
| `/` | `SessionLive` | `:index` | Dashboard home; generates an isolated session key per browser tab |
| `/sessions/:session_key` | `SessionLive` | `:show` | Dashboard bound to a specific session key |

### Query Parameters

- `/?agent_id=<id>` -- Sets the agent for the auto-generated session (default: `"default"`)
- `/?token=<token>` -- Authenticates the request (stripped from URL by client-side JS after consumption)
- `/sessions/:session_key?token=<token>` -- Same token authentication for named sessions

## LiveView Pages

### SessionLive (`/`, `/sessions/:session_key`)

The primary dashboard page. Provides a chat-style interface for sending prompts to Lemon agents and receiving streaming responses.

**Features:**
- Real-time streaming of assistant responses via PubSub deltas
- Multi-file upload (up to 5 files, 20 MB each) with progress tracking and cancellation
- Tool call visualization in collapsible detail panels
- System notifications for run lifecycle events (started, completed, failed)
- Message history capped at 250 messages

**Session key resolution:**
1. If `params["session_key"]` is present and valid, use it directly
2. Otherwise, generate an isolated key: `agent:<agent_id>:web:browser:unknown:tab-<random>`
3. Client-side JS in `app.js` also generates a stable per-tab session key stored in `sessionStorage`

**PubSub events handled:**
- `:run_started` -- Displays "Run started" system message
- `:delta` -- Streams text into the current assistant message bubble
- `:engine_action` -- Renders a tool call detail panel
- `:run_completed` -- Finalizes the assistant message; shows error if the run failed

**Submission flow:**
1. User enters prompt and/or uploads files
2. Files are persisted to the uploads directory with timestamped names
3. Prompt is enriched with file paths and submitted via `LemonRouter.submit/1`
4. Response streams back through PubSub events

### GamesLobbyLive (`/games`)

Displays a live list of public game matches. Subscribes to `LemonGames.Bus` lobby events and refreshes the match list automatically when matches are created, updated, or expire. Each match entry shows game type (Connect4, Rock Paper Scissors), status badge, and a "Watch" link.

### GameMatchLive (`/games/:id`)

Spectator view for a single game match. Shows the current board state (Connect4 grid or RPS throws), match metadata, and a scrolling event timeline. Subscribes to per-match events via `LemonGames.Bus` and fetches incremental events in batches of 100.

**Supported game types:**
- `connect4` -- Rendered as a grid with colored chip indicators
- `rock_paper_scissors` -- Shows player throws and winner

## Components

### LiveView Components (under `lib/lemon_web/live/components/`)

| Component | Module | Purpose |
|-----------|--------|---------|
| `MessageComponent` | `LemonWeb.Live.Components.MessageComponent` | Renders chat bubbles for user, assistant, system, and tool call messages. Delegates tool calls to `ToolCallComponent`. |
| `FileUploadComponent` | `LemonWeb.Live.Components.FileUploadComponent` | Drag-and-drop file upload area with per-file progress bars, error messages, and cancel buttons. |
| `ToolCallComponent` | `LemonWeb.Live.Components.ToolCallComponent` | Collapsible `<details>` panel showing tool name, phase, detail payload (as formatted JSON), status, and optional message. Auto-opens when phase is `started` or `updated`. |

### Core Components (`lib/lemon_web/components/core_components.ex`)

Shared function components auto-imported into all LiveViews:

| Component | Description |
|-----------|-------------|
| `<.button>` | Slate-900 rounded button with hover and disabled states |
| `<.input>` | Text input with focus ring styling |
| `<.flash_group>` | Renders flash messages as colored banners (error: rose, success: emerald) |

### Layouts (`lib/lemon_web/components/layouts/`)

- `root.html.heex` -- HTML shell with `<head>` (meta, CSRF token, Tailwind CDN, `app.js`), renders `@inner_content`
- `app.html.heex` -- Passthrough layout, renders `@inner_content` directly

## Static Assets and Frontend

LemonWeb uses a CDN-based frontend strategy with no local build tools (no esbuild, no Node.js):

- **Tailwind CSS**: Loaded from `https://cdn.tailwindcss.com` in the root layout
- **Phoenix JS**: Loaded from `https://cdn.jsdelivr.net/npm/phoenix@1.8.1` (ESM)
- **Phoenix LiveView JS**: Loaded from `https://cdn.jsdelivr.net/npm/phoenix_live_view@1.0.18` (ESM)
- **app.js** (`priv/static/assets/app.js`): Client-side entry point that initializes the LiveSocket, generates stable per-tab session keys via `sessionStorage`, normalizes agent IDs, and strips token params from the URL after authentication

Static files are served by `Plug.Static` at `/` for paths matching `~w(assets favicon.ico robots.txt)`.

## Authentication

Authentication is handled by the `LemonWeb.Plugs.RequireAccessToken` plug, which is optional and only active when a token is configured.

**Behavior:**
1. If `config :lemon_web, :access_token` is `nil` or `""`, all requests pass through (no gate)
2. When a token is configured, it is checked from three sources (in order):
   - `Authorization: Bearer <token>` header
   - `?token=<token>` query parameter
   - Session marker (SHA256 hash stored in cookie under `:lemon_web_auth`)
3. On valid token: a SHA256 hash is stored in the session so subsequent requests skip the token check
4. On invalid or missing token: responds with `401 Unauthorized` and halts

**Token comparison** uses constant-time comparison via `Plug.Crypto.secure_compare/2`.

## File Uploads

Configured in `SessionLive.mount/3`:

| Setting | Value |
|---------|-------|
| Accepted types | Any (`:any`) |
| Max entries per submission | 5 |
| Max file size | 20 MB |
| Upload mode | Auto-upload (`auto_upload: true`) |

**Upload directory:** Configured via `config :lemon_web, :uploads_dir` or defaults to `System.tmp_dir!/0 <> "/lemon_web_uploads"`. Files are named `{timestamp_ms}-{unique_id}-{sanitized_filename}`.

## Configuration

### Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `LEMON_WEB_ACCESS_TOKEN` | Dashboard access token | `nil` (no auth) |
| `LEMON_WEB_UPLOADS_DIR` | Directory for uploaded files | `System.tmp_dir!/0 <> "/lemon_web_uploads"` |
| `LEMON_WEB_HOST` | Production hostname | `"localhost"` |
| `LEMON_WEB_PORT` | Production HTTP port | `4080` |
| `LEMON_WEB_SECRET_KEY_BASE` | Production secret key (required in prod) | -- |
| `PHX_SERVER` | Set to `"1"` or `"true"` to start the HTTP server in prod | -- |

### Application Config

```elixir
# config/config.exs
config :lemon_web, LemonWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [html: LemonWeb.ErrorHTML, json: LemonWeb.ErrorJSON], layout: false],
  pubsub_server: LemonCore.PubSub,
  live_view: [signing_salt: "lemonwebsigningsalt"]

config :lemon_web, :access_token, nil
config :lemon_web, :uploads_dir, Path.join(System.tmp_dir!(), "lemon_web_uploads")
```

### Per-Environment Defaults

| Environment | Port | Server | Secret Key |
|-------------|------|--------|------------|
| dev | 4080 (127.0.0.1) | Inline (no `server: true`) | Hardcoded dev key |
| test | 4082 (127.0.0.1) | `server: false` | Hardcoded test key |
| prod | `LEMON_WEB_PORT` (0.0.0.0) | Enabled via `PHX_SERVER` | `LEMON_WEB_SECRET_KEY_BASE` |

## Error Handling

- `LemonWeb.ErrorHTML` -- Renders HTML error pages from `error_html/` templates (404: "Page not found", 500: "Something went wrong")
- `LemonWeb.ErrorJSON` -- Returns JSON error responses using Phoenix status message mapping: `%{errors: %{detail: "..."}}`

## Dependencies

### Umbrella Dependencies

| App | Purpose |
|-----|---------|
| `lemon_core` | PubSub (`LemonCore.Bus`), session keys (`LemonCore.SessionKey`), events (`LemonCore.Event`), map helpers |
| `lemon_games` | Games bus (`LemonGames.Bus`), match service (`LemonGames.Matches.Service`) |
| `lemon_router` | Request routing (`LemonRouter.submit/1`) for submitting prompts to agents |

### External Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `phoenix` | ~> 1.7.14 | Web framework |
| `phoenix_live_view` | ~> 1.0 | Real-time interactive UI |
| `phoenix_html` | ~> 4.1 | HTML helpers and form builders |
| `phoenix_live_reload` | ~> 1.5 | Dev-only live reload |
| `bandit` | ~> 1.5 | HTTP server (replaces Cowboy) |
| `jason` | ~> 1.4 | JSON encoding/decoding |
| `gettext` | ~> 0.26 | Internationalization |
| `lazy_html` | >= 0.1.0 | Test-only HTML parsing |

## Running

```bash
# Start the entire umbrella (includes lemon_web)
mix phx.server

# Or start with an interactive shell
iex -S mix phx.server

# Run lemon_web tests only
mix test apps/lemon_web

# Access the dashboard
open http://localhost:4080
```

## File Organization

```
apps/lemon_web/
|-- mix.exs
|-- lib/
|   |-- lemon_web.ex                              # Module macros (:live_view, :router, :html, etc.)
|   |-- lemon_web/
|       |-- application.ex                         # OTP application supervisor
|       |-- endpoint.ex                            # Phoenix endpoint (Bandit, sessions, static)
|       |-- router.ex                              # Route definitions and pipelines
|       |-- telemetry.ex                           # Telemetry supervisor
|       |-- gettext.ex                             # i18n backend
|       |-- plugs/
|       |   |-- require_access_token.ex            # Optional token authentication plug
|       |-- live/
|       |   |-- session_live.ex                    # Main dashboard LiveView
|       |   |-- games_lobby_live.ex                # Games lobby listing
|       |   |-- game_match_live.ex                 # Game match spectator
|       |   |-- components/
|       |       |-- file_upload_component.ex        # File upload UI
|       |       |-- message_component.ex            # Chat message bubbles
|       |       |-- tool_call_component.ex          # Tool call detail panels
|       |-- components/
|       |   |-- core_components.ex                 # Shared button, input, flash components
|       |   |-- layouts.ex                         # Layout module (embeds templates)
|       |   |-- layouts/
|       |       |-- root.html.heex                 # HTML document shell
|       |       |-- app.html.heex                  # App layout (passthrough)
|       |-- controllers/
|           |-- error_html.ex                      # HTML error renderer
|           |-- error_json.ex                      # JSON error renderer
|           |-- error_html/
|               |-- 404.html.heex                  # Not found page
|               |-- 500.html.heex                  # Server error page
|-- priv/
|   |-- static/
|   |   |-- assets/
|   |       |-- app.js                             # Client-side JS (LiveSocket init, session keys)
|   |-- gettext/
|       |-- .keep
|-- test/
    |-- test_helper.exs
    |-- lemon_web_test.exs                         # Smoke tests (app starts, modules load)
    |-- lemon_web/
        |-- live/
            |-- games_live_test.exs                # LiveView integration tests for games pages
```
