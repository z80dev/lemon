# Lemon Config Reload Design

Date: 2026-02-22  
Status: Planning only (no implementation)

## 1. Objective

Design a robust runtime config reload mechanism for Lemon that handles updates from:

- Config files (`~/.lemon/config.toml`, `<cwd>/.lemon/config.toml`)
- Environment variables / dotenv-managed env
- Secrets store (`LemonCore.Secrets` / `LemonCore.Store`)

The mechanism must detect changes, safely reload config, and propagate updates to long-running processes without requiring full app restarts where avoidable.

## 2. Current State in `~/dev/lemon`

### 2.1 Canonical config and cache

- Canonical config is loaded by `LemonCore.Config` from global + project TOML and then env overrides (`apps/lemon_core/lib/lemon_core/config.ex:195`, `apps/lemon_core/lib/lemon_core/config.ex:205`, `apps/lemon_core/lib/lemon_core/config.ex:916`).
- `LemonCore.ConfigCache` already provides ETS caching and file fingerprint checks (`mtime` + `size`) with explicit reload/invalidate APIs (`apps/lemon_core/lib/lemon_core/config_cache.ex:22`, `apps/lemon_core/lib/lemon_core/config_cache.ex:89`, `apps/lemon_core/lib/lemon_core/config_cache.ex:150`).
- `config/test.exs` sets `mtime_check_interval_ms: 0` so tests always re-stat files (`config/test.exs:23`).

### 2.2 Environment loading

- Dotenv is loaded once at startup via scripts (`bin/lemon-gateway:196`, `bin/lemon-gateway:199`, `bin/lemon-control-plane:205`).
- `LemonCore.Dotenv` currently supports one-shot load (`apps/lemon_core/lib/lemon_core/dotenv.ex:20`, `apps/lemon_core/lib/lemon_core/dotenv.ex:54`).

### 2.3 Secrets

- `LemonCore.Secrets` supports `set/get/resolve/delete/list/status` (`apps/lemon_core/lib/lemon_core/secrets.ex:38`, `apps/lemon_core/lib/lemon_core/secrets.ex:92`, `apps/lemon_core/lib/lemon_core/secrets.ex:127`).
- No built-in change notification is emitted when secrets are updated.

### 2.4 Processes impacted by reload

- `LemonGateway.Config` loads config at init and serves it by calls; no reload API today (`apps/lemon_gateway/lib/lemon_gateway/config.ex:68`).
- `LemonGateway.Scheduler` reads `max_concurrent_runs` at init and keeps it in state (`apps/lemon_gateway/lib/lemon_gateway/scheduler.ex:62`).
- `LemonGateway.TransportSupervisor` builds children once in `init` (`apps/lemon_gateway/lib/lemon_gateway/transport_supervisor.ex:17`).
- `LemonChannels.Application` registers/starts adapters at startup only (`apps/lemon_channels/lib/lemon_channels/application.ex:30`, `apps/lemon_channels/lib/lemon_channels/application.ex:38`).
- `LemonRouter.AgentProfiles` already has a reload path (`apps/lemon_router/lib/lemon_router/agent_profiles.ex:45`).

### 2.5 Control-plane write paths

- `config.set` / `config.patch` write to `:system_config` store but do not trigger runtime reload (`apps/lemon_control_plane/lib/lemon_control_plane/methods/config_set.ex:31`, `apps/lemon_control_plane/lib/lemon_control_plane/methods/config_patch.ex:27`).
- `secrets.set` / `secrets.delete` call `LemonCore.Secrets` but do not trigger runtime propagation (`apps/lemon_control_plane/lib/lemon_control_plane/methods/secrets_set.ex:34`, `apps/lemon_control_plane/lib/lemon_control_plane/methods/secrets_delete.ex:25`).

### 2.6 Existing docs reflect restart requirement

