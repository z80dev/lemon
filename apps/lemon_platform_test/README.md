# lemon_platform_test

Contract-test kit for Lemon's extension behaviours.

Four ExUnit case templates run the platform's compliance suites against *your*
implementation of a Lemon behaviour:

| Behaviour | Case template |
| --- | --- |
| `LemonCore.Store.Backend` | `LemonPlatformTest.BackendCase` |
| `LemonChannels.Plugin` | `LemonPlatformTest.PluginCase` |
| `LemonCore.SubagentRunner` | `LemonPlatformTest.SubagentRunnerCase` |
| `LemonMemory.Provider` | `LemonPlatformTest.ProviderCase` |

```elixir
defmodule MyApp.RedisBackendComplianceTest do
  use LemonPlatformTest.BackendCase,
    async: true,
    backend: MyApp.RedisBackend,
    backend_opts: [url: "redis://localhost:6379/15"]
end
```

Each case template's moduledoc is the reference guide for its behaviour: the
contract in prose, a worked minimal implementation, every option the suite takes,
and the places the contract is still underspecified. Start with
`LemonPlatformTest` for the overview.

The suites test a contract, never an implementation's internals, and are safe by
default: nothing makes a network call, delivers a message, or starts a real task
unless you pass an explicit probe.

## Gateway executor cutover

Gateway no longer accepts extension-provided engines. Its engine behaviour, registry,
`Echo` reference implementation, and `EngineCase` were intentionally removed when
Gateway became the runtime for its configured singleton executor. This kit therefore
does not provide a Gateway executor compliance case.

Use the boundary that matches the desired integration:

| Need | Use |
| --- | --- |
| Integrate a model/API | a `LemonAi.Provider` |
| Add in-process agent capability | a `CodingAgent` tool |
| Delegate external or vendor CLI work | `LemonCore.SubagentRunner` |

Claude Code, Codex, Kimi, OpenCode, and Pi remain optional delegated task runners in
`lemon_cli_runners`. `LemonCore.ResumeToken` and `LemonCore.ResumeFormats` retain
native and task-runner resume support. Top-level `engine: "lemon"` is fixed
compatibility provenance, while a delegated task retains its actual `task.engine`
runner ID; neither is a Gateway routing choice. Vendor runner configuration under
`[runtime.cli.<vendor>]` only configures a delegated task subprocess; it never
selects a top-level Gateway executor.

## Optional dependencies

Each case needs exactly one platform app, and they are all `optional: true`, so you
compile only the one you use — a `PluginCase` does not drag in the gateway, SQLite,
and a Telegram client. Add the app your case targets alongside the kit:

| Case / tool | Add |
| --- | --- |
| `BackendCase`, `EventsCase`, `SubagentRunnerCase` | `{:lemon_core, "~> 0.1", only: :test}` |
| `PluginCase` | `{:lemon_channels, "~> 0.1", only: :test}` |
| `ProviderCase` | `{:lemon_memory, "~> 0.1", only: :test}` |
| `FakeLLM` | `{:lemon_ai, "~> 0.1", only: :test}` and `{:lemon_agent, "~> 0.1", only: :test}` |

Forget one and the case raises at compile time naming the package to add.

## FakeLLM: drive an agent loop without a provider

`LemonPlatformTest.FakeLLM` is a scripted stand-in for an LLM. It turns a list of
turns into the stream function `LemonAgent` expects, emitting the same event protocol
a real provider adapter does — so you can test what your agent *does* with a tool call
or a refusal, with no network and no API key:

```elixir
stream_fn =
  LemonPlatformTest.FakeLLM.script([
    {:tool_call, "get_weather", %{"city" => "Paris"}},
    {:text, "It is sunny in Paris."}
  ])

config = %LemonAgent.Types.AgentLoopConfig{stream_fn: stream_fn, ...}
```

Steps cover a plain answer, one or many tool calls, a model refusal, and a transport
error. See the `LemonPlatformTest.FakeLLM` moduledoc for the full worked example.

## In this repo

`test/compliance/` runs the kit against the platform's own implementations — three
store backends, two channel adapters, and the local memory provider. Additional
compliance suites live with their implementations where dependency direction requires
it, including `XApi.ChannelAdapter` in `apps/x_api` and vendor
`LemonCore.SubagentRunner` implementations in `apps/lemon_cli_runners`.

```bash
mix test apps/lemon_platform_test
```
