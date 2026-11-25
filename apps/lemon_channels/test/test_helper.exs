#
# In umbrella `mix test`, other apps may start `:lemon_channels`
# earlier in the same BEAM with test-specific config (e.g. Telegram enabled).
# Some lemon_channels tests assume a clean Outbox/Registry/RateLimiter state, so we
# force a restart here with a stable config baseline.
#
# Config is set via the full-replacement gateway config path used by
# LemonCore.GatewayConfig in test mode (config_test_mode: true).
#

gateway_config_key = :gateway_test_config

Application.put_env(:lemon_core, gateway_config_key, %{
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

# Case-folding tests only run on a case-insensitive filesystem.
case_probe =
  Path.join(System.tmp_dir!(), "lemon-case-probe-#{System.unique_integer([:positive])}")

File.mkdir_p!(case_probe)
File.write!(Path.join(case_probe, "Probe"), "")
case_insensitive_fs? = File.exists?(Path.join(case_probe, "PROBE"))
File.rm_rf!(case_probe)

exclude_tags =
  if case_insensitive_fs?, do: exclude_tags, else: [:case_insensitive_fs | exclude_tags]

ExUnit.start(capture_log: true, exclude: exclude_tags)

# An umbrella `mix test` runs every later app suite in this VM, and this
# callback runs after each of them too: restart everything it stops, or the
# later suites see a stopped lemon_channels.
ExUnit.after_suite(fn _ ->
  _ = Application.stop(:lemon_channels)
  _ = Application.stop(:lemon_gateway)

  Application.delete_env(:lemon_core, gateway_config_key)
  Application.delete_env(:lemon_channels, :engines)
  Application.delete_env(:lemon_channels, :adapters)

  {:ok, _} = Application.ensure_all_started(:lemon_gateway)
  {:ok, _} = Application.ensure_all_started(:lemon_channels)
end)