- `docs/config.md` explicitly says gateway config changes currently require restart (`docs/config.md:308`).
- `LemonCore.Config` README lists config reloading as future work (`apps/lemon_core/lib/lemon_core/config/README.md:257`).

## 3. External Runtime/BEAM Constraints (Research)

These constraints drive the design:

- Build-time config in `config/*.exs` is compile-time and changing it usually requires recompilation (`Mix` docs, "Build-time configuration"):  
  https://hexdocs.pm/mix/main/Mix.html#module-build-time-configuration
- `Application.compile_env/*` is compile-time and checked against runtime app env; not a hot-reload path for runtime updates:  
  https://hexdocs.pm/elixir/main/Application.html#compile_env/3
- `runtime.exs` / config providers are evaluated at boot in releases, not continuously during runtime:  
  https://hexdocs.pm/elixir/main/config-and-releases.html  
  https://hexdocs.pm/elixir/main/Config.Provider.html
- OTP warns `application:set_env` does not update process state automatically; application code must handle the change:  
  https://www.erlang.org/doc/apps/kernel/application.html#set_env-3
- Native file watching is commonly implemented via `file_system` (with platform backends and polling fallback):  
  https://hexdocs.pm/file_system/readme.html

Design inference from the above: Lemon should treat runtime reload as an explicit application-level workflow (detect -> load -> apply -> notify), not as implicit magic from changing app env.

## 4. Recommended Architecture

## 4.1 Core idea

Introduce a central orchestrator in `lemon_core`:

- `LemonCore.ConfigReloader` (GenServer)

Responsibilities:

- Detect change triggers (watcher/poll/manual)
- Reload sources in a safe order
- Compute a redacted diff
- Broadcast a typed runtime event on `LemonCore.Bus`
- Track status/last error/last successful snapshot

Decouple application-specific updates via subscribers in each app (gateway/router/channels), instead of hard-coupling `lemon_core` to app internals.

## 4.2 Change detection strategy

Use a hybrid model (recommended):

- File watcher (primary) for low-latency local updates
- Polling fallback (secondary) for missed events/platform gaps
- Manual trigger (always available) for operator control

### 4.2.1 Files

Watch:

- `~/.lemon/config.toml`
- `<cwd>/.lemon/config.toml` (default runtime cwd)
- `<dotenv_dir>/.env` (from `LEMON_DOTENV_DIR` or cwd)

Details:

- Debounce burst events (e.g. 250-500ms)
- Verify with fingerprint (`mtime`, `size`) before reloading
- Keep periodic fallback poll (e.g. every 5s)

### 4.2.2 Env vars

Reality constraint:

- External OS/shell env changes are not directly observable by a running VM process.

Therefore:

- Treat `.env` as the practical runtime env source for automatic detection (watch/poll)
- Support manual reload for in-VM env updates (`System.put_env` paths)
- Document that host-level env changes usually require restart/redeploy unless pushed into VM by an explicit mechanism

### 4.2.3 Secrets

Detect via two channels:

- Event-driven: emit local notification on `LemonCore.Secrets.set/delete`
- Periodic digest check (e.g. every 10s) to catch out-of-band store updates

Digest input should be metadata-only:

- `{owner, name, updated_at, expires_at, version}`

No secret values are hashed/logged/broadcast.

### 4.2.4 Manual triggers

Add explicit reload entry points:

- Runtime API (`LemonCore.ConfigReloader.reload/1`)
- Control-plane method (`config.reload`)
- Optional CLI task (e.g. `mix lemon.config.reload`)

## 4.3 Reload pipeline

For each trigger:

1. Acquire a reload lock (serialize reloads).
2. Determine candidate changed sources (`:files`, `:env`, `:secrets`).
3. If env source changed and dotenv is enabled, reload `.env` first.
4. Reload canonical config (`LemonCore.Config.reload(cwd, validate: true)`).
5. Compute redacted config diff vs previous snapshot.
6. Persist new snapshot + source digests in reloader state.
7. Broadcast `%LemonCore.Event{type: :config_reloaded, ...}` on topic `"system"`.
8. If any step fails, keep last good snapshot and emit `:config_reload_failed`.

