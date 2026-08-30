# LemonWeb

Phoenix web interface for the Lemon platform. Provides real-time agent chat and a token-required local operations shell over shared Lemon runtime/session services.

## Architecture Overview

LemonWeb is a Phoenix 1.7 application inside an Elixir umbrella project. It uses Phoenix LiveView for interactive pages, Bandit as the HTTP server, and checked-in release assets for both Phoenix JavaScript and compiled Tailwind CSS. The page has no runtime CDN dependency.

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

### Browser Pipeline (`:browser`)

Includes `RequireAccessToken` plug. When `LEMON_WEB_ACCESS_TOKEN` is set, requests must present a valid token.

| Path | LiveView | Action | Description |
|------|----------|--------|-------------|
| `/` | `SessionLive` | `:index` | Dashboard home; generates an isolated session key per browser tab |
| `/sessions/:session_key` | `SessionLive` | `:show` | Dashboard bound to a specific session key |

### Required Management Pipeline (`:management_browser`)

The `/manage` surface always requires a configured `LEMON_WEB_ACCESS_TOKEN`.
It returns HTTP 503 when no token is configured and HTTP 401 for missing or
invalid credentials. A valid query token stores only a token-derived session
marker and immediately redirects to the same URL with `token` removed; bearer
authentication establishes the same marker without redirecting.

| Path | Handler | Description |
|------|---------|-------------|
| `/manage` | `ManagementLive` | Runtime/node status and searchable active/archived sessions |
| `/manage/blueprints` | `BlueprintManagementLive` | Content-free catalog inspection, validation, exact preview, and digest-confirmed activation |
| `/manage/providers` | `ProviderManagementLive` | Redacted provider fallback/pool/reference preview and apply |
| `/manage/sessions/:session_key` | `ManagementLive` | Redacted run/tool inspection and lifecycle controls |
| `/manage/sessions/:session_key/export/:format` | `SessionExportController` | Always-redacted `json` or `markdown` download |

### Query Parameters

- `/?agent_id=<id>` -- Sets the agent for the auto-generated session (default: `"default"`)
- `/?token=<token>` -- Authenticates the request (stripped by an immediate server redirect before rendering)
- `/sessions/:session_key?token=<token>` -- Same token authentication for named sessions

## LiveView Pages

### SessionLive (`/`, `/sessions/:session_key`)

The primary dashboard page. Provides a chat-style interface for sending prompts to Lemon agents and receiving streaming responses.

**Features:**
- Shared first-run readiness through `LemonCore.Setup.Readiness`; incomplete setup is explained before prompt or file persistence
- Real-time streaming of assistant responses via PubSub deltas
- Multi-file upload (up to 5 files, 20 MB each) with progress tracking and cancellation
- Tool call visualization in collapsible detail panels
- System notifications for run lifecycle events (started, completed, failed)
- Active-run stop control through `LemonRouter.abort_run/2`
- Message history capped at 250 messages
- Durable history reconstruction on `/sessions/:session_key`, including ordered prompt, tool, and answer messages for resume

**Session key resolution:**
1. If `params["session_key"]` is present and valid, use it directly
2. Otherwise, generate an isolated key: `agent:<agent_id>:web:browser:unknown:tab-<random>`
3. Client-side JS in `app.js` also generates a stable per-tab session key stored in `sessionStorage`

**PubSub events handled:**
- `:run_started` -- Displays "Run started" system message
- `:delta` -- Streams text into the current assistant message bubble
- `:engine_action` -- Renders a tool call detail panel
- `:run_completed` -- Finalizes the assistant message; shows error if the run failed
- `:config_reloaded` / `:secret_changed` on the `"system"` topic -- Re-derives browser setup readiness

**Submission flow:**
1. The shared readiness contract confirms config, secrets, provider, credential, and model are usable
2. User enters a prompt and/or uploads files
3. Files are persisted to the uploads directory with timestamped names
4. Prompt is enriched with file paths and submitted via `LemonRouter.submit/1`
5. Response streams back through PubSub events; **Stop** calls `LemonRouter.abort_run/2`

### ManagementLive (`/manage`)

The management page delegates to `LemonCore.SessionLifecycle` and does not own
a second session store. It provides bounded list/search, active/archive
filtering, title/pin/archive mutation, resume links, redacted structured
run/tool inspection, and redacted JSON/Markdown export. Runtime status comes
from `LemonCore.Runtime.Health`; live named-node presence comes from
`LemonCore.NodeRegistry` with node metadata deliberately omitted from the UI.

Guarded prune is preview-first and defaults to archived, unpinned sessions.
The confirmation token binds the threshold, policy flags, stable session keys,
index timestamps, and lifecycle metadata. If anything changes, execution fails
closed and requires a fresh preview. Canonical run history is committed last
after fallible ancillary cleanup, and deletion is verified.

Management inspection and downloads are always redacted and never expose raw
run records or event payloads. Chat resume is an internal trusted consumer of
unredacted history so the user can continue their own conversation; no operator
JSON-RPC method offers that mode.

### ProviderManagementLive (`/manage/providers`)

The provider page depends on the existing
`LemonAgent.ModelRuntime.ProviderConfiguration` service rather than owning a
second config writer. It shows only validated provider/pool identifiers and
credential-reference counts, and supports ordered fallback add/remove/clear,
pool create/update/activate/delete, and credential-reference add/remove/clear.

Every change is preview-first. Apply passes the preview's opaque config
revision back to the service, so any concurrent target change rejects the
write. Destructive operations also require the exact provider/pool confirmation
shown in the preview. Credential-reference values are password-masked, filtered
from LiveView logs, omitted from socket drafts, and re-entered on apply; the UI
keeps only a digest long enough to match the exact preview. Service errors are
mapped to bounded fixed text and never rendered verbatim.

