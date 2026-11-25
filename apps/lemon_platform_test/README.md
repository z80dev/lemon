# lemon_platform_test

Contract-test kit for Lemon's extension behaviours.

ExUnit case templates run the platform's compliance suites against *your*
implementation of a Lemon behaviour:

| Behaviour | Case template |
| --- | --- |
| `LemonCore.Store.Backend` | `LemonPlatformTest.BackendCase` |
| `LemonMemory.Provider` | `LemonPlatformTest.ProviderCase` |
| `LemonCore.Events` payloads | `LemonPlatformTest.EventsCase` |

The lemon repository also carries `PluginCase` for channel adapters. Its target
app, `lemon_channels`, is not published to Hex, so `PluginCase` is not in the Hex
package; a path dependency on `apps/lemon_platform_test` in a lemon checkout
provides it.

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

## Store durability extensions

`BackendCase` discovers optional callbacks from `LemonCore.Store.Backend`;
extensions do not have to implement `confirm_durable/1` or `with_durability/2`.
If exported, the suite checks that confirmation preserves data and usable state,
and that a durability scope invokes its mutation once, preserves its return
value and failures, and leaves the backend usable afterward.

`with_durability/2` supplies the transaction-level barrier for Store mutations
using `durable: true`; otherwise Store writes and then calls `sync/1`.
`confirm_durable/1` confirms visible authority without an extra barrier on
transaction-durable backends, or Store falls back to `sync/1` when it is absent.
A failed durable mutation/barrier is `:outcome_unknown`, not permission to retry
automatically. `sync/1` remains the explicit drain seal. The kit cannot simulate
power loss: implementations must separately test their real durability barrier
and restoration of ordinary write settings after success and failure.

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
| Delegate bounded work to a subagent | the native `task`/`agent` tools (in-process `CodingAgent.Session`) |

Delegated tasks run as native in-process subagents; the vendor CLI task runners
(Claude Code, Codex, Kimi, OpenCode, and Pi) were removed. `LemonCore.ResumeToken`
retains native and delegated-task resume support. Top-level `engine: "lemon"` is
fixed compatibility provenance, while a delegated task retains its own task
identity; neither is a Gateway routing choice.

## Optional dependencies

Each case needs exactly one platform app, and they are all `optional: true`, so you
compile only the one you use — a `BackendCase` does not drag in SQLite and the agent
runtime. Add the app your case targets alongside the kit:

| Case / tool | Add |
| --- | --- |
| `BackendCase`, `EventsCase` | `{:lemon_core, "~> 0.3.0", only: :test}` |
| `ProviderCase` | `{:lemon_memory, "~> 0.3.0", only: :test}` |
| `FakeLLM` | `{:lemon_ai, "~> 0.3.0", only: :test}` and `{:lemon_agent, "~> 0.3.0", only: :test}` |

The published packages share one release line and each 0.x minor may break, so
require them at the same minor as `lemon_platform_test`.

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

Verbatim `AssistantMessage` steps retain their typed error details. To exercise
transient retries, give the failed step `content: []`: text, thinking or tool-call
output commits the attempt and prevents automatic replay. A failed step with
partial output instead surfaces that output and the original error.

## Shared test helpers

Add `{:lemon_platform_test, "~> 0.3.0", only: :test}` to use the helpers
under `LemonPlatformTest.Testing`:

```elixir
defmodule MyApp.ConfigTest do
  use LemonPlatformTest.Testing.Case, async: false

  test "writes a fixture", %{harness: harness} do
    file = temp_file!(harness, "fixture.txt", "test content")
    assert File.read!(file) == "test content"
  end
end
```

Add `lemon_core` on the same release line if you request Store support
with `with_store: true` (or a `with_store` tag). The kit also provides
`Testing.AsyncHelpers` for synchronization, `Testing.HermeticEnv` for
environment snapshots, and `Testing.FileServerTap` for file race tests.

## In this repo

`test/compliance/` runs the kit against the platform's own implementations — two
store backends, two channel adapters, and the local memory provider. Additional
compliance suites should live with their implementations where dependency direction
requires it. Helper self-tests also cover missing optional-dependency diagnostics
and typed nested fixture overrides.

```bash
scripts/test path apps/lemon_platform_test/test --cover
```
