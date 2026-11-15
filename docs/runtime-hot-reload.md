# Runtime Hot-Reload

Lemon supports best-effort code reload for **already-running source checkouts**.
It is a development convenience, not an OTP release upgrade or state migration.
Packaged releases must be restarted instead.

## Reload from a source checkout

After editing the same checkout that the runtime is using:

```bash
./bin/lemon reload
./bin/lemon reload --no-sessions --json
```

The source launcher compiles the checkout before invoking the CLI. The CLI sends
`system.reload_code` over the authenticated control plane with a 60-second RPC
timeout; it never starts a runtime. Start one explicitly with
`./bin/lemon daemon` if needed. See the [CLI reference](user-guide/cli.md#source-development-reload).

The method requires `admin` scope, `LEMON_CLI_LAUNCHER=source` **on the runtime**
and an interactive BEAM code server (`:code.get_mode() == :interactive`).
Running a source CLI against a packaged runtime does not enable reload.
Direct RPC callers must compile the source first: the method itself does not
compile. Its only parameter is an optional boolean `sessions` (default `true`);
unknown keys or other values are rejected.

## What the runtime does

`LemonCore.CodeReload` and the control-plane method perform these steps:

1. Discover changed **already-loaded** modules with `:code.modified_modules/0`.
   The control-plane call does not restrict this to an application or directory;
   the lower-level `reload_modified/1` API can restrict paths with `:only_under`.
2. For each module, call `:code.soft_purge/1`, then `:code.load_file/1` from the
   code path if the purge succeeds. No hard purge is used. If the previous old
   version is still in use, report the module as `inUse` rather than kill the
   process to load another version. A file-load error is reported as `failed`.
3. Unless `sessions` is `false` (`--no-sessions`), invoke the configured session
   refresher. The standard runtime wires `CodingAgent.CodeReload`, which rebuilds
   idle coding sessions' tool/extension closures. Streaming sessions are counted
   as `busy` and skipped; failed or vanished sessions are counted as `failed`.
   If no refresher is configured, the counts are zero.
4. Retry the initially in-use modules **once**, after the refresh (even when
   session refresh was disabled). Report those still in use or failing to load.

The BEAM can keep a current and an old version of a module. Calls already
executing and closures created before reload can continue using old code.
Refreshing idle sessions helps replace tool closures; it does not upgrade every
closure or process in the VM. Busy sessions are not automatically refreshed
later by this operation. Newly added modules are not in the changed-loaded
module list; interactive mode can load them on demand from the code path.

## Reading the result

Human output includes module/session counts, load failures and modules still in
use. JSON returns:

| Field | Meaning |
| --- | --- |
| `reloaded` / `reloadedCount` | Module names successfully loaded across both attempts / exact total |
| `inUse` / `inUseCount` | Module names still blocked after the retry / exact total |
| `failed` / `failedCount` | Entries containing `module` and a safe `reason` / exact total |
| `sessions` | Counts named `refreshed`, `busy` and `failed` |

Each module list is capped at 200 entries; counts remain exact. Failure reasons
are `nofile`, `badfile`, `on_load_failure`, `not_purged`, `sticky_directory`, or
the generic `load_failed`. Disabling session refresh returns zero session counts.

CLI exit code `0` means the RPC returned a completed report, **not** that every
module loaded: inspect the failure and in-use totals. Exit code `1` means the RPC
was unavailable or refused; `2` means invalid usage. Reload is not transactional:
an exception can return an unavailable error after some changes were applied.
A timeout likewise leaves the outcome unknown; inspect the runtime before
retrying.

## What still needs a restart

Restart for changes to configuration, `mix.exs`, dependencies, applications,
supervision trees or incompatible GenServer/process state shapes. This path
does not rerun application startup, rebuild supervision trees, suspend processes
or invoke their `code_change/3` callbacks. It does not apply an OTP release
upgrade, migrate live state or roll back failed changes.

The CLI recommends restarting when modules remain in use. Unrefreshed closures
and busy sessions may still execute old code even if module loading succeeded.
Use a restart when the whole runtime must consistently adopt the change.

## Extension and package APIs

`Lemon.Reload` is a separate low-level API published in `lemon_core`, not the
implementation of `system.reload_code`. Its moduledoc describes all retained
entry points and their options:

- `soft_purge_module/1,2` and `reload_extension/1,2` are used by the coding-agent
  extension loader/cache.
- `reload_module/1,2`, `reload_app/1,2` and `reload_system/0,1` retain their
  documented public package contracts; the operator CLI does not call them.

Unlike the control-plane method, these APIs perform no admin or source-launcher
check. Extension compilation runs trusted source, including arbitrary top-level
code, and loads modules before its soft-purge check; it is not an atomic preview
or a guarantee that an error left the runtime unchanged. The optional
`reload_system/1` code-change targets are caller-managed and are not an automatic
upgrade mechanism.

For extension configuration and session tooling, see [Extensions](extensions.md).