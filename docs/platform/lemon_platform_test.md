# lemon_platform_test

`lemon_platform_test` is Lemon's contract-test kit. Its ExUnit case templates run
behaviour-compliance suites against an extension implementation before it reaches a
user. The kit covers `LemonChannels.Plugin` (`PluginCase`), `LemonCore.Store.Backend`
(`BackendCase`), `LemonMemory.Provider` (`ProviderCase`), and the typed bus payloads
of `LemonCore.Events` (`EventsCase`, for extensions that publish their own events;
see [Typed Bus Events](bus-events.md)). It also ships two test helpers:
`LemonPlatformTest.EventsFixtures` (builders for valid typed payloads) and
`LemonPlatformTest.FakeLLM` (a scripted LLM stream function for `LemonAgent` loops
with no network or API key).

Gateway engines are deliberately not an extension contract. The Gateway engine
behaviour, registry, `Echo` reference implementation, and `EngineCase` were removed
when Gateway moved to its configured singleton executor. Do not use this package to
add a top-level executor or vendor CLI to Gateway.

## Choose the correct extension point

| Need | Extension point |
| --- | --- |
| Integrate another model/API | `LemonAi.Provider` |
| Add agent capability | a `CodingAgent` tool |
| Run delegated work | a native in-process subagent (`CodingAgent.Session` via the `task` tool) |
| Add a messaging channel | `LemonChannels.Plugin` |
| Add a store or memory backend | `LemonCore.Store.Backend` or `LemonMemory.Provider` |

Delegated tasks run natively in-process: a subagent is a child
`CodingAgent.Session` coordinated by `CodingAgent.Coordinator`, and there are no
vendor CLI runners (Claude Code, Codex, Kimi, OpenCode, and Pi were removed).
Top-level `engine: "lemon"` is fixed compatibility provenance, while a
delegated task retains its own task identity. Neither is a direct Gateway
executor.

Each case template's moduledoc is the reference guide for its behaviour: the `use`
line, a minimal implementation, every suite option, and optional callbacks. The
suites test contracts rather than implementation internals and avoid network calls,
message delivery, and real task runs unless an explicit probe opts in.

## Using the kit

```elixir
defmodule MyApp.RedisBackendComplianceTest do
  use LemonPlatformTest.BackendCase,
    async: true,
    backend: MyApp.RedisBackend,
    backend_opts: [url: "redis://localhost:6379/15"]
end
```

Each case needs exactly one platform app, and all are `optional: true`: `BackendCase`
and `EventsCase` need `lemon_core`, `ProviderCase` needs `lemon_memory`, `FakeLLM` needs
`lemon_ai` and `lemon_agent`, and `PluginCase` needs `lemon_channels`, which is not
published to Hex, so outside this repository it requires a path dependency on a Lemon
checkout. A missing dependency raises at compile time naming the package to add. Package
details live in `apps/lemon_platform_test/README.md`.

`test/compliance/` in this repo runs the kit against the platform's own implementations:
the ETS, JSONL and SQLite store backends, the Discord, Email and Telegram channel
adapters, the local memory provider, and the core event registry.

```bash
scripts/test path apps/lemon_platform_test/test --cover
```
