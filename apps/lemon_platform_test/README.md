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

## In this repo

`test/compliance/` runs the kit against the platform's own implementations —
three store backends, two channel adapters, the echo engine, the local memory
provider. Two more live where the dependency direction requires them:
`XApi.ChannelAdapter` in `apps/x_api` and `CodingAgent.GatewayEngine` in
`apps/coding_agent`, each depending on this app the way a third party would.

```
mix test apps/lemon_platform_test
```