Failure rule: never replace active runtime snapshot with an invalid reload.

## 4.4 Propagation model to running processes

Use PubSub fanout:

- `LemonCore.ConfigReloader` emits events on `LemonCore.Bus` topic `"system"`
- Each app adds a small subscriber that applies local updates

Recommended subscribers:

- `LemonGateway.ConfigSubscriber`
- `LemonRouter.ConfigSubscriber`
- `LemonChannels.ConfigSubscriber`

### 4.4.1 Component action matrix

- `LemonGateway.Config`: add `reload/0` to atomically refresh state from `ConfigLoader`.
- `LemonGateway.Scheduler`: add `update_max_concurrent_runs/1` callback/cast.
- `LemonGateway.TransportSupervisor`: add reconcile API to start newly-enabled transports and stop disabled ones.
- `LemonChannels`: add adapter reconcile manager for enable/disable transitions.
- `LemonRouter.AgentProfiles`: call existing `reload/0`.
- Components that already read config per-call can remain unchanged.

### 4.4.2 Restart-required vs hot-updatable

Hot-updatable:

- Processes that read from `LemonGateway.Config.get/1` on each operation
- Agent profiles (already reloadable)

Likely restart/reconcile required:

- Transport processes initialized with tokens/connection params
- Supervisors that build static child lists at init
- Services bound to ports from app env (health/voice server children)

Rule of thumb:

- If config is captured in `init/1`, add explicit reconfigure callback or perform controlled child restart.

## 4.5 Public API (clean interface)

Proposed core API:

```elixir
defmodule LemonCore.ConfigReloader do
  @type source :: :files | :env | :secrets

  @spec reload(keyword()) ::
          {:ok,
           %{
             reload_id: String.t(),
             changed_sources: [source()],
             changed_paths: [String.t()],
             applied_at_ms: non_neg_integer(),
             actions: [map()]
           }}
          | {:error, term()}

  @spec reload_async(keyword()) :: :ok
  @spec status() :: map()
  @spec watch_paths() :: [String.t()]
end
```

Suggested options:

- `:sources` (default `[:files, :env, :secrets]`)
- `:force` (ignore unchanged digest check)
- `:reason` (`:watcher | :poll | :manual | :secrets_event`)
- `:cwd`
- `:validate` (default true)

## 4.6 Control-plane interface changes

Add method:

- `config.reload`

Parameters:

- `sources` optional list (`files|env|secrets`)
- `force` optional bool
- `reason` optional string

Returns:

- reload result summary (`reloadId`, `changedSources`, `actions`, `warnings`)

Update:

- `Methods.Registry` built-ins
- `Protocol.Schemas`
- (Optional) EventBridge mapping for `config.reloaded` / `config.reload.failed` WS events

## 4.7 Supervision tree changes

### 4.7.1 `lemon_core`

Current children (`apps/lemon_core/lib/lemon_core/application.ex:42`) should be extended with:

- `LemonCore.ConfigReloader`
- (Optional) watcher child under reloader if using `FileSystem`

Order recommendation:

- Keep `ConfigCache` and `Store` before `ConfigReloader`.

### 4.7.2 `lemon_gateway`

Add `LemonGateway.ConfigSubscriber` to app children (`apps/lemon_gateway/lib/lemon_gateway/application.ex:13`).

### 4.7.3 `lemon_router`

Add `LemonRouter.ConfigSubscriber` near `AgentProfiles` child (`apps/lemon_router/lib/lemon_router/application.ex:11`).

### 4.7.4 `lemon_channels`

Add `LemonChannels.ConfigSubscriber` and adapter reconcile manager (`apps/lemon_channels/lib/lemon_channels/application.ex:8`).

## 5. Source-specific handling details

