defmodule LemonCli.Setup.GatewayTest do
  use ExUnit.Case, async: true

  alias LemonCli.Setup.Gateway
  alias LemonCli.Setup.Gateway.{Discord, Telegram}

  # ──────────────────────────────────────────────────────────────────────────
  # Test helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp capture_io(overrides \\ %{}) do
    agent_ref = start_supervised!({Agent, fn -> [] end})

    io =
      %{
        info: fn msg -> Agent.update(agent_ref, &[{:info, msg} | &1]) end,
        error: fn msg -> Agent.update(agent_ref, &[{:error, msg} | &1]) end,
        prompt: fn _msg -> "" end,
        secret: fn _msg -> "" end
      }
      |> Map.merge(overrides)

    {io, fn -> Agent.get(agent_ref, &Enum.reverse/1) end}
  end

  defp messages(log) do
    Enum.map(log, fn {_type, msg} -> msg end)
  end

  defp error_messages(log) do
    log |> Enum.filter(fn {type, _} -> type == :error end) |> Enum.map(fn {_, m} -> m end)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Gateway dispatcher: non-interactive, no transport
  # ──────────────────────────────────────────────────────────────────────────

  describe "Gateway.run/2 — no transport specified" do
    test "non-interactive: lists adapters and returns :ok" do
      {io, get_log} = capture_io()
      result = Gateway.run(["--non-interactive"], io)
      log = get_log.()

      assert result == :ok
      assert Enum.any?(messages(log), &String.contains?(&1, "telegram"))
      assert Enum.any?(messages(log), &String.contains?(&1, "discord"))
      assert Enum.any?(messages(log), &String.contains?(&1, "gateway"))
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Gateway dispatcher: unknown transport
  # ──────────────────────────────────────────────────────────────────────────

  describe "Gateway.run/2 — unknown transport" do
    test "returns {:error, :unknown_transport} and prints error" do
      {io, get_log} = capture_io()
      result = Gateway.run(["--non-interactive", "--transport", "fax"], io)

      assert result == {:error, :unknown_transport}
      assert Enum.any?(error_messages(get_log.()), &String.contains?(&1, "fax"))
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Discord adapter: non-interactive setup and smoke failures
  # ──────────────────────────────────────────────────────────────────────────

  describe "Discord.run/2" do
    test "gives packaged-install guidance when encrypted secrets are not configured" do
      {io, get_log} =
        capture_io(%{
          secrets_status: fn -> %{configured: false} end
        })

      assert {:error, :secrets_not_configured} = Discord.run(["--non-interactive"], io)

      output = messages(get_log.())
      assert Enum.any?(output, &String.contains?(&1, "lemon secrets init"))
      refute Enum.any?(output, &String.contains?(&1, "mix lemon"))
    end

    test "gives packaged-install guidance for a missing non-interactive token" do
      {io, get_log} =
        capture_io(%{
          secrets_status: fn -> %{configured: true} end,
          secret_get: fn _key -> {:error, :not_found} end
        })

      assert {:error, :token_not_found} =
               Discord.run(
                 ["--non-interactive", "--default-channel-id", "123456789012345678"],
                 io
               )

      output = messages(get_log.())
      assert Enum.any?(output, &String.contains?(&1, "--token"))
      assert Enum.any?(output, &String.contains?(&1, "lemon secrets set discord_bot_token"))
      refute Enum.any?(output, &String.contains?(&1, "mix lemon"))
    end

    test "configures from non-interactive flags without persisting or printing the token" do
      token = "1234567890.abcde.12345"

      config_path =
        Path.join(System.tmp_dir!(), "lemon-discord-#{System.unique_integer([:positive])}.toml")

      on_exit(fn -> File.rm(config_path) end)

      {io, get_log} =
        capture_io(%{
          config_path: config_path,
          secrets_status: fn -> %{configured: true} end,
          secret_get: fn _key -> {:error, :not_found} end,
          secret_set: fn key, value ->
            send(self(), {:secret_set, key, value})
            {:ok, :stored}
          end,
          http_get: fn ^token -> {:ok, "lemon-bot"} end
        })

      assert :ok =
               Discord.run(
                 [
                   "--non-interactive",
                   "--token",
                   token,
                   "--default-channel-id",
                   "123456789012345678",
                   "--allowed-channel-id",
                   "234567890123456789",
                   "--skip-smoke"
                 ],
                 io
               )

      assert_receive {:secret_set, "discord_bot_token", ^token}

      config = File.read!(config_path)
      assert config =~ "enable_discord = true"
      assert config =~ ~s(bot_token_secret = "discord_bot_token")
      assert config =~ "default_channel_id = 123456789012345678"
      assert config =~ "allowed_channel_ids = [123456789012345678, 234567890123456789]"
      assert config =~ "deny_unbound_channels = true"
      refute config =~ token
      refute Enum.any?(messages(get_log.()), &String.contains?(&1, token))
    end

    test "reports an actionable unauthorized token without exposing it" do
      token = "1234567890.abcde.12345"

      {io, get_log} =
        capture_io(%{
          config_path: Path.join(System.tmp_dir!(), "unused-discord-config.toml"),
          secrets_status: fn -> %{configured: true} end,
          secret_set: fn _key, _value -> {:ok, :stored} end,
          http_get: fn ^token -> {:error, :unauthorized} end
        })

      assert {:error, :unauthorized} =
               Discord.run(
                 [
                   "--non-interactive",
                   "--token",
                   token,
                   "--default-channel-id",
                   "123456789012345678"
                 ],
                 io
               )

      errors = error_messages(get_log.())
      assert Enum.any?(errors, &String.contains?(&1, "401"))
      refute Enum.any?(messages(get_log.()), &String.contains?(&1, token))
    end

    test "reports an actionable Discord transport failure without exposing the token" do
      token = "1234567890.abcde.12345"

      {io, get_log} =
        capture_io(%{
          config_path: Path.join(System.tmp_dir!(), "unused-discord-config.toml"),
          secrets_status: fn -> %{configured: true} end,
          secret_set: fn _key, _value -> {:ok, :stored} end,
          http_get: fn ^token -> {:error, :econnrefused} end
        })

      assert {:error, :discord_unreachable} =
               Discord.run(
                 [
                   "--non-interactive",
                   "--token",
                   token,
                   "--default-channel-id",
                   "123456789012345678"
                 ],
                 io
               )

      errors = error_messages(get_log.())
      assert Enum.any?(errors, &String.contains?(&1, "Could not reach Discord API"))
      refute Enum.any?(messages(get_log.()), &String.contains?(&1, token))
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Telegram adapter: owner pairing with a stubbed Bot API
  # ──────────────────────────────────────────────────────────────────────────

  describe "Telegram.run/2" do
    @telegram_token "123456789:#{String.duplicate("A", 35)}"

    test "gives packaged-install guidance when encrypted secrets are not configured" do
      {io, get_log} = capture_io(%{secrets_status: fn -> %{configured: false} end})

      assert {:error, :secrets_not_configured} = Telegram.run(["--non-interactive"], io)

      output = messages(get_log.())
      assert Enum.any?(output, &String.contains?(&1, "lemon secrets init"))
      refute Enum.any?(output, &String.contains?(&1, "mix lemon"))
    end

    test "non-interactive setup refuses to write an unpaired config without --chat-id" do
      config_path = tmp_config_path()

      {io, get_log} =
        capture_io(%{
          config_path: config_path,
          secrets_status: fn -> %{configured: true} end,
          secret_set: fn _key, _value -> {:ok, :stored} end
        })

      args = ["--non-interactive", "--token", @telegram_token, "--skip-smoke"]
      assert {:error, :missing_chat_id} = Telegram.run(args, io)

      refute File.exists?(config_path)
      assert Enum.any?(messages(get_log.()), &String.contains?(&1, "--chat-id"))
    end

    test "non-interactive flags write a paired config without persisting the raw token" do
      config_path = tmp_config_path()

      {io, get_log} =
        capture_io(%{
          config_path: config_path,
          secrets_status: fn -> %{configured: true} end,
          secret_set: fn key, value ->
            send(self(), {:secret_set, key, value})
            {:ok, :stored}
          end,
          telegram_get_me: fn @telegram_token -> {:ok, "lemon_test_bot"} end
        })

      assert :ok =
               Telegram.run(
                 [
                   "--non-interactive",
                   "--token",
                   @telegram_token,
                   "--chat-id",
                   "4242",
                   "--chat-id",
                   "-1001234567890"
                 ],
                 io
               )

      assert_receive {:secret_set, "telegram_bot_token", @telegram_token}

      config = File.read!(config_path)
      assert config =~ "enable_telegram = true"
      assert config =~ ~s(bot_token_secret = "telegram_bot_token")
      assert config =~ "allowed_chat_ids = [4242, -1001234567890]"
      refute config =~ @telegram_token
      refute Enum.any?(messages(get_log.()), &String.contains?(&1, @telegram_token))
    end

    test "interactive pairing captures the chat that sends /start and acknowledges it" do
      config_path = tmp_config_path()
      chat_id = 987_654_321
      test_pid = self()

      Process.put(:telegram_updates, [
        [],
        [start_update(41, 555, "hello")],
        [start_update(42, chat_id, "/start")]
      ])

      {io, _get_log} =
        capture_io(%{
          config_path: config_path,
          secrets_status: fn -> %{configured: true} end,
          secret_get: fn "telegram_bot_token" -> {:error, :not_found} end,
          secret: fn _prompt -> @telegram_token end,
          secret_set: fn _key, _value -> {:ok, :stored} end,
          telegram_get_me: fn @telegram_token -> {:ok, "lemon_test_bot"} end,
          telegram_get_updates: fn @telegram_token, offset, _timeout_s ->
            send(test_pid, {:get_updates, offset})

            case Process.get(:telegram_updates, []) do
              [batch | rest] ->
                Process.put(:telegram_updates, rest)
                {:ok, batch}

              [] ->
                {:ok, []}
            end
          end
        })

      assert :ok = Telegram.run(["--pair-timeout", "5"], io)

      config = File.read!(config_path)
      assert config =~ "allowed_chat_ids = [#{chat_id}]"
      refute config =~ "555"

      # The /start update is acknowledged so a running transport never replays it.
      assert_received {:get_updates, 43}
    end

    test "pairing gives up after the bounded wait with a /whoami hint" do
      config_path = tmp_config_path()

      {io, get_log} =
        capture_io(%{
          config_path: config_path,
          secrets_status: fn -> %{configured: true} end,
          secret_get: fn _key -> {:ok, @telegram_token} end,
          telegram_get_updates: fn _token, _offset, _timeout_s ->
            Process.sleep(1_100)
            {:ok, []}
          end
        })

      assert {:error, :pairing_timeout} =
               Telegram.run(["--skip-smoke", "--pair-timeout", "1"], io)

      refute File.exists?(config_path)
      assert Enum.any?(messages(get_log.()), &String.contains?(&1, "/whoami"))
    end

    test "reports an invalid token from getMe without exposing it" do
      {io, get_log} =
        capture_io(%{
          config_path: tmp_config_path(),
          secrets_status: fn -> %{configured: true} end,
          secret_set: fn _key, _value -> {:ok, :stored} end,
          telegram_get_me: fn _token -> {:error, :unauthorized} end
        })

      assert {:error, :unauthorized} =
               Telegram.run(
                 ["--non-interactive", "--token", @telegram_token, "--chat-id", "1"],
                 io
               )

      assert Enum.any?(error_messages(get_log.()), &String.contains?(&1, "401"))
      refute Enum.any?(messages(get_log.()), &String.contains?(&1, @telegram_token))
    end
  end

  defp tmp_config_path do
    path =
      Path.join(System.tmp_dir!(), "lemon-telegram-#{System.unique_integer([:positive])}.toml")

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp start_update(update_id, chat_id, text) do
    %{
      "update_id" => update_id,
      "message" => %{
        "message_id" => update_id,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => chat_id, "username" => "owner"},
        "text" => text
      }
    }
  end
end
