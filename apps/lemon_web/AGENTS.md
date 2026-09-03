# lemon_web AGENTS.md

Phoenix web interface for Lemon with LiveView. Provides real-time agent chat and authenticated session operations.

## Quick Orientation

This is a Phoenix 1.7 LiveView app inside the Lemon umbrella. The frontend uses checked-in compiled Tailwind CSS plus vendored Phoenix/LiveView JS from umbrella dependencies; production has no runtime CDN dependency. The HTTP server is Bandit.

Key entry points:
- **Router**: `lib/lemon_web/router.ex` -- all routes defined here
- **Endpoint**: `lib/lemon_web/endpoint.ex` -- HTTP pipeline and socket config
- **Main LiveView**: `lib/lemon_web/live/session_live.ex` -- the dashboard chat UI
- **Management LiveView**: `lib/lemon_web/live/management_live.ex` -- session/runtime operations
- **Provider management**: `lib/lemon_web/live/provider_management_live.ex` -- redacted routing mutations
- **Memory management**: `lib/lemon_web/live/memory_management_live.ex` -- bounded redacted recall/provenance/delete
- **Session export**: `lib/lemon_web/controllers/session_export_controller.ex` -- redacted downloads
- **Auth plug**: `lib/lemon_web/plugs/require_access_token.ex` -- optional chat or required management token gate

## Purpose and Responsibilities

- **Web UI**: Main dashboard for interacting with Lemon agents
- **LiveView Sessions**: Real-time chat interface with streaming updates
- **File Uploads**: Multi-file uploads (up to 5 files, 20MB each) with progress tracking
- **Message Display**: User messages, assistant responses, system notifications, tool calls
- **Tool Call Visualization**: Collapsible `<details>` elements showing engine actions and results
- **Authentication**: Optional access token protection via Bearer header, query param, or session
- **First-run readiness**: Shared `LemonCore.Setup.Readiness` state blocks doomed prompt/upload submissions and gives exact setup recovery
- **Run control**: Active browser runs expose cancellation plus explicit
  follow-up/steer/redirect submission through the shared router contracts
- **Session lifecycle**: Shared `LemonCore.SessionLifecycle` list/search/title/pin/archive/export/prune operations; never duplicate its stores
- **Provider lifecycle**: Shared `LemonAgent.ModelRuntime.ProviderConfiguration` preview/apply boundary; never edit provider TOML directly from the Web app
- **Blueprint lifecycle**: Shared `LemonAutomation.Blueprint.Catalog` bounded-ID, validation, digest, and activation boundary; never read bundle paths or create cron/profile records directly
- **Memory lifecycle**: Shared `LemonMemory.Lifecycle` bounded list/search/provenance/preview/delete boundary; never read memory SQLite or render raw Store rows
- **Profile lifecycle**: Shared `LemonCore.ProfileStore` create/clone/rename/delete boundary; Web state is limited to bounded metadata and opaque revisions, never profile paths or system prompts
- **Management security**: `/manage` fails closed without a configured access token; inspection/export are always redacted
- **Resume**: Named chat routes reconstruct durable prompt/tool/answer history using the internal trusted unredacted mode