## 5.1 Config files

- Reuse existing `LemonCore.Config.reload/2` + `ConfigCache.reload/2` path.
- Keep file fingerprint checks and no-op fast path.
- Reload should include validation warnings but remain non-fatal unless parse/load fails.

## 5.2 Env / dotenv

Improve dotenv behavior for reload safety:

- Track keys loaded from `.env` by the reloader
- On subsequent reloads, remove stale previously-managed keys that disappeared from file (authoritative mode)
- Keep default behavior opt-in to avoid breaking existing assumptions

Recommended config:

- `:dotenv_mode` -> `:preserve` (default) or `:authoritative`

## 5.3 Secrets

- Emit local event on set/delete
- Trigger targeted reload with source `:secrets`
- Secret diffs should contain names/metadata only, never values
- Map known secret-dependent components to local reconcile/restart actions

## 6. Observability and safety

Emit telemetry:

- `[:lemon, :config, :reload, :start]`
- `[:lemon, :config, :reload, :stop]`
- `[:lemon, :config, :reload, :exception]`
- `[:lemon, :config, :change, :detected]`

Include metadata:

- `reload_id`, `reason`, `sources`, `duration_ms`, `changed_count`, `actions_count`

Logging:

- Log changed keys/paths only
- Redact any field containing `token`, `secret`, `api_key`, `password`

## 7. Testing Plan

## 7.1 Unit tests

- Change detection and debounce logic
- Source digest comparisons
- Dotenv key tracking (including key removal)
- Redaction and diff generation
- Reload lock serialization

## 7.2 Integration tests

- Edit TOML -> confirm event + gateway config refresh
- Edit `.env` -> confirm env override path refresh
- `secrets.set/delete` -> confirm propagation event and component update
- Scheduler max concurrency updates without restart
- Transport/adapters reconcile on enable/disable toggles

## 7.3 Failure-path tests

- Invalid TOML parse errors keep last good config
- Validation warnings do not crash reloader
- Subscriber failure isolation (one app fails to apply; others continue)

## 8. Rollout Plan

Phase 1 (low risk):

- `LemonCore.ConfigReloader` with manual API only
- Event broadcast + status
- `config.reload` control-plane method

Phase 2:

- File watcher + polling fallback for TOML and `.env`
- Gateway/router/channels subscribers
- Scheduler and basic transport reconcile

Phase 3:

- Secrets event hooks + digest poll
- Extended reconcile matrix for transport-specific restarts
- WS event mapping for config reload notifications

Phase 4:

- Optional advanced features (authoritative dotenv mode default, SIGHUP hook, richer diff reporting)

## 9. Key Tradeoffs

- Event-driven decoupling vs direct module calls:
  - Choose event-driven to avoid cross-app compile coupling and keep `lemon_core` reusable.
- Immediate watcher-only vs watcher+poll:
  - Choose hybrid for reliability across OS/filesystem edge cases.
- Full app-env hot mutation vs scoped runtime config:
  - Choose scoped runtime config + explicit process reconfigure/restart hooks for correctness.

## 10. Out of Scope (for this design)

- General hot-reload of all `Application.get_env` usage across all umbrella apps
- Mid-flight reevaluation of `runtime.exs` / config providers as a built-in mechanism
- Automatic propagation of external host env changes without an explicit runtime bridge

## 11. References

- Elixir config + releases: https://hexdocs.pm/elixir/main/config-and-releases.html
- Mix build-time config caveats: https://hexdocs.pm/mix/main/Mix.html#module-build-time-configuration
- `Application.compile_env/*`: https://hexdocs.pm/elixir/main/Application.html#compile_env/3
- Config providers: https://hexdocs.pm/elixir/main/Config.Provider.html
- Erlang `application:set_env` caveats: https://www.erlang.org/doc/apps/kernel/application.html#set_env-3
- `file_system` watcher behavior: https://hexdocs.pm/file_system/readme.html

