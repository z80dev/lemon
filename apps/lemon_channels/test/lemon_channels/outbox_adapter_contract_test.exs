defmodule LemonChannels.OutboxAdapterContractTest do
  @moduledoc """
  The contract every built-in outbox adapter honors for the at-least-once
  delivery policy.

  Each adapter's `deliver/1` is driven against a fake transport (no network):

    * an **ambiguous** send, one where the platform may already have accepted the
      write, normalizes to an outcome-unknown failure, which the outbox
      redelivers with the same payload and idempotency key;
    * a **definite** failure, a rejection or a failure before anything was sent,
      is not unknown and stays terminal.

  The outbox applies `DeliveryError.classify/1` and then
  `DeliveryError.outcome_unknown?/1` to what an adapter returns, so that is the
  normalization asserted here. A new adapter must be added below; the first test
  fails until it is.
  """
  use ExUnit.Case, async: false

  import LemonChannels.FakeSmtpRelay

  alias LemonChannels.Adapters.{Discord, Email, Telegram, Xmtp}
  alias LemonChannels.Adapters.Xmtp.Transport, as: XmtpTransport
  alias LemonChannels.{DeliveryError, OutboundPayload}

  @adapters [Telegram, Discord, Email, Xmtp]
  @gateway_config_key :gateway_test_config

  defmodule TelegramApi do
    def send_message(_token, _chat_id, _text, _opts, _parse_mode), do: Process.get(:api_result)
  end

  defmodule DiscordApi do
    def create(_channel_id, _params) do
      case Process.get(:api_result) do
        {:raise, message} -> raise message
        result -> result
      end
    end
  end

  # Stands in for an XMTP transport that dies while a delivery call is in flight.
  defmodule CrashingXmtpTransport do
    use GenServer

    def start, do: GenServer.start(__MODULE__, nil, name: LemonChannels.Adapters.Xmtp.Transport)

    @impl true
    def init(_), do: {:ok, nil}

    @impl true
    def handle_call({:deliver, _payload}, _from, state), do: {:stop, :crashed, state}
  end

  setup do
    old_gateway = Application.get_env(:lemon_core, @gateway_config_key)
    old_email = Application.get_env(:lemon_channels, Email)

    Application.put_env(
      :lemon_core,
      @gateway_config_key,
      Map.merge(old_gateway || %{}, %{
        enable_discord: true,
        discord: %{account_id: "acct", api_mod: DiscordApi},
        telegram: %{
          account_id: "acct",
          bot_token: "token",
          api_mod: TelegramApi
        }
      })
    )

    on_exit(fn ->
      stop(XmtpTransport)
      restore(:lemon_core, @gateway_config_key, old_gateway)
      restore(:lemon_channels, Email, old_email)
    end)

    :ok
  end

  test "every built-in adapter is covered by this contract" do
    {:ok, modules} = :application.get_key(:lemon_channels, :modules)

    plugins =
      Enum.filter(modules, fn module ->
        Code.ensure_loaded?(module) and
          LemonChannels.Plugin in Keyword.get(module.module_info(:attributes), :behaviour, [])
      end)

    assert Enum.sort(plugins) == Enum.sort(@adapters)
  end

  describe "telegram" do
    test "ambiguous sends normalize to outcome-unknown" do
      for result <- [
            {:error, :timeout},
            {:error, {:closed, :socket}},
            {:error, {:http_error, 502, ""}}
          ] do
        Process.put(:api_result, result)
        assert_unknown_outcome(Telegram.deliver(telegram_payload()))
      end
    end

    test "a definite rejection stays terminal" do
      Process.put(:api_result, {:error, {:http_error, 400, "Bad Request"}})
      refute_unknown_outcome(Telegram.deliver(telegram_payload()))
    end
  end

  describe "discord" do
    test "ambiguous sends normalize to outcome-unknown" do
      for result <- [
            {:error, :timeout},
            {:error, {:http_error, 503, ""}},
            {:raise, "connection died mid-send"}
          ] do
        Process.put(:api_result, result)
        assert_unknown_outcome(Discord.deliver(discord_payload()))
      end
    end

    test "a definite rejection stays terminal" do
      Process.put(:api_result, {:error, %{status_code: 400, response: %{message: "bad"}}})
      refute_unknown_outcome(Discord.deliver(discord_payload()))
    end
  end

  describe "email" do
    test "a connection lost after DATA and a stalled relay normalize to outcome-unknown" do
      {port, server} = smtp_server(&receive_message/1)
      configure_relay(port)
      assert_unknown_outcome(Email.deliver(email_payload()))
      await(server)

      # The relay accepts the connection and never speaks: the deadline fires
      # while the outcome is still pending.
      {port, server} = smtp_server(fn socket -> :gen_tcp.recv(socket, 0, 2_000) end)
      configure_relay(port, smtp_timeout: 300)
      assert_unknown_outcome(Email.deliver(email_payload()))
      await(server)
    end

    test "a rejection and a failure before DATA stay terminal" do
      {port, server} =
        smtp_server(fn socket ->
          _body = receive_message(socket)
          tcp_send(socket, "554 5.7.1 message rejected")
        end)

      configure_relay(port)
      refute_unknown_outcome(Email.deliver(email_payload()))
      await(server)

      configure_relay(closed_port())
      refute_unknown_outcome(Email.deliver(email_payload()))
    end
  end

  describe "xmtp" do
    test "a transport lost mid-call normalizes to outcome-unknown" do
      {:ok, _pid} = CrashingXmtpTransport.start()
      assert_unknown_outcome(Xmtp.deliver(xmtp_payload()))
    end

    test "a transport that is not running stays terminal" do
      refute_unknown_outcome(Xmtp.deliver(xmtp_payload()))
    end
  end

  # --- Normalization, as the outbox applies it ---

  defp assert_unknown_outcome(result) do
    assert {:error, reason} = result

    assert DeliveryError.outcome_unknown?(DeliveryError.classify(reason)),
           "ambiguous outcome was not normalized to outcome-unknown: #{inspect(reason)}"
  end

  defp refute_unknown_outcome(result) do
    assert {:error, reason} = result

    refute DeliveryError.outcome_unknown?(DeliveryError.classify(reason)),
           "definite failure was classified outcome-unknown: #{inspect(reason)}"
  end

  # --- Fake transports ---

  defp configure_relay(port, extra \\ []) do
    Application.put_env(
      :lemon_channels,
      Email,
      Keyword.merge([from: "agent@lemon.test", smtp_relay: "127.0.0.1", smtp_port: port], extra)
    )
  end

  # --- Payloads ---

  defp telegram_payload do
    OutboundPayload.text("telegram", "acct", %{kind: :dm, id: "123", thread_id: nil}, "hello")
  end

  defp discord_payload do
    OutboundPayload.text("discord", "acct", %{kind: :channel, id: "123", thread_id: nil}, "hello")
  end

  defp email_payload do
    OutboundPayload.text(
      "email",
      "agent@lemon.test",
      %{kind: :dm, id: "alice@example.com", thread_id: nil},
      "here you go"
    )
  end

  defp xmtp_payload do
    OutboundPayload.text(
      "xmtp",
      "default",
      %{kind: :dm, id: "conversation-1", thread_id: nil},
      "hello"
    )
  end

  defp stop(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
