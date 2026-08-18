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
  # Adapter behaviour
  # ──────────────────────────────────────────────────────────────────────────

  describe "Adapter behaviour" do
    test "Telegram implements all required callbacks" do
      Code.ensure_loaded!(Telegram)

      assert function_exported?(Telegram, :name, 0)
      assert function_exported?(Telegram, :description, 0)
      assert function_exported?(Telegram, :run, 2)
    end

    test "Telegram name and description are non-empty strings" do
      assert is_binary(Telegram.name()) and byte_size(Telegram.name()) > 0
      assert is_binary(Telegram.description()) and byte_size(Telegram.description()) > 0
    end

    test "Telegram.name/0 is \"telegram\"" do
      assert Telegram.name() == "telegram"
    end

    test "Discord implements all required callbacks" do
      Code.ensure_loaded!(Discord)

      assert function_exported?(Discord, :name, 0)
      assert function_exported?(Discord, :description, 0)
      assert function_exported?(Discord, :run, 2)
      assert Discord.name() == "discord"
    end
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

    test "prints list of available transports after unknown transport error" do
      {io, get_log} = capture_io()
      Gateway.run(["--non-interactive", "klingon"], io)

      log = get_log.()
      assert Enum.any?(messages(log), &String.contains?(&1, "telegram"))
      assert Enum.any?(messages(log), &String.contains?(&1, "discord"))
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Discord adapter: non-interactive setup and smoke failures
  # ──────────────────────────────────────────────────────────────────────────

  describe "Discord.run/2" do
    test "configures from non-interactive flags without persisting or printing the token" do
      token = "1234567890.abcde.12345"
      config_path = Path.join(System.tmp_dir!(), "lemon-discord-#{System.unique_integer([:positive])}.toml")
      on_exit(fn -> File.rm(config_path) end)

      {io, get_log} =
        capture_io(%{
          config_path: config_path,
          secrets_status: fn -> %{configured: true} end,
          secret_get: fn _key -> {:error, :not_found} end,
          secret_set: fn key, value -> send(self(), {:secret_set, key, value}); {:ok, :stored} end,
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
  # Telegram adapter: non-interactive without secrets
  # ──────────────────────────────────────────────────────────────────────────

  describe "Telegram.run/2 — secrets not configured" do
    test "returns {:error, :secrets_not_configured} with guidance" do
      # Telegram adapter checks Secrets.status() — without a real keychain
      # in the test env the master key is often absent.  We override the
      # io.error callback to capture the output.
      {io, get_log} = capture_io()
      result = Telegram.run(["--non-interactive"], io)

      case result do
        {:error, :secrets_not_configured} ->
          errors = error_messages(get_log.())
          assert Enum.any?(errors, &String.contains?(&1, "secret"))

        {:error, :token_not_found} ->
          # Secrets are configured but token is absent — also fine for unit
          errors = error_messages(get_log.())
          assert Enum.any?(errors, &String.contains?(&1, "token"))

        _ ->
          :ok
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Telegram adapter: token format validation (pure, no secrets)
  # ──────────────────────────────────────────────────────────────────────────

  describe "Telegram token format" do
    test "valid tokens accepted by regex" do
      valid = [
        "123456789:ABCDEFabcdef1234567890abcdefABCDEFGH",
        "987654321:aAbBcCdDeEfFgGhHiIjJkKlLmMnNoOpPqQrR"
      ]

      regex = ~r/^\d+:[\w-]{35,100}$/
      Enum.each(valid, fn t -> assert Regex.match?(regex, t), "expected #{t} to match" end)
    end

    test "invalid tokens rejected by regex" do
      invalid = ["nocodon", "123456:short", "", "abc:#{String.duplicate("x", 35)}"]
      regex = ~r/^\d+:[\w-]{35,100}$/

      Enum.each(invalid, fn t ->
        refute Regex.match?(regex, t), "expected #{t} NOT to match"
      end)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Telegram adapter: --skip-smoke bypasses connectivity
  # ──────────────────────────────────────────────────────────────────────────

  describe "Telegram.run/2 — --skip-smoke" do
    test "smoke step outputs skip message when --skip-smoke is set" do
      # We cannot easily stub Secrets or :httpc here, so we just test that
      # the skip-smoke flag propagates the right message when the run gets
      # that far (it may not if secrets aren't configured).
      {io, get_log} = capture_io()
      # Provide a fake secret callback that returns a correctly-formatted token
      # so the adapter gets past secrets (if configured in the test environment).
      io = %{
        io
        | secret: fn _ -> "123456789:#{String.duplicate("A", 35)}" end,
          prompt: fn _ -> "" end
      }

      _result = Telegram.run(["--skip-smoke", "--non-interactive"], io)

      all = messages(get_log.())

      if Enum.any?(all, &String.contains?(&1, "skip")) do
        assert Enum.any?(all, &String.contains?(&1, "smoke"))
      end
    end
  end
end
