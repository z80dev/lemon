defmodule LemonChannels.Adapters.Discord.ConfigTest do
  @moduledoc """
  The vendor half of the Discord gateway-config contract.

  Resolution and validation of `[gateway.discord]` live here, byte-equivalent
  to the old `LemonCore.Config.Gateway` discord code (see
  `LemonChannels.Adapters.Discord.Config`). The generic mechanism that routes
  sections through registered channel modules is tested in
  `LemonCore.Config.GatewayTest` with a stub channel.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Discord.Config

  @env_vars ~w(DISCORD_BOT_TOKEN LEMON_GATEWAY_ENABLE_DISCORD)

  setup do
    original = Map.new(@env_vars, fn key -> {key, System.get_env(key)} end)
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  describe "resolve/1" do
    test "resolves the discord section" do
      resolved =
        Config.resolve(%{
          "bot_token" => "discord-token",
          "bot_token_secret" => "discord_bot_token",
          "default_account_id" => "dc-work",
          "default_channel_id" => "123456",
          "default_thread_id" => "789",
          "allowed_guild_ids" => [1_475_727_416_549_969_980],
          "deny_unbound_channels" => false,
          "message_content_intent_enabled" => true
        })

      assert resolved.bot_token == "discord-token"
      assert resolved.bot_token_secret == "discord_bot_token"
      assert resolved.default_account_id == "dc-work"
      assert resolved.default_channel_id == "123456"
      assert resolved.default_thread_id == "789"
      assert resolved.allowed_guild_ids == [1_475_727_416_549_969_980]
      assert resolved.deny_unbound_channels == false
      assert resolved.message_content_intent_enabled == true
    end

    test "drops nil and blank values instead of passing them through" do
      resolved = Config.resolve(%{"bot_token" => "", "default_channel_id" => nil})

      refute Map.has_key?(resolved, :bot_token)
      refute Map.has_key?(resolved, :default_channel_id)

      # Integer ids survive; they are not blanked.
      resolved = Config.resolve(%{"default_channel_id" => 123, "default_thread_id" => 456})
      assert resolved.default_channel_id == 123
      assert resolved.default_thread_id == 456
    end

    test "coerces string-encoded booleans with a false default" do
      resolved = Config.resolve(%{"deny_unbound_channels" => "true"})
      assert resolved.deny_unbound_channels == true

      resolved = Config.resolve(%{"message_content_intent_enabled" => "false"})
      assert resolved.message_content_intent_enabled == false

      # The booleans always materialize, defaulting to false.
      assert Config.resolve(%{}) == %{
               deny_unbound_channels: false,
               message_content_intent_enabled: false
             }
    end

    test "passes the files section through" do
      resolved =
        Config.resolve(%{
          "files" => %{
            "enabled" => true,
            "auto_send_generated_files" => true,
            "auto_send_generated_max_files" => 2
          }
        })

      assert resolved.files["enabled"] == true
      assert resolved.files["auto_send_generated_files"] == true
      assert resolved.files["auto_send_generated_max_files"] == 2
    end

    test "uses the default section when absent" do
      assert Config.resolve(%{}) == %{
               deny_unbound_channels: false,
               message_content_intent_enabled: false
             }

      assert Config.resolve(nil) == %{
               deny_unbound_channels: false,
               message_content_intent_enabled: false
             }
    end
  end

  describe "enabled?/1" do
    test "honours the LEMON_GATEWAY_ENABLE_DISCORD environment override" do
      assert Config.enabled?(false) == false

      System.put_env("LEMON_GATEWAY_ENABLE_DISCORD", "true")
      assert Config.enabled?(false) == true

      System.put_env("LEMON_GATEWAY_ENABLE_DISCORD", "false")
      assert Config.enabled?(true) == false
    end
  end

  describe "validate/2" do
    test "validates discord bot token format" do
      errors =
        Config.validate(
          %{bot_token: "MTA5ODc2NTQzMjEwOTg3NjU0MzIx.ABC123.XYZ789abc123def456"},
          []
        )

      assert errors == []

      errors = Config.validate(%{bot_token: "invalid-token"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.discord.bot_token"))
    end

    test "accepts env var references in discord bot_token" do
      errors = Config.validate(%{bot_token: "${DISCORD_BOT_TOKEN}"}, [])
      assert errors == []
    end

    test "validates discord allowed_guild_ids" do
      errors = Config.validate(%{allowed_guild_ids: [123_456_789, 987_654_321]}, [])
      assert errors == []

      errors = Config.validate(%{allowed_guild_ids: ["123", "456"]}, [])

      assert Enum.any?(errors, &String.contains?(&1, "gateway.discord.allowed_guild_ids"))
    end

    test "validates discord allowed_channel_ids" do
      errors = Config.validate(%{allowed_channel_ids: [123_456_789]}, [])
      assert errors == []

      errors = Config.validate(%{allowed_channel_ids: "not-a-list"}, [])

      assert Enum.any?(errors, &String.contains?(&1, "gateway.discord.allowed_channel_ids"))
    end

    test "validates discord deny_unbound_channels" do
      errors = Config.validate(%{deny_unbound_channels: true}, [])
      assert errors == []

      errors = Config.validate(%{deny_unbound_channels: "yes"}, [])

      assert Enum.any?(errors, &String.contains?(&1, "gateway.discord.deny_unbound_channels"))
    end

    test "validates discord message_content_intent_enabled" do
      errors = Config.validate(%{message_content_intent_enabled: true}, [])
      assert errors == []

      errors = Config.validate(%{message_content_intent_enabled: "yes"}, [])

      assert Enum.any?(
               errors,
               &String.contains?(&1, "gateway.discord.message_content_intent_enabled")
             )
    end

    test "validates a complete discord config" do
      errors =
        Config.validate(
          %{
            bot_token: "MTA5ODc2NTQzMjEwOTg3NjU0MzIx.ABC123.XYZ789abc123def456",
            allowed_guild_ids: [123_456_789],
            allowed_channel_ids: [987_654_321],
            deny_unbound_channels: true,
            message_content_intent_enabled: true
          },
          []
        )

      assert errors == []
    end

    test "rejects non-map sections" do
      assert Config.validate(nil, []) == ["gateway.discord: must be a map"]
    end
  end
end
