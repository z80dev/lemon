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

Application.put_env(:lemon_channels, :adapters, [])

_ = Application.stop(:lemon_channels)
_ = Application.stop(:lemon_gateway)

{:ok, _} = Application.ensure_all_started(:lemon_gateway)
{:ok, _} = Application.ensure_all_started(:lemon_channels)

# Tests that shell out to Node are excluded (not skipped) on hosts without it.
exclude_tags = if System.find_executable("node"), do: [], else: [:node]

ExUnit.start(capture_log: true, exclude: exclude_tags)

# An umbrella `mix test` runs every later app suite in this VM, and this
# callback runs after each of them too: restart everything it stops, or the
# later suites see a stopped lemon_channels.
ExUnit.after_suite(fn _ ->
  _ = Application.stop(:lemon_channels)
  _ = Application.stop(:lemon_gateway)

  Application.delete_env(:lemon_gateway, gateway_config_key)
  Application.delete_env(:lemon_channels, :engines)
  Application.delete_env(:lemon_channels, :adapters)

  {:ok, _} = Application.ensure_all_started(:lemon_gateway)
  {:ok, _} = Application.ensure_all_started(:lemon_channels)
end)
