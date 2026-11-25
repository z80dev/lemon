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

## Privacy: what is never sent or logged

Crash reports, whether sent to Sentry or written to local logs, must not
carry prompts, answers or other conversation content. Three layers enforce
this:

1. **Crash-log filter.** `LemonCore.Application.start/2` installs
   `LemonCore.CrashLogRedaction` as the first primary `:logger` filter, ahead
   of Elixir's translator, so every handler (console, log file, Sentry) sees
   sanitized OTP reports. It rewrites `gen_server`/`gen_statem` terminate
   reports, `proc_lib` crash reports (shown when SASL reports are enabled),
   supervisor reports, `Task` terminating reports, unexpected-`handle_info`
   reports and the emulator's "Error in process" exits:
   - reasons become an exit atom, `{tag, :redacted}`, or
     `LemonCore.StatusRedaction.RedactedCrash` naming the original exception
     module (its message is dropped);
   - stacktrace arguments (e.g. function-clause arguments) become arities and
     locations keep only file/line;
   - last message, state (a `gen_statem` keeps its atom state name), message
     queues, postponed events, debug logs, client info, process dictionaries and
     child/initial-call start arguments are dropped; timers keep atom names only.
   If the filter itself raises, the event is replaced by
   `[crash report redacted]` (fail closed).
2. **`format_status/1` redaction.** Prompt-holding processes call
   `LemonCore.StatusRedaction.gen_server/2` (or `gen_statem/2`), which keeps only
   scalar identifiers (run id, session key, phase), replaces the last message
   with `:redacted`, empties the debug log and `gen_statem` event queues (timer
   names and atom timer contents are kept) and reduces exit reasons the same
   way. This also covers `:sys.get_status/1`. Processes covered:
   `CodingAgent.Session`, `CodingAgent.Executor.SessionRunner`,
   `CodingAgent.Executor.RemoteSessionRunner`, `CodingAgent.Advisor`,
   `CodingAgent.AsyncFollowups`, `CodingAgent.BackgroundRun.Worker`,
   `LemonAgent.Agent`, `LemonRouter.RunProcess`,
   `LemonRouter.StreamCoalescer`, `LemonRouter.SessionCoordinator`,
   `LemonRouter.RestartCarryover`, `LemonOmp.Session`,
   `LemonAutomation.CronManager` and `LemonHoncho.SessionManager`
   (`LemonAi.EventStream` and the other `format_status` implementations found by
   `rg "def format_status" apps` predate this and redact similarly). A new
   process that holds conversation content must add the same callback.
   Explicit exit/failure-reason log lines in the session, agent and run
   processes use `LemonCore.StatusRedaction.inspect_reason/1` instead of
   `inspect(reason)`.
3. **`before_send` scrubber.** `config/runtime.exs` sets
   `config :sentry, before_send: {LemonCore.SentryScrubber, :before_send}`
   whenever `:sentry` is present (independent of `SENTRY_DSN`, which Sentry
   also reads on its own). For every event it:
   - keeps only `pid_which_sent_last_message` and `logger_metadata.file/line`
     in `extra` — `genserver_state`, `last_message`, `crash_reason` and any
     other extra are dropped;
   - replaces the message with a fixed label (`GenServer %s terminating`
     keeps its pid parameter, everything else becomes `[redacted]`);
   - replaces every exception value with `[redacted]` (the exception type and
     stacktrace are kept), and clears stack-frame `vars`, mechanism data,
     breadcrumbs, request body/cookies/headers/query string and fingerprints
     built from inspected `GenServer.call` payloads.

Not covered: ordinary `Logger` calls that interpolate content themselves are
outside these layers, and the Sentry scrubber leaves `request.url`, tags,
user/context fields and attachments untouched (nothing in the repository sets
them today).

Regression tests: `apps/lemon_core/test/lemon_core/crash_log_redaction_test.exs`
captures real local log output for crashes with secrets in exception messages,
function-clause arguments, pending mailbox messages, `gen_statem` data/queues
and `Task` reasons; `apps/lemon_core/test/lemon_core/sentry_crash_redaction_test.exs`
loads the real `config/runtime.exs`, crashes a GenServer holding a prompt
through the configured `Sentry.LoggerHandler`, and asserts the rendered event
contains no prompt, answer or state.

## Implementation

- Dependencies: `apps/lemon_core/mix.exs` adds `{:sentry, "~> 14.0"}` and
  `{:finch, "~> 0.21"}` (Sentry's default HTTP client since v12; the built-in
  `JSON` module is used on Elixir 1.19, so no separate JSON dependency is
  needed).
- Gating and configuration: `config/runtime.exs` always sets the
  `before_send` scrubber when `:sentry` is loadable, and sets the DSN,
  environment, release and the `:lemon_core, :logger` handler entry only when
  `SENTRY_DSN` is present.
- Handler attachment: `LemonCore.Application.start/2` calls
  `Logger.add_handlers(:lemon_core)`, which is a no-op when nothing is
  configured under `:lemon_core, :logger`.