### BlueprintManagementLive (`/manage/blueprints`)

The blueprint page delegates every operation to
`LemonAutomation.Blueprint.Catalog`, the same bounded-ID service used by the
control-plane RPC methods. It lists safe bundle IDs/counts, re-runs validation,
and previews exact profile skill plus cron actions without mutation. Apply
requires the displayed fresh 64-character digest; the service re-plans under
its lock, so catalog, profile, schedule, or destination drift rejects the
request and forces a new preview. Identical replay reports `unchanged` and
does not create a duplicate job.

The LiveView allowlists its own state projection. It does not retain or render
free-form manifest names/descriptions, prompts, skill bodies, commands,
environment values, tokens, paths, or service error terms. The profile draft
survives stale/refused operations, while the stale plan digest is cleared.

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

- `root.html.heex` -- HTML shell with `<head>` (meta, CSRF token, bundled `app.css` and `app.js`) plus the skip-navigation link
- `app.html.heex` -- Passthrough layout, renders `@inner_content` directly

## Static Assets and Frontend

LemonWeb uses a small checked-in static frontend strategy with no runtime build tools:

- **Tailwind CSS**: Precompiled and minified into `priv/static/assets/app.css`; release digests include it and runtime startup never contacts a CSS CDN
- **Phoenix JS**: Vendored from `deps/phoenix/priv/static/phoenix.mjs` into `priv/static/assets/vendor/phoenix.mjs`
- **Phoenix LiveView JS**: Vendored from `deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js` into `priv/static/assets/vendor/phoenix_live_view.esm.js`
- **app.js** (`priv/static/assets/app.js`): Client-side entry point that initializes the LiveSocket, generates stable per-tab session keys via `sessionStorage`, normalizes agent IDs, and strips token params from the URL after authentication

Static files are served by `Plug.Static` at `/` for paths matching
`~w(assets favicon.ico favicon.svg robots.txt)`. The root layout declares the
bundled SVG favicon explicitly, avoiding a first-load missing-favicon request.

## Authentication

Authentication is handled by `LemonWeb.Plugs.RequireAccessToken`. Chat routes
retain the optional local gate, while management routes pass `required: true`
and fail closed without a configured token.

**Behavior:**
1. If `config :lemon_web, :access_token` is `nil` or `""`, optional chat routes pass through; required management routes return HTTP 503
2. When a token is configured, it is checked from three sources (in order):
   - `Authorization: Bearer <token>` header
   - `?token=<token>` query parameter
   - Session marker (SHA256 hash stored in cookie under `:lemon_web_auth`)
3. On valid token: a SHA256 hash is stored in the session so subsequent requests skip the token check; query bootstrap redirects server-side to a token-free URL while bearer auth continues directly
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
| `LEMON_WEB_ACCESS_TOKEN` | Chat gate and required management credential | `nil` (chat open; management unavailable) |
| `LEMON_WEB_UPLOADS_DIR` | Directory for uploaded files | `System.tmp_dir!/0 <> "/lemon_web_uploads"` |
| `LEMON_WEB_HOST` | Production hostname | `"localhost"` |
| `LEMON_WEB_PORT` | HTTP port for unified runtime and production | `4080` |
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
| dev (`mix phx.server`) | 4080 (127.0.0.1) | Phoenix server task | Hardcoded dev key |
| dev (`bin/lemon`) | `LEMON_WEB_PORT` / `--web-port` (127.0.0.1) | Enabled by runtime boot | Hardcoded dev key |
| test | 4082 (127.0.0.1) | `server: false` | Hardcoded test key |
| prod | `LEMON_WEB_PORT` (0.0.0.0) | Enabled via `PHX_SERVER` | `LEMON_WEB_SECRET_KEY_BASE` |

## Error Handling

- `LemonWeb.ErrorHTML` -- Renders HTML error pages from `error_html/` templates (404: "Page not found", 500: "Something went wrong")
- `LemonWeb.ErrorJSON` -- Returns JSON error responses using Phoenix status message mapping: `%{errors: %{detail: "..."}}`

## Dependencies

### Umbrella Dependencies

| App | Purpose |
|-----|---------|
| `lemon_agent` | Shared provider configuration validation, atomic mutation, revision, confirmation, and redaction boundary |
| `lemon_automation` | Shared bounded blueprint catalog, validation, exact preview, profile activation, and create-once scheduler boundary |
| `lemon_core` | PubSub, session keys/events, shared session lifecycle, runtime health, and live node presence |
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
# Installed full release: start if needed, wait for Web health, and open browser
lemon web

# Source checkout: same behavior
./bin/lemon web

# Print the address without opening a browser
lemon web --no-open

# Run lemon_web tests only
mix test apps/lemon_web

# Contributor-only direct Phoenix path
mix phx.server
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
|       |   |-- require_access_token.ex            # Optional/required token authentication plug
|       |-- live/
|       |   |-- session_live.ex                    # Main dashboard LiveView
|       |   |-- management_live.ex                 # Authenticated session operations LiveView
|       |   |-- provider_management_live.ex        # Authenticated provider-routing LiveView
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
|           |-- session_export_controller.ex       # Redacted session downloads
|           |-- error_html.ex                      # HTML error renderer
|           |-- error_json.ex                      # JSON error renderer
|           |-- error_html/
|               |-- 404.html.heex                  # Not found page
|               |-- 500.html.heex                  # Server error page
|-- priv/
|   |-- static/
|   |   |-- assets/
|   |       |-- app.css                            # Precompiled Tailwind stylesheet
|   |       |-- management.css                     # Responsive management-shell styles
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
