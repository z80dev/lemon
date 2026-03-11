#
# In umbrella `mix test`, other apps may start `:lemon_channels`
# earlier in the same BEAM with test-specific config (e.g. Telegram enabled).
# Some lemon_channels tests assume a clean Outbox/Registry/RateLimiter state, so we
# force a restart here with a stable config baseline.
#
# Config is set via the full-replacement gateway config path used by
# LemonCore.GatewayConfig in test mode (config_test_mode: true).
#

gateway_config_key = :"Elixir.LemonGateway.Config"

Application.put_env(:lemon_gateway, gateway_config_key, %{
  # Keep lemon_channels from auto-starting Telegram adapter during unit tests.
  enable_telegram: false,
  enable_discord: false,
  enable_xmtp: false,
  max_concurrent_runs: 1,
  default_engine: "lemon",
  # Neutralize TOML-derived Telegram defaults from local developer config.
  telegram: %{
    bot_token: nil,
    allowed_chat_ids: nil,
    deny_unbound_chats: false,
    drop_pending_updates: false,
    files: %{}
  },
  xmtp: %{},
  discord: %{bot_token: nil}
})

Application.put_env(:lemon_channels, :engines, [
  "lemon",
  "echo",
  "codex",
  "claude",
  "opencode",
  "pi",
  "kimi"
])

# Keep X adapter tests deterministic by default; specific tests can opt in.
Application.put_env(:lemon_channels, :x_api_use_secrets, false)

_ = Application.stop(:lemon_channels)
_ = Application.stop(:lemon_gateway)

{:ok, _} = Application.ensure_all_started(:lemon_gateway)
{:ok, _} = Application.ensure_all_started(:lemon_channels)

ExUnit.start()

ExUnit.after_suite(fn _ ->
  _ = Application.stop(:lemon_channels)
  _ = Application.stop(:lemon_gateway)

  Application.delete_env(:lemon_gateway, gateway_config_key)
  Application.delete_env(:lemon_channels, :engines)
  Application.delete_env(:lemon_channels, :x_api_use_secrets)
end)
