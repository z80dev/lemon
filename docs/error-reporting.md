# Error Reporting

Lemon ships an optional [Sentry](https://sentry.io) sink for unhandled
exceptions and process crashes, wired through `lemon_core` (present in every
release profile).

## Enabling it

Set `SENTRY_DSN` in the environment before boot:

```bash
export SENTRY_DSN="https://<public_key>@<org>.ingest.sentry.io/<project_id>"
```

Optional companions:

- `LEMON_ENV` (or `SENTRY_ENVIRONMENT`) — reported as the Sentry
  `environment_name`. Falls back to the Mix environment (e.g. `"prod"`) if
  neither is set.

When `SENTRY_DSN` is absent or blank, nothing is configured: the `:sentry`
application still boots (it's an optional dependency of `lemon_core`, and the
release profiles include it), but with `dsn: nil`, which is Sentry's own
documented "disabled" mode — no events are sent and no logger handler is
attached. This is the default, and is what CI, tests, and local development
run with.

`:sentry` and its HTTP client `:finch` are optional deps, so a host application
that depends on `lemon_core` without them still boots: `config/runtime.exs`
skips this block when `Sentry.LoggerHandler` is not loadable, and
`LemonCore.Application` drops any configured handler whose module is missing.

## What gets captured

Once enabled, a [`Sentry.LoggerHandler`](https://hexdocs.pm/sentry/Sentry.LoggerHandler.html)
is attached at `lemon_core` boot (see `LemonCore.Application.start/2`, which
calls `Logger.add_handlers(:lemon_core)`). With the handler's default
`capture_log_messages: false`, it reports **crashes** — messages whose
metadata carries an exit reason and stacktrace (unhandled exceptions,
supervisor-reported process crashes) — at `:error` level and above. Routine
`Logger.error/2` calls that aren't crashes are not forwarded, so enabling
this does not turn every logged error into a Sentry event.

The release/version tag on reported events comes from
`Application.spec(:lemon_core, :vsn)` (the `lemon_core` app version, which
tracks the umbrella's `mix.exs` version).

To capture something manually outside of a crash:

```elixir
try do
  risky_operation()
rescue
  exception -> Sentry.capture_exception(exception, stacktrace: __STACKTRACE__)
end
```

## Implementation

- Dependencies: `apps/lemon_core/mix.exs` adds `{:sentry, "~> 13.0"}` and
  `{:finch, "~> 0.21"}` (Sentry's default HTTP client since v12; the built-in
  `JSON` module is used on Elixir 1.19, so no separate JSON dependency is
  needed).
- Gating and configuration: `config/runtime.exs` sets `config :sentry, ...`
  and the `:lemon_core, :logger` handler entry only when `SENTRY_DSN` is
  present.
- Handler attachment: `LemonCore.Application.start/2` calls
  `Logger.add_handlers(:lemon_core)`, which is a no-op when nothing is
  configured under `:lemon_core, :logger`.