## Phoenix Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  Endpoint (LemonWeb.Endpoint)                                 │
│  ├── Socket "/live" → Phoenix.LiveView.Socket                 │
│  ├── Static assets                                            │
│  └── Router (LemonWeb.Router)                                 │
│       ├── Pipeline :browser → optional RequireAccessToken     │
│       └── Pipeline :management_browser → required token       │
└─────────────────────────────────────────────────────────────┘
```

### OTP Application Structure

- `LemonWeb.Application` - Supervisor with `Telemetry` and `Endpoint` (`:one_for_one`)
- `LemonWeb.Endpoint` - HTTP/WebSocket endpoint (uses Bandit); session stored in signed cookie `_lemon_web_key`
- `LemonWeb.Router` - Chat routes plus token-required `/manage` session/export, `/manage/providers`, `/manage/blueprints`, `/manage/memory`, and `/manage/profiles` routes
- `LemonWeb.Telemetry` - Phoenix telemetry metrics

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
- `:run_status` - `:idle`, `:running`, `:stopping`, or `:unavailable` for active-run controls
- `:control_mode` - `:followup`, `:steer`, or `:redirect` while a run is active
- `:control_notice` - Bounded success/refusal feedback; never copy raw runtime
  error terms into this assign
- `:setup_state` / `:setup_ready?` - Shared config/secrets/provider readiness shown in the browser
- `:submit_error` - Validation/error string shown above submit button

**PubSub integration:**
- Subscribes to `LemonCore.Bus.session_topic(session_key)` and the global `"system"` topic on mount (only when `connected?/1`)
- Receives session events `:run_started`, `:delta`, `:engine_action`, `:run_completed` plus system `:config_reloaded` and `:secret_changed` readiness events
- Unknown `%LemonCore.Event{}` types are silently ignored

The UI must fail closed while `LemonCore.Setup.Readiness.ready?/1` is false:
do not consume uploads, append a user message, or call `LemonRouter.submit/1`.
The terminal setup flow owns mutations; the Web surface is a read-only status
and recovery guide. The separately authenticated `/manage/providers` route is
the only current Web settings journey and delegates every write to the shared
provider-configuration service.

Named session mounts also call `SessionLifecycle.history/2` with
`redact: false` to reconstruct the user's private conversation in order. This
mode is restricted to the in-process chat resume path. Management inspection,
downloads, and operator JSON-RPC must remain redacted.

Every mount also reconciles its active run through
`LemonCore.RouterBridge.active_run/1`. Follow-up, steer, and redirect are shown
only for an eligible active run and recheck that read model at submit time.
Only an exact `:none` response means idle. An initial error, unexpected answer,
exception, or exit renders an explicit disabled unavailable state; a later
lookup failure preserves the last known running/stopping state and draft.
Active guidance is text-only and bounded by the shared named-node control-text
limit. A successful router submission keeps `:last_run_id` pointed at the
original active run (the returned submission ID is not a stop target); a stale
or refused control keeps the draft and renders a fixed user-facing message.
Do not expose remote error terms, invocation IDs, credentials, or paths.

### ManagementLive

`LemonWeb.ManagementLive` is the focused operations shell. It reads runtime
health and sanitized named-node presence, lists/searches durable sessions,
mutates title/pin/archive metadata, renders redacted structured runs/tools,
links back to chat resume, and drives confirmation-bound prune. It must use
`LemonCore.SessionLifecycle` rather than reading or deleting store tables
directly.

Prune UI rules are security properties: preview first; archived-only and
unpinned by default; show exact candidate keys; keep the opaque confirmation
token server-side; and require a new preview after any lifecycle mutation.
Never add raw event/run dumps to management inspection or exports.

### ProviderManagementLive

`LemonWeb.ProviderManagementLive` renders redacted effective fallback and
credential-pool state and delegates every preview/apply to
`LemonAgent.ModelRuntime.ProviderConfiguration`. It may show validated provider
and pool identifiers plus counts, but never raw credential references, secret
or environment names, base URLs, config paths, prompts, or service error
payloads.

All Web writes are preview-first. Keep the opaque config revision server-side
and pass it as `expectedRevision` on apply so a concurrent config edit fails
closed. Destructive actions additionally require the exact confirmation from
the service. Credential-reference values use password fields, are filtered from
Phoenix logs, are hashed only long enough to match preview with re-entry, and
must never be copied into socket drafts or rendered HTML. Stale and refused
mutations keep non-secret drafts; stale previews are cleared so they cannot be
replayed.

### BlueprintManagementLive

`LemonWeb.BlueprintManagementLive` uses the automation-owned
`LemonAutomation.Blueprint.Catalog` service also consumed by control-plane
methods. The Web app must not resolve catalog paths, read manifests, copy
skills, or write cron/profile stores itself.

Only regex-constrained IDs, bounded counts, parsed schedule/enabled/action
fields, audit enums, and the fresh confirmation digest may enter LiveView
state. Free-form bundle/automation names and descriptions, prompts, skill
bodies, commands, environment values, tokens, and paths are excluded even
though lower-level inspection responses may contain some manifest metadata.
Preview is read-only. Activation requires retyping the exact 64-character
digest; a catalog/profile/destination change fails closed, clears the stale
preview, and keeps the profile draft. A successful replay reports `unchanged`
and preserves one stable cron job.

### MemoryManagementLive

`LemonWeb.MemoryManagementLive` is a read-mostly view over
`LemonMemory.Lifecycle`. It supports bounded search and filtering by scope,
safe agent label, one-way workspace digest, and `run` / `learned_source` kind.
The LiveView receives only Safety-redacted prompt/answer summaries,
allowlisted provenance types, counts, and SHA-256 digests. It never receives or
renders raw source paths/URLs, workspace keys, provider details, store errors,
secret names/values, prompts outside the bounded summary, or arbitrary
exception terms.

Single-record deletion always starts as a dry-run preview. The operator must
retype the exact digest bound to the document ID and a deterministic revision
over every persisted field. The Store checks that revision in constant time
inside the transaction that removes both the document and FTS row. Wrong,
stale, missing, malformed, or ambiguous targets mutate nothing and keep the
current search/filter draft.

### ProfileManagementLive

`LemonWeb.ProfileManagementLive` delegates lifecycle writes to
`LemonCore.ProfileStore` and uses `LemonCore.NodeRegistry` only for current
named-node availability. It must sanitize each service record before assigning
it: IDs, names, model/node/status, availability, and canonical session keys are
allowed; derived paths and system prompts are not. All create/clone/rename/delete
writes are preview-first. Clone, rename, and delete recheck a server-held opaque
profile revision in constant time immediately before the service call; delete
also requires exact-ID confirmation and inherits the store's trash-first
rollback semantics. Stale/refused writes keep form drafts and expose only fixed
error text.

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

1. If no `:access_token` is configured, optional chat routes pass; routes with `required: true` return HTTP 503
2. Token sources (checked in order):
   - `Authorization: Bearer <token>` header
   - Query param `?token=<token>`
   - Session marker (`:lemon_web_auth`)
3. On valid token -> store SHA256 hash of token in session under `:lemon_web_auth`
4. On invalid/missing -> 401 Unauthorized (halts pipeline)

Valid query-token authentication must redirect server-side to the same path
and non-token query parameters with `token` removed before any page renders.
Bearer authentication establishes the session marker without redirecting.
Never regress this to JavaScript-only cleanup: address history, referrers, and
screenshots exist before client code runs.

The `:management_browser` pipeline always uses `required: true`. Do not move
management routes into the optional pipeline.

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
- `use Phoenix.VerifiedRoutes` (verified path helpers like `~p"/sessions/#{session_key}"`)

Other available macros: `:router`, `:controller`, `:live_component`, `:html`.

## Testing Guidance

### Test Location

`apps/lemon_web/test/`

### Running Tests

```bash
# Run all lemon_web tests
mix test apps/lemon_web

