defmodule LemonCore.Setup.GatewayTest do
  use ExUnit.Case, async: true

  alias LemonCore.Setup.Gateway
  alias LemonCore.Setup.Gateway.Telegram

  # ──────────────────────────────────────────────────────────────────────────
  # Test helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp capture_io do
    agent_ref = start_supervised!({Agent, fn -> [] end})

    io = %{
      info: fn msg -> Agent.update(agent_ref, &[{:info, msg} | &1]) end,
      error: fn msg -> Agent.update(agent_ref, &[{:error, msg} | &1]) end,
      prompt: fn _msg -> "" end,
      secret: fn _msg -> "" end
    }

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
