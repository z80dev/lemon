# LemonWeb

Phoenix LiveView interface for Lemon: agent chat and operator workflows over the
shared runtime. User workflows belong in the
[browser user guide](../../docs/user-guide/web.md); contributor invariants live in
[AGENTS.md](AGENTS.md).

## Routes and operator access

`LemonWeb.Plugs.RequireOperator` gates operator HTTP routes, and
`LemonWeb.LiveAuth` checks every LiveView mount. Sign in at `/login` with the
control-plane operator token (`LEMON_CONTROL_PLANE_OPERATOR_TOKEN`); the session
holds a token-derived marker, not the token. Without a configured token the UI
returns 503, unless explicit tokenless loopback compatibility applies to the
actual socket peer. Unauthenticated GETs redirect to `/login`; other
unauthenticated operator requests return 401.

| Paths | Handler |
|-------|---------|
| `/` and `/chat/:session_key` | `ChatLive` |
| `/sessions` and `/sessions/:session_key` | `ManagementLive` |
| `/omp` and `/omp/:id` | `OmpLive` |
| `/automation` | `WorkManagementLive` |
| `/blueprints` | `BlueprintManagementLive` |
| `/skills` | `SkillsLive` |
| `/memory` | `MemoryManagementLive` |
| `/learning` | `LearningLive` |
| `/mcp` | `McpLive` |
| `/profiles` | `ProfileManagementLive` |
| `/models` | `ProviderManagementLive` |
| `/usage` | `UsageLive` |
| `/diagnostics` | `DiagnosticsLive` |
| `/settings` | `SettingsLive` |
| `/nodes` | `NodesLive` |
| `/sessions/:session_key/export/:format` | `SessionExportController` |
| `/profiles/:id/export` | `ProfileExportController` |

`GET /login` and `POST /login` handle sign-in; `DELETE /logout` signs out.
`GET /healthz` is the unauthenticated health endpoint. See the
[browser user guide](../../docs/user-guide/web.md) for sign-in and page workflows.

Learning uses the shared `LemonSkills.Timeline` lifecycle read model directly,
like Memory uses its owning lifecycle service. It displays only bounded,
redacted projections for the selected local profile; previews remain escaped
untrusted text. It has no separate store or mutation implementation.

## Configuration

### Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` | Operator credential used for browser sign-in | Launcher-managed; required unless explicit tokenless loopback compatibility applies |
| `LEMON_WEB_UPLOADS_DIR` | Directory for uploaded files | `System.tmp_dir!/0 <> "/lemon_web_uploads"` |
| `LEMON_WEB_HOST` | Production hostname | `"localhost"` |
| `LEMON_WEB_PORT` | HTTP port for unified runtime and production | `4080` |
| `LEMON_WEB_SECRET_KEY_BASE` | Phoenix production secret key base; required for the full runtime release | -- |
| `PHX_SERVER` | Enable the production HTTP server with `"1"`, `"true"`, or `"TRUE"` | -- |

## Development

Run these commands from the umbrella root:

```bash
# Start the source runtime if needed and open the browser
./bin/lemon web

# Set up the locked CSS build dependencies, then regenerate committed CSS
mix do --app lemon_web assets.setup
mix do --app lemon_web assets.build

# Run the app's tests
scripts/test path apps/lemon_web/test
```

The Tailwind build writes `priv/static/assets/app.css`. Commit regenerated CSS
when changing its source or template classes; releases do not need a Node
toolchain to build it at startup.
