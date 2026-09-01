# Failure Handling

How code in the umbrella is allowed to catch an exception. This is the
deliverable of Phase 6 of the
[September 2026 architecture review](../architecture/review-2026-09.md),
as revised in its section 7: the count of `rescue` clauses is a signal, not
a target, and the property that matters is that a failure is never silent.

The rule, in three lines. Code may catch an exception only if all three hold:

1. **The failure is observable.** It is logged with its stacktrace, or
   returned to a caller that will log or act on it. A `rescue` whose only
   effect is to substitute a default value is a silent failure.
2. **The caller receives an accurate outcome.** `:ok` means the work was
   done. A caught failure answers `{:error, reason}`, `nil`, `false` or an
   unchanged state, whichever the function's contract makes true.
3. **Continuing leaves valid state.** The process, its state and the
   stores it touched are in a state the next call can work from.

Ordinary functions do not rescue. A bug in a pure helper (a parse, a lookup,
a rendering) should reach the nearest boundary with its stacktrace, where
one clause reports it. Wrapping a call that cannot raise (`LemonCore.Store`,
the bridges, `Introspection.record/3`, everything that already answers
`{:error, reason}`) is dead code and is removed when found.

## Boundaries

A boundary is a place where a failure must not propagate further because
what is above it cannot do anything useful with it. The boundaries in this
codebase, and the outcome each one owes its caller:

| Boundary | Example | Outcome on failure |
| --- | --- | --- |
| Adapter inbound handler | `handle_info` for a Discord or Telegram event, the Telegram pipeline dispatch | Log at `:warning` with the stacktrace; keep the adapter's state; answer the user when there is an interaction to answer |
| Run event handling | `LemonRouter.RunProcess` timers and completion side effects | Log at `:error` with the stacktrace; keep the run alive; the run's terminal outcome is still emitted |
| Outbound API call | Nostrum, the Telegram API, a webhook | Log at `:warning`; return `{:error, exception}` so the caller knows nothing was sent |
| Async task body | `Task.start`, `Task.Supervisor.start_child` bodies | Log with the stacktrace; the task's result is its own |
| Bridge call | `LemonCore.RouterBridge`, `LemonCore.EventBridge`, `LemonCore.EngineInfoBridge` | Log at `:error`; answer `{:error, exception}` (see [Reliability Contracts](reliability-contracts.md)) |
| Tool and plugin execution | `CodingAgent` tool calls, channel plugins, cron job bodies | Catch anything, report it, and return the failure as the tool's result |
| Owner-supplied functions | `LemonCore.Store.update/5` running a caller's function | Log with the stacktrace; answer `{:error, {:update_failed, exception}}`; write nothing |

Everything not in this table is not a boundary.

## Reporting

`LemonCore.Failure.log/4` is how a boundary reports:

```elixir
def handle_info({:media_group_flush, group_key, ref}, state) do
  {:noreply, dispatch_transport_event({:media_group_flush, group_key, ref}, state)}
rescue
  exception ->
    Failure.log("telegram media group flush", exception, __STACKTRACE__)
    {:noreply, state}
end
```

It logs `<what> raised: <exception and stacktrace>` at `:warning` (or the
`level:` given) with `crash_reason` metadata, the key log handlers and
telemetry already read for crashes. `LemonCore.Failure.log_caught/5` does
the same for a `catch kind, reason` clause. Naming the exception you expect
(`rescue ArgumentError ->`) is still preferred where you know it, because
it lets everything else through.

Messages name the attempt, not the module: "discord interaction handling",
"run watchdog timeout for run_id=...". Include the run or session key when
the boundary has one; a log line that cannot be tied to a run is much less
useful than one that can.

## What is not allowed

- `rescue _ -> default` in a helper that a boundary already covers. Remove
  it; the boundary reports with a stacktrace and the helper's bug surfaces.
- A rescue that answers `:ok` for work that did not happen. Answer
  `{:error, exception}` or the function's failure value.
- Catching to keep a process alive when the process cannot continue
  correctly. Let it crash; the supervisor restarts it and logs the reason.
- `Code.ensure_loaded?/1` or `function_exported?/3` around a call to a
  module the application depends on at compile time. It is not a failure
  guard, it is a way to skip the call silently when the name is wrong.

## How this is kept true

- `mix lemon.quality` ratchets `silent_rescues`, the number of `rescue`
  clauses whose first clause discards the exception (`rescue` followed by
  `_ ->`), beside the older `rescue_clauses` count. Both can only fall.
- The transports and the router run path were reworked to this policy in
  Phase 6 (`LemonChannels.Adapters.Discord.Transport`,
  `LemonChannels.Adapters.Telegram.Transport`, `LemonRouter.SurfaceManager`,
  `LemonRouter.RunProcess` and its `CompactionTrigger`). The remaining
  silent rescues are concentrated in the Telegram transport's submodules and
  the control-plane method modules; take them when those files are next
  touched, module by module, and lower the ratchet each time.
