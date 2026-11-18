defmodule LemonChannels.Adapters.Xmtp.TransportAuthorizationTest do
  @moduledoc """
  Sender authorization for XMTP inbound traffic, exercised through the real
  transport message path: bridge JSON events delivered as
  `{:xmtp_bridge_event, map}` to a running `Xmtp.Transport`, submitted through
  `LemonCore.RouterBridge`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonChannels.Adapters.Xmtp.Transport
  alias LemonCore.Dedupe.Ets

  defmodule AuthTestRouter do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def handle_inbound(msg) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil), do: send(pid, {:inbound, msg})
      :ok
    end

    def submit(%LemonCore.RunRequest{} = request) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:submitted, request.prompt, request.meta || %{}})
      end

      {:ok, "run_#{System.unique_integer([:positive])}"}
    end
  end

  @gateway_config_key :"Elixir.LemonGateway.Config"
  @dedupe_table :lemon_channels_xmtp_dedupe
  @allowed_inbox "inbox-allowed-1"
  @other_inbox "inbox-stranger-2"
  @bot_inbox "bot-inbox-abc"
  @bot_wallet "0x2222222222222222222222222222222222222222"
  @secret_text "launch the secret plan 7f3a"

  setup do
    stop_transport()

    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_gateway_env = Application.get_env(:lemon_gateway, @gateway_config_key)

    :persistent_term.put({AuthTestRouter, :pid}, self())

    :ok =
      LemonCore.RouterBridge.configure(router: AuthTestRouter, run_orchestrator: AuthTestRouter)

    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      enable_xmtp: true,
      xmtp: %{require_live: false, poll_interval_ms: 30_000, connect_timeout_ms: 5_000}
    })

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({AuthTestRouter, :pid})
      restore_env(:lemon_core, :router_bridge, old_router_bridge)
      restore_env(:lemon_gateway, @gateway_config_key, old_gateway_env)
    end)

    :ok
  end

  test "a sender outside allowed_inboxes is dropped before dedupe and submission; the allowed inbox submits" do
    pid = start_transport(%{allowed_inboxes: [String.upcase(@allowed_inbox)]})
    port_server = trace_port_server(pid)

    denied = dm_event(@other_inbox, "msg-denied", "bridge-denied", @secret_text)
    denied_key = Transport.inbound_dedupe_key_for_test(denied)

    send(pid, {:xmtp_bridge_event, denied})
    :sys.get_state(pid)

    refute_receive {:submitted, _, _}, 150
    refute Ets.seen?(@dedupe_table, denied_key, :infinity)
    # The bridge is told to stop re-emitting the dropped message, but no reply is sent.
    assert_receive {:trace, ^port_server, :receive,
                    {:"$gen_cast",
                     {:command, %{"op" => "ack_inbound", "dedupe_key" => "bridge-denied"}}}},
                   800

    refute_receive {:trace, ^port_server, :receive,
                    {:"$gen_cast", {:command, %{"op" => "send"}}}},
                   100

    allowed = dm_event(@allowed_inbox, "msg-allowed", "bridge-allowed", "hello from allowed")
    send(pid, {:xmtp_bridge_event, allowed})

    assert_receive {:submitted, "hello from allowed", meta}, 1_000
    assert meta[:xmtp].sender_inbox_id == @allowed_inbox
    :sys.get_state(pid)
    assert Ets.seen?(@dedupe_table, Transport.inbound_dedupe_key_for_test(allowed), :infinity)
  end

  test "empty allowed_inboxes with allow_all unset denies, and the log carries no message content" do
    for cfg <- [%{}, %{allowed_inboxes: []}] do
      stop_transport()
      pid = start_transport(cfg)

      event = dm_event(@allowed_inbox, "msg-unpaired", "bridge-unpaired", @secret_text)

      log =
        capture_log([level: :debug], fn ->
          send(pid, {:xmtp_bridge_event, event})
          :sys.get_state(pid)
        end)

      refute_receive {:submitted, _, _}, 150
      refute Ets.seen?(@dedupe_table, Transport.inbound_dedupe_key_for_test(event), :infinity)
      assert log =~ "xmtp inbound dropped"
      assert log =~ "reason=unpaired"
      refute log =~ "secret plan"
      refute log =~ "7f3a"
    end
  end

  test "allow_all: true with no allowlist accepts any sender" do
    pid = start_transport(%{allow_all: true})

    send(pid, {:xmtp_bridge_event, dm_event(@other_inbox, "msg-open", "bridge-open", "open")})
    assert_receive {:submitted, "open", _meta}, 1_000
  end

  test "a non-empty allowlist is authoritative even with allow_all: true" do
    pid = start_transport(%{allowed_inboxes: [@allowed_inbox], allow_all: true})

    send(pid, {:xmtp_bridge_event, dm_event(@other_inbox, "msg-x", "bridge-x", "nope")})
    refute_receive {:submitted, _, _}, 150
  end

  test "a message without a sender inbox id is denied even when its wallet looks familiar" do
    pid = start_transport(%{allowed_inboxes: [@allowed_inbox]})

    event =
      dm_event(@allowed_inbox, "msg-no-inbox", "bridge-no-inbox", "spoof")
      |> Map.delete("sender_inbox_id")

    send(pid, {:xmtp_bridge_event, event})
    refute_receive {:submitted, _, _}, 150
  end

  test "group messages without a mention of the bot are non-triggering" do
    pid = start_transport(%{allowed_inboxes: [@allowed_inbox]})
    send(pid, connected_event())

    no_mention = group_event(@allowed_inbox, "msg-g1", "bridge-g1", "just chatting")
    send(pid, {:xmtp_bridge_event, no_mention})
    :sys.get_state(pid)

    refute_receive {:submitted, _, _}, 150
    refute Ets.seen?(@dedupe_table, Transport.inbound_dedupe_key_for_test(no_mention), :infinity)

    by_inbox =
      group_event(@allowed_inbox, "msg-g2", "bridge-g2", "@#{String.upcase(@bot_inbox)} run it")

    send(pid, {:xmtp_bridge_event, by_inbox})
    assert_receive {:submitted, "@" <> _, meta}, 1_000
    assert meta[:peer].kind == :group

    by_wallet =
      group_event(@allowed_inbox, "msg-g3", "bridge-g3", "hey @#{String.upcase(@bot_wallet)}")

    send(pid, {:xmtp_bridge_event, by_wallet})
    assert_receive {:submitted, "hey @" <> _, _meta}, 1_000

    # A longer token that merely starts with the bot's inbox id is not a mention.
    prefix_only = group_event(@allowed_inbox, "msg-g4", "bridge-g4", "@#{@bot_inbox}xyz go")
    send(pid, {:xmtp_bridge_event, prefix_only})
    refute_receive {:submitted, _, _}, 150
  end

  test "a group mention from a sender outside the allowlist is still dropped" do
    pid = start_transport(%{allowed_inboxes: [@allowed_inbox]})
    send(pid, connected_event())

    event = group_event(@other_inbox, "msg-g5", "bridge-g5", "@#{@bot_inbox} do it")
    send(pid, {:xmtp_bridge_event, event})
    refute_receive {:submitted, _, _}, 150
  end

  test "group messages cannot trigger when the bot identity is unknown" do
    pid = start_transport(%{allowed_inboxes: [@allowed_inbox]})
    send(pid, {:xmtp_bridge_event, %{"type" => "connected", "mode" => "live"}})

    send(pid, {:xmtp_bridge_event, group_event(@allowed_inbox, "m", "b", "@ do it")})
    refute_receive {:submitted, _, _}, 150
  end

  test "an unauthorized non-text message gets no placeholder reply" do
    pid = start_transport(%{allowed_inboxes: [@allowed_inbox]})
    port_server = trace_port_server(pid)

    event =
      dm_event(@other_inbox, "msg-img", "bridge-img", nil)
      |> Map.merge(%{"content_type" => "image", "content" => %{"mime_type" => "image/png"}})

    send(pid, {:xmtp_bridge_event, event})
    :sys.get_state(pid)

    refute_receive {:trace, ^port_server, :receive,
                    {:"$gen_cast", {:command, %{"op" => "send"}}}},
                   150
  end

  # The policy lives in the canonical gateway config (here the test-mode
  # replacement layer `LemonCore.GatewayConfig` reads), not in start options, so
  # a reload that rewrites it must govern the next message without a restart.
  test "a config reload that revokes an inbox stops it on the running transport" do
    put_xmtp_policy(%{allowed_inboxes: [@allowed_inbox]})
    pid = start_transport(%{})

    send(pid, {:xmtp_bridge_event, dm_event(@allowed_inbox, "msg-r1", "bridge-r1", "before")})
    assert_receive {:submitted, "before", _}, 1_000

    put_xmtp_policy(%{allowed_inboxes: [@other_inbox]})

    revoked = dm_event(@allowed_inbox, "msg-r2", "bridge-r2", "after revoke")
    send(pid, {:xmtp_bridge_event, revoked})
    :sys.get_state(pid)
    refute_receive {:submitted, "after revoke", _}, 150
    refute Ets.seen?(@dedupe_table, Transport.inbound_dedupe_key_for_test(revoked), :infinity)

    send(
      pid,
      {:xmtp_bridge_event, dm_event(@other_inbox, "msg-r3", "bridge-r3", "newly allowed")}
    )

    assert_receive {:submitted, "newly allowed", _}, 1_000
  end

  test "a config reload from allow_all: true to false closes the running transport" do
    put_xmtp_policy(%{allow_all: true})
    pid = start_transport(%{})

    send(pid, {:xmtp_bridge_event, dm_event(@other_inbox, "msg-a1", "bridge-a1", "open door")})
    assert_receive {:submitted, "open door", _}, 1_000

    put_xmtp_policy(%{allow_all: false})

    send(pid, {:xmtp_bridge_event, dm_event(@other_inbox, "msg-a2", "bridge-a2", "closed door")})
    :sys.get_state(pid)
    refute_receive {:submitted, "closed door", _}, 150
  end

  defp put_xmtp_policy(policy) do
    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      enable_xmtp: true,
      xmtp:
        Map.merge(
          %{require_live: false, poll_interval_ms: 30_000, connect_timeout_ms: 5_000},
          policy
        )
    })
  end

  defp start_transport(extra_cfg) do
    cfg =
      Map.merge(
        %{bridge_script: missing_bridge_script(), require_live: false, connect_timeout_ms: 5_000},
        extra_cfg
      )

    {:ok, pid} = Transport.start_link(config: cfg)
    send(pid, {:xmtp_bridge_event, %{"type" => "connected", "mode" => "live"}})
    pid
  end

  defp connected_event do
    {:xmtp_bridge_event,
     %{
       "type" => "connected",
       "mode" => "live",
       "inbox_id" => @bot_inbox,
       "wallet_address" => @bot_wallet
     }}
  end

  defp trace_port_server(pid) do
    port_server = :sys.get_state(pid).port_server
    :erlang.trace(port_server, true, [:receive])
    port_server
  end

  defp dm_event(inbox, message_id, bridge_key, text) do
    %{
      "type" => "message",
      "bridge_dedupe_key" => bridge_key,
      "conversation_id" => "conv-#{inbox}",
      "sender_inbox_id" => inbox,
      "sender_address" => "0x1111111111111111111111111111111111111111",
      "message_id" => message_id,
      "content" => %{"text" => text},
      "is_group" => false
    }
  end

  defp group_event(inbox, message_id, bridge_key, text) do
    dm_event(inbox, message_id, bridge_key, text)
    |> Map.merge(%{
      "conversation_id" => "group-conv-1",
      "is_group" => true,
      "group_id" => "group-conv-1"
    })
  end

  defp missing_bridge_script do
    Path.join(System.tmp_dir!(), "xmtp_missing_bridge_#{System.unique_integer([:positive])}.mjs")
  end

  defp stop_transport do
    case Process.whereis(Transport) do
      pid when is_pid(pid) -> GenServer.stop(pid, :normal, 1_000)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