# Run a specific test file
mix test apps/lemon_web/test/lemon_web/session_live_test.exs
```

### Existing Tests

- `test/lemon_web_test.exs` -- Smoke tests: application starts, endpoint config present, router and SessionLive modules load

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
- `LemonCore.Setup.Readiness` -- Single read-only first-run readiness state shared with the CLI/TUI
- `LemonCore.RouterBridge` -- Fail-safe active-run lookup used to discover and
  revalidate eligible active-session controls
- `LemonCore.NodeRegistry.max_control_text_bytes/0` -- Shared text bound for
  Web steer/redirect guidance

### lemon_agent

- `LemonAgent.ModelRuntime.ProviderConfiguration` -- The sole provider-routing
  mutation, validation, atomic-write, confirmation, revision, and redaction
  boundary used by the Web management page

### lemon_memory

- `LemonMemory.Lifecycle` -- bounded, redacted list/search/inspect and guarded
  single-record delete used by `/manage/memory`

### lemon_router

- `LemonRouter.submit/1` -- Submits a prompt to be routed to the appropriate agent. Returns `{:ok, run_id}` or `{:error, reason}`.
- `LemonRouter.abort/1` -- Aborts the active run for a session key.
- `LemonRouter.abort_run/1` -- Aborts a specific run by ID.
- Active-run submissions set `queue_mode` to `:followup`, `:steer`, or
  `:redirect`; do not add a Web-only control protocol.

## Configuration Reference

| Config Key | Env Var | Default | Purpose |
|------------|---------|---------|---------|
| `:access_token` | `LEMON_WEB_ACCESS_TOKEN` | `nil` | Optional chat gate; required for management |
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
|   |-- management_live.ex              # Authenticated session operations
|   |-- memory_management_live.ex       # Authenticated durable-memory inspection/delete
|   |-- blueprint_management_live.ex    # Authenticated exact-confirmed blueprint activation
|   |-- provider_management_live.ex     # Authenticated provider-routing operations
|   |-- profile_management_live.ex      # Authenticated preview-first profile lifecycle
|   |-- components/
|       |-- file_upload_component.ex    # Upload UI with progress bars
|       |-- message_component.ex        # Chat message bubbles
|       |-- tool_call_component.ex      # Collapsible tool call details
|-- lib/lemon_web/components/
|   |-- core_components.ex              # button/1, input/1, flash_group/1
|   |-- layouts.ex                      # embeds layouts/* templates
|   |-- layouts/
|       |-- root.html.heex             # HTML document shell
|       |-- app.html.heex             # App layout (passthrough)
|-- lib/lemon_web/controllers/
|   |-- error_html.ex                   # HTML error pages
|   |-- error_json.ex                   # JSON error responses
|   |-- error_html/
|       |-- 404.html.heex             # Not found page
|       |-- 500.html.heex             # Server error page
|-- priv/
|   |-- static/assets/app.css          # Checked-in compiled Tailwind stylesheet
|   |-- static/assets/session.css      # Responsive active-run controls and notices
|   |-- static/assets/management.css   # Responsive session/provider management UI
|   |-- static/assets/app.js           # Client JS (LiveSocket init, session keys)
|   |-- gettext/.keep                   # i18n placeholder
|-- test/
    |-- test_helper.exs
    |-- lemon_web_test.exs              # Smoke tests
    |-- lemon_web/live/
        |-- games_live_test.exs         # Games LiveView integration tests
```
