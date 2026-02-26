# Runtime Hot-Reload

This document covers Lemon's runtime code reload path for BEAM modules, extension
source files, and targeted OTP `code_change/3` callbacks.

## Components

- `Lemon.Reload` (`apps/lemon_core/lib/lemon_core/reload.ex`)
  - `reload_module/2`
  - `reload_app/2`
  - `reload_extension/2`
  - `reload_system/1`
- `LemonControlPlane.Methods.SystemReload`
  (`apps/lemon_control_plane/lib/lemon_control_plane/methods/system_reload.ex`)
  - JSON-RPC method: `system.reload`

## Locking Model

All reload operations run under a distributed lock:

- lock key: `{Lemon.Reload, :reload_lock}`
- implementation: `:global.trans/4`

This prevents overlapping reload operations from racing against each other.

## Reload Scopes

`system.reload` supports these scopes:

- `module` - reload one loaded module
- `app` - reload all modules declared in one OTP app
- `extension` - compile and load one `.ex` / `.exs` extension file
- `all` (default) - orchestrated reload path (apps + extensions + code_change)

### Example Requests

```json
{"jsonrpc":"2.0","id":1,"method":"system.reload","params":{"scope":"module","module":"LemonCore.Clock"}}
```

```json
{"jsonrpc":"2.0","id":2,"method":"system.reload","params":{"scope":"all","apps":["lemon_core"],"extensions":["/tmp/my_extension.ex"]}}
```

## Result Shape

Reload APIs return a normalized structure:

- `kind` (`module|app|extension|code_change|system`)
- `target`
- `status` (`ok|partial|error`)
- `reloaded` (list)
- `skipped` (list of `%{target, reason}`)
- `errors` (list of `%{target, reason}`)
- `duration_ms`
- `metadata` (scope-specific fields)

For `scope=all`, `metadata.results` includes child results for each app,
extension, and code-change target.

## Telemetry

Each operation emits telemetry events:

- `[:lemon, :reload, :start]`
- `[:lemon, :reload, :stop]`
- `[:lemon, :reload, :exception]`

## Tests

- `apps/lemon_core/test/lemon_core/reload_test.exs`
- `apps/lemon_control_plane/test/lemon_control_plane/methods/system_reload_test.exs`

These cover module/app/extension reload behavior, orchestration, lock behavior,
and response validation.