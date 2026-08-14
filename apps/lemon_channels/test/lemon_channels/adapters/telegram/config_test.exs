defmodule LemonChannels.Adapters.Telegram.ConfigTest do
  @moduledoc """
  The vendor half of the Telegram gateway-config contract.

  Resolution and validation of `[gateway.telegram]` live here, byte-equivalent
  to the old `LemonCore.Config.Gateway` telegram code minus the `token` ->
  `bot_token` rename (see `LemonChannels.Adapters.Telegram.Config`). The
  generic mechanism that routes sections through registered channel modules is
  tested in `LemonCore.Config.GatewayTest` with a stub channel.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Config

  @env_vars ~w(
    TELEGRAM_BOT_TOKEN
    LEMON_GATEWAY_ENABLE_TELEGRAM
    LEMON_TELEGRAM_COMPACTION_ENABLED
    LEMON_TELEGRAM_COMPACTION_CONTEXT_WINDOW
    LEMON_TELEGRAM_COMPACTION_RESERVE_TOKENS
    LEMON_TELEGRAM_COMPACTION_TRIGGER_RATIO
  )

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
    test "uses default telegram settings" do
      resolved = Config.resolve(%{})

      assert resolved.bot_token == nil
      assert resolved.compaction.enabled == true
      assert resolved.compaction.context_window_tokens == 400_000
      assert resolved.compaction.reserve_tokens == 16_384
      assert resolved.compaction.trigger_ratio == 0.9
    end

    test "uses telegram token from config (both spellings)" do
      token = "bot123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"

      resolved = Config.resolve(%{"bot_token" => token})

      assert resolved.bot_token == token
      refute Map.has_key?(resolved, :token)

      # Legacy `token` spelling still resolves into the `bot_token` field.
      legacy = Config.resolve(%{"token" => token})
      assert legacy.bot_token == token
    end

    test "resolves telegram token from env var reference" do
      System.put_env("TELEGRAM_BOT_TOKEN", "bot987654:XYZ-ABC5678")

      resolved =
        Config.resolve(%{
          "token" => "${TELEGRAM_BOT_TOKEN}"
        })

      assert resolved.bot_token == "bot987654:XYZ-ABC5678"
    end

    test "returns nil when env var not set for token reference" do
      System.delete_env("TELEGRAM_BOT_TOKEN")

      resolved =
        Config.resolve(%{
          "token" => "${TELEGRAM_BOT_TOKEN}"
        })

      assert resolved.bot_token == nil
    end

    test "uses telegram compaction settings from config" do
      resolved =
        Config.resolve(%{
          "compaction" => %{
            "enabled" => false,
            "context_window_tokens" => 200_000,
            "reserve_tokens" => 8192,
            "trigger_ratio" => 0.8
          }
        })

      assert resolved.compaction.enabled == false
      assert resolved.compaction.context_window_tokens == 200_000
      assert resolved.compaction.reserve_tokens == 8192
      assert resolved.compaction.trigger_ratio == 0.8
    end

    test "environment variables override telegram compaction settings" do
      System.put_env("LEMON_TELEGRAM_COMPACTION_ENABLED", "false")
      System.put_env("LEMON_TELEGRAM_COMPACTION_CONTEXT_WINDOW", "200000")
      System.put_env("LEMON_TELEGRAM_COMPACTION_RESERVE_TOKENS", "8192")
      System.put_env("LEMON_TELEGRAM_COMPACTION_TRIGGER_RATIO", "0.8")

      resolved = Config.resolve(%{})

      assert resolved.compaction.enabled == false
      assert resolved.compaction.context_window_tokens == 200_000
      assert resolved.compaction.reserve_tokens == 8192
      assert resolved.compaction.trigger_ratio == 0.8
    end

    test "normalizes bot_token_secret" do
      resolved = Config.resolve(%{"bot_token_secret" => "telegram_bot_token"})
      assert resolved.bot_token_secret == "telegram_bot_token"

      blank = Config.resolve(%{"bot_token_secret" => ""})
      assert blank.bot_token_secret == nil
    end

    test "passes unknown telegram keys through atomized" do
      resolved =
        Config.resolve(%{
          "default_account_id" => "tg-work",
          "default_chat_id" => -100_123,
          "default_thread_id" => 77,
          "default_topic_id" => 88,
          "allowed_chat_ids" => [1, 2],
          "poll_interval_ms" => 500
        })

      assert resolved.default_account_id == "tg-work"
      assert resolved.default_chat_id == -100_123
      assert resolved.default_thread_id == 77
      assert resolved.default_topic_id == 88
      assert resolved.allowed_chat_ids == [1, 2]
      assert resolved.poll_interval_ms == 500
    end
  end

  describe "enabled?/1" do
    test "honours the LEMON_GATEWAY_ENABLE_TELEGRAM environment override" do
      assert Config.enabled?(false) == false

      System.put_env("LEMON_GATEWAY_ENABLE_TELEGRAM", "true")
      assert Config.enabled?(false) == true

      System.put_env("LEMON_GATEWAY_ENABLE_TELEGRAM", "false")
      assert Config.enabled?(true) == false
    end
  end

  describe "validate/2" do
    test "validates telegram bot_token format" do
      errors =
        Config.validate(%{bot_token: "123456789:ABCdefGHIjklMNOpqrsTUVwxyz"}, [])

      assert errors == []

      errors = Config.validate(%{bot_token: "invalid-token"}, [])

      assert Enum.any?(errors, &String.contains?(&1, "gateway.telegram.bot_token"))
    end

    test "accepts env var references in bot_token" do
      errors = Config.validate(%{bot_token: "${TELEGRAM_BOT_TOKEN}"}, [])
      assert errors == []
    end

    test "validates telegram compaction settings" do
      errors =
        Config.validate(
          %{
            compaction: %{
              enabled: true,
              context_window_tokens: 400_000,
              reserve_tokens: 16_384,
              trigger_ratio: 0.9
            }
          },
          []
        )

      assert errors == []

      errors =
        Config.validate(
          %{
            compaction: %{
              enabled: "yes",
              trigger_ratio: 1.5
            }
          },
          []
        )

      assert Enum.any?(errors, &String.contains?(&1, "gateway.telegram.compaction.enabled"))

      assert Enum.any?(
               errors,
               &String.contains?(&1, "gateway.telegram.compaction.trigger_ratio")
             )
    end

    test "rejects non-map sections" do
      assert Config.validate(nil, []) == ["gateway.telegram: must be a map"]
      assert Config.validate("nope", []) == ["gateway.telegram: must be a map"]
    end
  end
end
