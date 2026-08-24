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

- `LemonPlatformTest.EventsFixtures.channel_delivery/1` — builder for the new
  `LemonCore.Events.ChannelDelivery` payload (`:channel_delivery` on the
  `channels` topic); `EventsCase` covers the module through the registry like
  every other typed payload.
- Four `ExUnit.CaseTemplate`s, used as `use LemonPlatformTest.PluginCase,
  adapter: MyAdapter`:

  | Behaviour | Case template |
  |---|---|
  | `LemonChannels.Plugin` | `LemonPlatformTest.PluginCase` |
  | `LemonCore.SubagentRunner` | `LemonPlatformTest.SubagentRunnerCase` |
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
  the app their case needs. Each case template guards on the presence of its
  target behaviour and raises a pointed "add this dep" error when it is missing
  (`BackendCase`/`EventsCase` → `lemon_core`, `PluginCase` →
  `lemon_channels`, `SubagentRunnerCase` → `lemon_core`, `ProviderCase` →
  `lemon_memory`, `FakeLLM` → `lemon_ai` + `lemon_agent`).
- Registration round-trips are part of applicable suites so adapters, runners,
  and providers cannot work standalone while remaining invisible to the
  platform.
- `LemonPlatformTest.EngineCase` was removed with the public custom top-level
  engine contract. There is no replacement top-level executor extension kit.
- `LemonPlatformTest.EventsCase` covers `LemonCore.Events` payload modules —
  registry completeness, `from_map/1` round-trip and string-key acceptance,
  strict `new/1`, `Introspection` parity between the struct and the map it
  replaced, JSON encodability, and `Bus.broadcast_event/4` envelope discipline
  under both bus backends. It also asserts that a payload module does **not**
  implement `Access` (`LemonPlatformTest.EventsCase.implements_access?/1`):
  payloads are pattern-matched or read by field, and a consumer holding one that
  may still be a legacy map coerces it with `LemonCore.Events.coerce/2`. Reading
  a payload by key is what lets a field rename ship as a silent `nil`.

### Notes on safety

- **The suites are inert by default.** Nothing delivers a message, starts a run
  or opens a socket unless you pass an explicit `:deliver_probe` or
  `:run_probe`. A compliance suite that posts to your live Telegram bot would
  be worse than no suite at all.
- The suites were validated against deliberately broken implementations to
  confirm they fail rather than passing vacuously, and against real
  implementations such as `XApi.ChannelAdapter` from their owning applications,
  which is the dependency direction a third party has.
