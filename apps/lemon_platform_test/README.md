# lemon_platform_test

Contract-test kit for Lemon's extension behaviours.

Four ExUnit case templates that run the platform's compliance suites against
*your* implementation of a Lemon behaviour:

| Behaviour | Case template |
| --- | --- |
| `LemonCore.Store.Backend` | `LemonPlatformTest.BackendCase` |
| `LemonChannels.Plugin` | `LemonPlatformTest.PluginCase` |
| `LemonGateway.Engine` | `LemonPlatformTest.EngineCase` |
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
contract in prose, a worked minimal implementation, every option the suite
takes, and the places the contract is still underspecified. Start with
`LemonPlatformTest` for the overview.

The suites test the contract, never an implementation's internals, and they are
safe by default: nothing makes a network call, delivers a message or starts a
real run unless you pass an explicit probe.

## Optional dependencies

Each case needs exactly one platform app, and they are all `optional: true`, so
you compile only the one you use — a `PluginCase` does not drag in the gateway,
SQLite and a Telegram client. Add the app your case targets alongside the kit:

| Case / tool | Add |
| --- | --- |
| `BackendCase`, `EventsCase` | `{:lemon_core, "~> 0.1", only: :test}` |
| `PluginCase` | `{:lemon_channels, "~> 0.1", only: :test}` |
| `EngineCase` | `{:lemon_gateway, "~> 0.1", only: :test}` |
| `ProviderCase` | `{:lemon_memory, "~> 0.1", only: :test}` |
| `FakeLLM` | `{:lemon_ai, "~> 0.1", only: :test}` and `{:lemon_agent, "~> 0.1", only: :test}` |

Forget one and the case raises at compile time naming the package to add.

## FakeLLM: drive an agent loop without a provider

`LemonPlatformTest.FakeLLM` is a scripted stand-in for an LLM. It turns a list of
turns into the stream function `LemonAgent` expects, emitting the same event
protocol a real provider adapter does — so you can test what your agent *does*
with a tool call or a refusal, with no network and no API key:

```elixir
stream_fn =
  LemonPlatformTest.FakeLLM.script([
    {:tool_call, "get_weather", %{"city" => "Paris"}},
    {:text, "It is sunny in Paris."}
  ])

config = %LemonAgent.Types.AgentLoopConfig{stream_fn: stream_fn, ...}
```

Steps cover a plain answer, one or many tool calls, a model refusal and a
transport error. See the `LemonPlatformTest.FakeLLM` moduledoc for the full
worked example.

## In this repo

`test/compliance/` runs the kit against the platform's own implementations —
three store backends, two channel adapters, the echo engine, the local memory
provider. Two more live where the dependency direction requires them:
`XApi.ChannelAdapter` in `apps/x_api` and `CodingAgent.GatewayEngine` in
`apps/coding_agent`, each depending on this app the way a third party would.

```
mix test apps/lemon_platform_test
```
