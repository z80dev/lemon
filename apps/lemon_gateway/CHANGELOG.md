# Changelog

All notable changes to `lemon_gateway` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release as a standalone package. This release is mostly about what the
gateway no longer knows: it went from an application wired to a specific coding
agent to an engine runtime anything can register with.

### Added

- `LemonGateway.EngineRegistry.register/1` — engines register themselves at
  boot instead of being named in the gateway's compiled-in engine list.
  Registration persists to `:lemon_gateway, :registered_engines`, so a
  registry restart keeps the engine, and a configured engine whose module is
  absent from the build is skipped rather than crashing the registry. This is
  how the platform stopped depending on any particular agent implementation.
- `LemonGateway.EngineRegistry.register_default/1` — the boot auto-registration
  call for packages announcing the engines they ship. It is a no-op when the
  operator explicitly configured `:lemon_gateway, :engines`: that list is a
  ceiling, and a vendor engine an operator disabled by narrowing it must not
  come back because the package happens to be in the release. The registry
  never writes the operator's `:engines` key.
- `LemonGateway.Workspace` reads `config :lemon_gateway, :workspace_dir`
  (accepting an `{module, function, args}` tuple), replacing a direct call into
  a specific agent's configuration.
- `LemonGateway.Config.replacement_config/0`, so the application that owns an
  environment key is the one that reads it.
- The engine runtime registers three capabilities — `engine_registry`,
  `transport_registry` and `gateway_config` — through
  `LemonCore.EngineInfoBridge`. Other packages ask `lemon_core` about the
  gateway instead of constructing `LemonGateway.*` atoms at runtime.

### Changed

- **`Engine.cancel/1` is now total and idempotent.** Every built-in CLI engine
  used to raise `FunctionClauseError` when handed a context it did not
  recognise; cancelling an unknown or already-finished run is now a no-op. The
  contract is written down in `LemonGateway.Engine`'s moduledoc, along with the
  steer invariant, and `LemonPlatformTest.EngineCase` turns it into tests.
- The gateway no longer writes chat state; the router is its single writer.
- CLI engines render resume tokens through `LemonCore.ResumeToken`, which reads
  the format each vendor package registered at boot. `CliAdapter` had a second
  copy of the per-vendor table; there is now one source for the syntax an engine
  prints and the syntax it parses back.
- Ingress (the HTTP webhook listener and the Twilio SMS utility) is documented
  as gateway-owned by design rather than as "legacy" awaiting migration. It is
  off by default and stays here because it needs synchronous HTTP responses,
  which the channel `Plugin` behaviour deliberately does not offer.

### Removed

- **The `droid` engine is gone**, along with its runner, subagent, schema and
  the `FACTORY_API_KEY` variable. There is no migration shim: persisted state
  that names it — a binding or webhook `default_engine`, a sticky engine
  selection, a scheduled job row, a stored resume token — no longer resolves to
  an engine, and the run fails rather than falling back. Re-point anything set
  to `droid` at another engine before upgrading.
- **The Farcaster transport is gone** (about 1.4k LOC of transport and tests,
  plus its configuration keys, validators and 6 environment variables:
  `FARCASTER_*` and `LEMON_GATEWAY_ENABLE_FARCASTER`). It was off by default
  and unused. If you were running it, pin the previous revision.
- **The email transport is gone**, replaced by `LemonChannels.Adapters.Email`
  in `lemon_channels` — email is a conversational channel, and this package no
  longer pretends otherwise. Threading state carries over untouched (same
  `:email_message_threads` / `:email_thread_state` tables), and the adapter
  still reads the TOML `[gateway]` `email` block, so an existing relay,
  sender and webhook token keep working without edits. Two changes worth
  knowing: inbound now arrives on `LemonChannels.InboundHttp` at `POST /email`
  with the token in an `x-webhook-token` header rather than on the gateway's
  own listener, and `enable_email` no longer does anything here. `gen_smtp` and
  `mail` are no longer dependencies of this package.
- The dependency on any specific coding agent. The in-process engine shim moved
  to the agent that owns it and registers itself; the edge now points from the
  agent to this package.
- **The dependency on `lemon_cli_runners`, and with it the five vendor engine
  shells** (`LemonGateway.Engines.{Claude,Codex,Kimi,Opencode,Pi}`). They now
  live in `lemon_cli_runners` as `LemonCliRunners.Engines.*` and register with
  `EngineRegistry` at that package's boot, the same way coding_agent
  contributes the `lemon` engine. The gateway no longer names any vendor; the
  only engine it ships is `Echo`, and `Engines.CliAdapter` stays here as the
  vendor-free harness. A runtime that wants the vendor engines must include
  the `lemon_cli_runners` application; ids, behaviour and configuration are
  otherwise unchanged.

### Known gaps

- Voice support is deferred and undocumented.
