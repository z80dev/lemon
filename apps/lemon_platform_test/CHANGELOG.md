# Changelog

All notable changes to `lemon_platform_test` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release. This package is new: if you are implementing one of Lemon's
extension behaviours, add it as a test-only dependency and the platform's own
compliance suite runs against your module.

```elixir
{:lemon_platform_test, "~> 0.1", only: :test}
```

### Added

- Four `ExUnit.CaseTemplate`s, used as `use LemonPlatformTest.PluginCase,
  adapter: MyAdapter`:

  | Behaviour | Case template |
  |---|---|
  | `LemonChannels.Plugin` | `LemonPlatformTest.PluginCase` |
  | `LemonGateway.Engine` | `LemonPlatformTest.EngineCase` |
  | `LemonCore.Store.Backend` | `LemonPlatformTest.BackendCase` |
  | `LemonMemory.Provider` | `LemonPlatformTest.ProviderCase` |

- Each template's moduledoc is the behaviour's guide: the contract in prose, a
  worked minimal implementation, the option reference, and the known gaps. If
  you read one document before implementing a Lemon behaviour, read that one.
- `LemonPlatformTest.FakeLLM` — a scripted, deterministic stand-in for an LLM
  provider that drives a real `LemonAgent` agent loop with no network or API key.
  `FakeLLM.script/2` turns a list of turns (`{:text, ...}`, `{:tool_call, ...}`,
  `{:tool_calls, ...}`, `{:refusal, ...}`, `{:error, ...}`) into the stream
  function `AgentLoopConfig` expects, emitting the provider event protocol the
  loop consumes. Previously the only implementation of that protocol was an
  unshipped test-support module, so testing an agent against Lemon meant
  reverse-engineering it.
- The platform dependencies are now `optional: true`. A consumer compiles only
  the app their case needs — a `PluginCase` no longer pulls in `lemon_gateway`,
  `exqlite` and `nostrum` as transitive test deps. Each case template guards on
  the presence of its target behaviour and raises a pointed "add this dep" error
  when it is missing (`BackendCase`/`EventsCase` → `lemon_core`, `PluginCase` →
  `lemon_channels`, `EngineCase` → `lemon_gateway`, `ProviderCase` →
  `lemon_memory`, `FakeLLM` → `lemon_ai` + `lemon_agent`).
- Registration round-trips are part of every suite. "Works standalone but is
  invisible to the platform" is the common way a third-party implementation
  fails, so the suites check that your adapter, engine or provider actually
  appears in the registry after it registers.

### Notes on safety

- **The suites are inert by default.** Nothing delivers a message, starts a run
  or opens a socket unless you pass an explicit `:deliver_probe` or
  `:run_probe`. A compliance suite that posts to your live Telegram bot would
  be worse than no suite at all.
- The suites were validated against a deliberately broken store backend to
  confirm they fail (seven failures from three injected contract violations)
  rather than passing vacuously, and against nine real implementations — two of
  them (`XApi.ChannelAdapter` and `CodingAgent.GatewayEngine`) driven from their
  own applications, which is the dependency direction a third party has.
