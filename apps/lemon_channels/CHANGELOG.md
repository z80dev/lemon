# Changelog

All notable changes to `lemon_channels` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
releases follow [Semantic Versioning](https://semver.org/) from `0.1.0` onward.

## [Unreleased]

First release as a standalone package. `LemonChannels.Plugin` is the platform's
most third-party-facing extension point, so most of this release is about
keeping it small and honest.

### Added

- `LemonChannels.CommandCatalog` — a portable, JSON-safe source of shared slash
  command names, aliases, descriptions, argument hints, busy-state metadata,
  and semantic capability ids for channel and interactive clients. It includes
  the Hermes-compatible queue/steer/session/reasoning/status/usage/task/help
  and background/side-question vocabulary while keeping execution in the
  existing router, session, task, and control-plane owners.
- Telegram and Discord now execute the portable queue/steer aliases,
  reset/reasoning/stop compatibility names, redacted status/usage/task/help
  commands, session compaction, isolated `/bg`, and no-tools `/btw` through a
  shared channel renderer while retaining their native transport UX.
- `LemonChannels.Dispatcher` is now observable: after every dispatch it emits a
  `[:lemon, :channels, :dispatch]` telemetry event (measurements
  `%{count: 1, duration: native}`; metadata `channel_id`, `account_id`, `kind`,
  `intent_id`, `run_id`, `session_key`, `ok`) and broadcasts a typed
  `LemonCore.Events.ChannelDelivery` on the `"channels"` bus topic — carrying
  route/peer info, the intent kind, a bounded text preview, and the dispatch
  result. Emission happens after the result is known and is rescue-wrapped, so
  an observability failure can never break a real send. Tests asserting "lemon
  would have sent exactly this" subscribe to `"channels"` and match the struct.
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
- `LemonChannels.Adapters.{Telegram,Discord,Xmtp}.Config` — each adapter now
  owns its `[gateway.<id>]` config section end to end: the sub-table's
  resolution (secret indirection, `${VAR}` expansion, per-platform defaults),
  its `enable_<id>` flag, its `LEMON_*` variables and its validation rules.
  They implement the new `LemonCore.Config.Gateway.Channel` behaviour and are
  registered under `config :lemon_core, :gateway_channels`. Resolution and
  validation are unchanged in behaviour with one exception: the telegram
  section now exposes the expanded token as `bot_token` and no longer emits a
  separate `token` key — every reader already used `bot_token`, and the
  validation path is now `gateway.telegram.bot_token`.
- `LemonChannels.Adapters.ConfigHelpers` — the TOML coercions those three
  sections share (key atomization, blank-to-nil, string booleans, nil
  rejection), moved out of `LemonCore.Config.Gateway` with the sections.
- `LemonChannels.Doctor.Diagnostics`, `LemonChannels.Doctor.Readiness` and
  `LemonChannels.Doctor.Checks.Channels` — the channel config diagnostics,
  launch-gate readiness summary and doctor check, moved here from `lemon_core`.
  The first two are reached through `config :lemon_core, :doctor_runtime`
  (`channel_diagnostics:`, `channel_readiness:`); the check registers through
  `config :lemon_core, :doctor_checks`. `Diagnostics` now calls
  `LemonChannels.Registry` directly instead of resolving it through
  `RuntimeModules`, since that indirection existed only for core's benefit.
- `LemonChannels.Doctor.ProofSpec` — the per-channel smoke-proof vocabulary
  (which check names count as a channel media delivery, what evidence each
  contributes, the Discord launch gates, the channel-origin cron check names,
  and the failure/setup-error classifications). It implements
  `LemonCore.Doctor.ChannelProofs` and is registered as `channel_proofs:` under
  `:doctor_runtime`, so `lemon_core`'s proof diagnostics no longer name a
  platform.
- `mix lemon.channels` — the redacted channel launch-readiness task, moved here
  from `lemon_core`. Task name and output are unchanged.
- `LemonChannels.Env` gained the eight declarations that moved out of
  `LemonCore.Env.Declarations` with their readers:
  `LEMON_GATEWAY_ENABLE_{TELEGRAM,DISCORD,XMTP}` and the four
  `LEMON_TELEGRAM_COMPACTION_*` variables.
- `LemonChannels.Telegram.FakeAPI` — an in-process fake of
  `LemonChannels.Telegram.API` for hermetic transport testing, selectable via
  `[gateway.telegram] api_mod = "LemonChannels.Telegram.FakeAPI"` in ExUnit or
  a running release. It mirrors every function the transport calls through its
  resolved `api_mod`, queues fabricated inbound updates with real `getUpdates`
  offset semantics (`push_update/1`, `simulate_message/3`,
  `simulate_callback_query/3`), and captures every outbound API call for
  introspection (`sent/0`, `await_send/2`, `clear/0`). State lives in a lazily
  started unlinked GenServer, so no supervision-tree change is required.
  Exercised by `transport_fake_api_test.exs` and
  `scripts/live_fake_telegram_smoke.exs` in the umbrella repo.

### Changed

- The Discord and Telegram transports follow `docs/platform/failure-handling.md`:
  every remaining `rescue` reports the exception with its stacktrace through
  `LemonCore.Failure` and answers what actually happened (`{:error, exception}`
  for a send that did not go out, "Command failed." for a slash command that
  raised before answering Discord), and the blanket rescues inside helpers
  that a boundary already covers are gone, so a bug in a command handler
  reaches the log instead of a silent default. The dedupe mark is written
  with an explicit `Store.put/3` result instead of a `:ok =` match under a
  rescue.

- `LemonChannels.BindingResolver` returns `LemonCore.Binding` and reads the
  gateway config through `LemonCore.GatewayConfig`; `LemonChannels.Binding`,
  `LemonChannels.Cwd` and `LemonChannels.GatewayConfig` are removed. Adapters
  use `LemonCore.Cwd` and `LemonCore.GatewayConfig` directly.
- `LemonChannels.Telegram.KnownTargetStore` declares its table with
  `LemonCore.Store.Table` (cached), and `LemonChannels.Application`
  registers the declaration at boot instead of asking the store to mirror a
  bare table name.
- `LemonChannels.Runtime` returns the router bridge's answer unchanged
  (`:ok`, `{:error, :unavailable}` or `{:error, exception}`) and
  `session_busy?/1` answers `{:ok, boolean()} | {:error, :unavailable}`; the
  dynamic fallback to `LemonRouter.Router` and the blanket `rescue _ -> :ok`
  are gone. The Telegram, Discord and WhatsApp adapters render the outcome
  ("router unavailable") instead of assuming success.
- The goal and kanban status commands take their automation capabilities from
  `config :lemon_channels` (`goal_continuation_module`, `goal_loop_module`,
  `kanban_dispatcher_module`) instead of hardcoded module atoms; an
  unconfigured capability answers `{:error, :not_available}`.
- `LemonChannels.enqueue/1` accepts a plain map with the payload's fields, so
  callers that must not name `LemonChannels.OutboundPayload` (automation) can
  still deliver through `LemonRouter.ChannelsDelivery`.
- `lemon_channels` now depends on `lemon_ai` directly; the Discord model
  catalog calls `LemonAi.Models.list_models/0` instead of a dynamic atom.
- Channels query gateway configuration through `LemonCore.EngineInfoBridge`
  instead of constructing `LemonGateway.*` atoms at runtime.
- Capabilities are resolved through the plugin registry. An unregistered
  channel answers `nil`/`false` instead of matching a hardcoded table.
- Top-level resume selection and outbound resume-line preservation accept only
  native `lemon` tokens. Vendor resume formats remain available as delegated
  task metadata but cannot select or leak into channel conversation routing.
- The Discord and Telegram approval sinks read `:approval_requested` events by
  pattern-matching `LemonCore.Events.ApprovalRequested` and its nested
  `ApprovalPending`, instead of `payload[:approval_id] || payload["approval_id"]`
  key probing. `lemon_core` removed the `Access` shim on event payload structs,
  so key probing would have raised inside the `rescue` these functions wrap
  themselves in and silently stopped delivering approval prompts. A payload that
  still arrives as a legacy map is coerced once with
  `LemonCore.Events.coerce/2`; one that cannot be coerced is skipped with a log
  rather than mis-rendered.

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
