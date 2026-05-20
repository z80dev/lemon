# LemonWeb

Phoenix web interface for the Lemon platform. Provides a real-time dashboard for interacting with Lemon agents via LiveView and optional token-based access control.

## Architecture Overview

LemonWeb is a Phoenix 1.7 application inside an Elixir umbrella project. It uses Phoenix LiveView for interactive pages, Bandit as the HTTP server, vendored Phoenix JavaScript from umbrella dependencies, and Tailwind CSS loaded from CDN for styling.

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

### Authenticated Browser Pipeline (`:browser`)

Includes `RequireAccessToken` plug. When `LEMON_WEB_ACCESS_TOKEN` is set, requests must present a valid token.

| Path | LiveView | Action | Description |
|------|----------|--------|-------------|
| `/` | `SessionLive` | `:index` | Dashboard home; generates an isolated session key per browser tab |
| `/ops` | `OpsDashboardLive` | `:index` | Operations dashboard for health, launch-readiness gate status, browser worker status/artifacts, media job metadata, provider readiness, grouped media provider-proof readiness, usage/cost/quota aggregates, memory-provider registry status, extension/plugin directory diagnostics, checkpoint metadata plus diff/restore controls, redacted goal/kanban status, runs, approvals including MCP OAuth `Open OAuth` actions and structured MCP sampling summaries, cron schedules with recent run/retry visibility, active-run abort controls, and recent lifecycle audit entries, skills, channels, and support bundle access |
| `/ops/runs/:run_id` | `OpsRunLive` | `:show` | Run detail page with timeline, tool events, failures, child-run graph, approval metadata and resolution actions including MCP OAuth and sampling context, and support bundle access |
| `/sessions/:session_key` | `SessionLive` | `:show` | Dashboard bound to a specific session key |

| Path | Controller | Action | Description |
|------|------------|--------|-------------|
| `/ops/support-bundle` | `SupportBundleController` | `:download` | Downloads a redacted Lemon support bundle zip |

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

### OpsDashboardLive (`/ops`)

Operations dashboard for support and runtime inspection.

**Features:**
- Runtime, router, launch-readiness gate summary, browser worker, media job, grouped media provider-proof readiness, provider readiness, usage/cost/quota aggregates, memory-provider registry, provider routing preview, and secrets status summary
- Version, release, git, Elixir, and OTP runtime metadata
- Default provider/model/thinking/engine editing and provider secret-reference editing
- Local browser driver lifecycle counters, redacted local/remote CDP driver mode, last error, artifact directory, and recent screenshot artifacts
- Redacted media job counts, artifact counts, cleanup policy, recent generated-media job metadata, and grouped image/TTS/STT/vision/video proof status with copy-ready live-proof commands, per-provider rerun commands, default proof artifact paths, and bounded permission/quota/payment/request-shape next actions from safe reason kinds
- Redacted usage aggregate panel backed by `LemonCore.UsageDiagnostics` for current requests, tokens, cost, provider rows, today totals, and configured run/token/cost limits without prompt text, responses, message bodies, credentials, or secret values
- Redacted memory-provider count, enabled provider count, source/scope/timeout shape, and cleanup flags matching `memory.status` and `memory_diagnostics.json`
- Redacted LSP checker/server/session status plus recent LSP proof artifacts and proof-check summaries
- Active sessions, recent runs, and observed introspection activity
- Pending execution approvals with resolution actions, including MCP OAuth authorization links for local PKCE flows and structured MCP sampling summaries with request hash, model, token, message, role, and content-kind metadata
- Cron schedule list with create/edit/delete, run-now, Pause/Resume, active-run Abort, retry policy controls, recent run/retry outcome visibility, and recent lifecycle audit entries
- Extension/plugin directory, manifest, registry audit, and WASM lifecycle diagnostics with redacted path/file hashes, aggregate capability/provider/host/distribution/audit shape, install/update proof status, sidecar lifecycle proof status, and no plugin-code loading
- Redacted durable kanban board/task status with counts, leases, columns, worker profile, and workspace hashes
- Skill health, provenance, required binaries, missing requirements, install/update controls, enable/disable controls, channel transport enable/disable config controls, shared Telegram/Discord launch-gate readiness, gateway default editing, Telegram token-secret and allowlist editing, Discord token-secret, allowlist, deny-unbound, and Message Content Intent declaration editing, channel binding create/edit/delete controls, live adapter status, and disconnect/reconnect controls
- Channel failure drilldown that reports Discord DM setup refusals, Discord Message Content Intent/free-response proof drift, and Discord slash client-click missing/invalid/non-promotable/stale proof state from the same sanitized reason kinds used by doctor and support bundles, with concrete live-matrix handoff commands surfaced for operators; the aggregate launch-gate card is backed by `LemonCore.Doctor.ChannelReadiness`, matching `channels.status` and support-bundle `channel_readiness.json`
- Launch Readiness panel backed by `LemonCore.Doctor.ReadinessSummary`, matching `mix lemon.readiness`, `readiness.status`, and support-bundle `readiness_summary.json` for doctor, Telegram/Discord gate, shared proof-gate, provider-media, proof, unresolved-gate, and cleanup summaries without raw ids, prompts, provider responses, proof paths/details, bot tokens, or secret values
- Support bundle download plus source-dev and release-runtime troubleshooting commands

### OpsRunLive (`/ops/runs/:run_id`)

Run-level support page for inspecting one execution.

**Features:**
- Run status, event counts, failures, pending approval summary with MCP OAuth and sampling metadata plus approve/deny actions, resolved/timed-out approval history, skill/memory learning events, Telegram/Discord channel events, cron lifecycle events, and subagent/delegation events
- Timeline of introspection events
- Tool event and failure lists
- Nested child-run graph from recorded `parent_run_id` relationships
- Support bundle download plus source-dev and release-runtime troubleshooting commands

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

LemonWeb uses a small static frontend strategy with no local build tools (no esbuild, no Node.js):

- **Tailwind CSS**: Loaded from `https://cdn.tailwindcss.com` in the root layout
- **Phoenix JS**: Vendored from `deps/phoenix/priv/static/phoenix.mjs` into `priv/static/assets/vendor/phoenix.mjs`
- **Phoenix LiveView JS**: Vendored from `deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js` into `priv/static/assets/vendor/phoenix_live_view.esm.js`
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
| `lemon_core` | PubSub (`LemonCore.Bus`), session keys (`LemonCore.SessionKey`), events (`LemonCore.Event`), map helpers |
| `lemon_router` | Request routing (`LemonRouter.submit/1`) for submitting prompts to agents |
| `lemon_ai_runtime` | Redacted provider credential readiness diagnostics |

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
