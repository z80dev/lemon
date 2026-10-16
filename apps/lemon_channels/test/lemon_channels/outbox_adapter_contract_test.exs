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

  alias LemonChannels.Adapters.{Discord, Email, Telegram, WhatsApp, Xmtp}
  alias LemonChannels.Adapters.WhatsApp.Transport, as: WhatsAppTransport
  alias LemonChannels.Adapters.Xmtp.Transport, as: XmtpTransport
  alias LemonChannels.{DeliveryError, OutboundPayload, Outbox, Registry}
  alias LemonChannels.Outbox.{Dedupe, RateLimiter}

  @adapters [Telegram, Discord, Email, WhatsApp, Xmtp]
  @gateway_config_key :"Elixir.LemonGateway.Config"
  @jid "15551234567@s.whatsapp.net"

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
    old_gateway = Application.get_env(:lemon_gateway, @gateway_config_key)
    old_email = Application.get_env(:lemon_channels, Email)
    missing_bridge = Path.join(System.tmp_dir!(), "missing_whatsapp_bridge.mjs")

    Application.put_env(
      :lemon_gateway,
      @gateway_config_key,
      Map.merge(old_gateway || %{}, %{
        enable_discord: true,
        discord: %{account_id: "acct", api_mod: DiscordApi},
        telegram: %{
          account_id: "acct",
          bot_token: "token",
          api_mod: TelegramApi,
          files: %{outbound_send_delay_ms: 0}
        },
        whatsapp: %{bridge_script: missing_bridge, dm_mode: :open}
      })
    )

    on_exit(fn ->
      stop(WhatsAppTransport)
      stop(XmtpTransport)
      restore(:lemon_gateway, @gateway_config_key, old_gateway)
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

  describe "whatsapp" do
    test "a bridge send exception, a lost acknowledgement and a lost transport normalize to outcome-unknown" do
      result =
        whatsapp_deliver(fn transport, id ->
          send(transport, bridge_error(id, "Connection Closed", outcome_unknown: true))
        end)

      assert_unknown_outcome(result)

      result = whatsapp_deliver(fn transport, id -> send(transport, {:command_timeout, id}) end)
      assert_unknown_outcome(result)

      result = whatsapp_deliver(fn transport, _id -> Process.exit(transport, :kill) end)
      assert_unknown_outcome(result)
    end

    test "a definite bridge failure stays terminal" do
      result =
        whatsapp_deliver(fn transport, id ->
          send(transport, bridge_error(id, "not connected"))
        end)

      refute_unknown_outcome(result)
      assert {:error, "not connected"} = result
    end

    test "a transport that is not running stays terminal" do
      refute_unknown_outcome(WhatsApp.deliver(whatsapp_payload()))
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

  describe "outbox redelivery of a WhatsApp bridge send exception" do
    setup do
      for module <- [Registry, RateLimiter, Dedupe, Outbox] do
        if is_nil(Process.whereis(module)), do: start_supervised!(module)
      end

      _ = Registry.register(WhatsApp)

      on_exit(fn ->
        Application.delete_env(:lemon_channels, Outbox)
        if Process.whereis(Registry), do: Registry.unregister(WhatsApp.id())
      end)

      transport = start_whatsapp_transport()
      port_server = :sys.get_state(transport).port_server
      :erlang.trace(port_server, true, [:receive])

      %{transport: transport, port_server: port_server}
    end

    test "is redelivered with the same payload and confirmed once the bridge accepts it", ctx do
      %{transport: transport, port_server: port_server} = ctx
      {payload, ref} = notifying_whatsapp_payload("whatsapp-unknown")

      assert {:ok, _} = Outbox.enqueue(payload)

      assert_receive {:trace, ^port_server, :receive,
                      {:"$gen_cast",
                       {:command, %{"op" => "send_text", "id" => first_id, "text" => text}}}},
                     2_000

      send(transport, bridge_error(first_id, "Connection Closed", outcome_unknown: true))

      # An unknown outcome is not reported; the retry backs off for a second.
      refute_receive {:delivery_result, ^ref, _}, 200

      assert_receive {:trace, ^port_server, :receive,
                      {:"$gen_cast",
                       {:command, %{"op" => "send_text", "id" => second_id, "text" => ^text}}}},
                     4_000

      refute second_id == first_id
      send(transport, {:whatsapp_bridge_event, %{"type" => "command_result", "id" => second_id}})

      assert_receive {:delivery_result, ^ref, {:ok, :sent}}, 2_000
      assert Dedupe.check(WhatsApp.id(), payload.idempotency_key) == :duplicate
    end

    test "a definite bridge failure is reported terminal and never redelivered", ctx do
      %{transport: transport, port_server: port_server} = ctx
      {payload, ref} = notifying_whatsapp_payload("whatsapp-definite")

      assert {:ok, _} = Outbox.enqueue(payload)

      assert_receive {:trace, ^port_server, :receive,
                      {:"$gen_cast", {:command, %{"op" => "send_text", "id" => id}}}},
                     2_000

      send(transport, bridge_error(id, "ENOENT: no such file"))
      assert_receive {:delivery_result, ^ref, {:error, "ENOENT: no such file"}}, 500

      # The shortest retry backoff is one second.
      refute_receive {:trace, ^port_server, :receive,
                      {:"$gen_cast", {:command, %{"op" => "send_text"}}}},
                     1_300
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

  # Delivers one WhatsApp text through the real transport and adapter, with the
  # bridge's reply scripted by `respond`, which receives the transport and the
  # correlation id of the command the bridge was asked to run.
  defp whatsapp_deliver(respond) do
    stop(WhatsAppTransport)
    transport = start_whatsapp_transport()
    port_server = :sys.get_state(transport).port_server
    :erlang.trace(port_server, true, [:receive])

    task = Task.async(fn -> WhatsApp.deliver(whatsapp_payload()) end)

    assert_receive {:trace, ^port_server, :receive,
                    {:"$gen_cast", {:command, %{"op" => "send_text", "id" => id}}}},
                   2_000

    respond.(transport, id)
    Task.await(task, 5_000)
  end

  defp start_whatsapp_transport do
    stop(WhatsAppTransport)
    # Unlinked: a test may kill the transport mid-call.
    {:ok, pid} = GenServer.start(WhatsAppTransport, [], name: WhatsAppTransport)
    send(pid, {:whatsapp_bridge_event, %{"type" => "connected", "jid" => "bot@s.whatsapp.net"}})
    pid
  end

  defp bridge_error(id, message, extra \\ []) do
    event = %{"type" => "command_error", "id" => id, "error" => message}
    {:whatsapp_bridge_event, Enum.into(extra, event, fn {k, v} -> {to_string(k), v} end)}
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

  defp whatsapp_payload do
    OutboundPayload.text("whatsapp", "default", %{kind: :dm, id: @jid, thread_id: nil}, "hello")
  end

  defp xmtp_payload do
    OutboundPayload.text(
      "xmtp",
      "default",
      %{kind: :dm, id: "conversation-1", thread_id: nil},
      "hello"
    )
  end

  defp notifying_whatsapp_payload(key_prefix) do
    ref = make_ref()

    payload =
      OutboundPayload.text(
        "whatsapp",
        "default",
        %{kind: :dm, id: @jid, thread_id: nil},
        "outbox-#{System.unique_integer([:positive])}",
        idempotency_key: "#{key_prefix}-#{System.unique_integer([:positive])}",
        notify_pid: self(),
        notify_ref: ref,
        meta: %{notify_tag: :delivery_result}
      )

    {payload, ref}
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
