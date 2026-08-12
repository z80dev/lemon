# Changelog

All notable changes to `lemon_channels` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release as a standalone package. `LemonChannels.Plugin` is the platform's
most third-party-facing extension point, so most of this release is about
keeping it small and honest.

### Added

- `LemonChannels.InboundHttp` — an opt-in HTTP listener (plug/bandit) for
  adapters that receive webhooks instead of polling. It is off unless
  configured; this package had no HTTP server before.
- `LemonChannels.Adapters.Email` — email as a first-class channel rather than a
  gateway transport, with both halves in one adapter: inbound webhook parsing
  into a `LemonCore.InboundMessage`, and SMTP delivery. It owns its own thread
  resolution (`ThreadStore`), because email's `References` header is a list of
  ancestors while `InboundMessage.reply_to_id` is a single id — the same way
  Telegram owns its message-id tables. It is inert unless explicitly
  configured.
- `LemonChannels.Application.register_and_start_adapter/2` — adapters in other
  packages register themselves at boot. `x_api` is the worked example.
- The `Plugin` contract is now documented in prose in the behaviour's moduledoc
  and enforced by `LemonPlatformTest.PluginCase`: id format and purity,
  `normalize_inbound/1` must not raise, `deliver/1` must not crash the caller,
  and `meta/0` should omit a key rather than invent a value for it.

### Changed

- Channels ask `lemon_core` about the gateway (through
  `LemonCore.EngineInfoBridge`) instead of building `LemonGateway.*` atoms at
  runtime. `gateway_config.ex` and `engine_registry.ex` no longer name another
  application.
- Capabilities are resolved through the plugin registry. An unregistered
  channel answers `nil`/`false` instead of matching a hardcoded table.
- Resume lines in inbound messages, and the resume line preserved when
  splitting a long outbound message, are recognised through
  `LemonCore.ResumeToken` — that is, through whatever resume formats the
  installed engines registered — plus a generic
  `<engine> resume|--resume|--session <token>` line for any engine
  `LemonCore.EngineCatalog` knows. `engine_registry.ex` and
  `telegram/truncate.ex` no longer spell out `codex`/`claude` themselves, so a
  channels runtime recognises every installed engine's syntax rather than the
  three that happened to be hardcoded. Note the trade in the other direction:
  the exact vendor spellings are no longer a floor this package provides on its
  own. Embed it without the package that wraps a given CLI and that engine's
  lines are read only in the generic shape above — which is also the only
  runtime where that engine cannot be run at all.

### Removed

- **LemonChannels.Capabilities.Registry.lookup/1 and the static capability
  table behind it.** It had zero production callers — capability queries
  already resolved through the plugin registry — and it hardcoded facts about
  channels this package does not own, including the X/Twitter adapter that now
  lives in its own repository. If you called it, register your adapter and
  publish capabilities from `meta/0`.
- The X/Twitter adapter, which moved to the `x_api` satellite package and
  registers itself. Nothing in this package mentions X any more.

### Known gaps

- `meta/0`'s flag map cannot express everything the deleted capability table
  could (attachment size limits, rich-block features, rate limits). Widening it
  to the typed capability spec is deferred until a consumer needs it.
- This package still depends on `lemon_media` for the `/media status` command,
  and `lemon_media` is not yet published. That dependency has to be resolved —
  published or inverted — before `lemon_channels` can go to hex.
