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
