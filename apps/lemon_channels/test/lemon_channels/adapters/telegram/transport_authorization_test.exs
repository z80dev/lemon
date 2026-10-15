defmodule LemonChannels.Adapters.Telegram.TransportAuthorizationTest do
  alias Elixir.LemonChannels, as: LemonChannels
  use ExUnit.Case, async: false

  defmodule AuthTestRouter do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def handle_inbound(msg) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:inbound, msg})
      end

      :ok
    end

    def submit(%LemonCore.RunRequest{} = request) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:inbound, inbound_from_request(request)})
      end

      {:ok, "run_#{System.unique_integer([:positive])}"}
    end

    defp inbound_from_request(%LemonCore.RunRequest{} = request) do
      meta = request.meta || %{}

      %LemonCore.InboundMessage{
        channel_id: meta[:channel_id],
        account_id: meta[:account_id],
        peer: meta[:peer],
        sender: meta[:sender],
        message: %{
          id: meta[:user_msg_id] && to_string(meta[:user_msg_id]),
          text: request.prompt,
          timestamp: nil,
          reply_to_id: nil
        },
        raw: meta[:raw],
        meta: meta
      }
    end
  end

  defmodule AuthMockAPI do
    @updates_key {__MODULE__, :updates}
    @pid_key {__MODULE__, :pid}

    def set_updates(updates), do: :persistent_term.put(@updates_key, updates)
    def register_test(pid), do: :persistent_term.put(@pid_key, pid)

    def get_updates(_token, _offset, _timeout_ms) do
      updates = :persistent_term.get(@updates_key, [])

      case updates do
        [next | rest] ->
          :persistent_term.put(@updates_key, rest)
          {:ok, %{"ok" => true, "result" => [next]}}

        [] ->
          {:ok, %{"ok" => true, "result" => []}}
      end
    end

    def send_message(_token, chat_id, text, _reply_to_or_opts \\ nil, _parse_mode \\ nil) do
      if pid = :persistent_term.get(@pid_key, nil) do
        send(pid, {:send_message, chat_id, text})
      end

      {:ok, %{"ok" => true, "result" => %{"message_id" => System.unique_integer([:positive])}}}
    end

    def edit_message_text(_token, chat_id, message_id, text, opts \\ nil) do
      if pid = :persistent_term.get(@pid_key, nil) do
        send(pid, {:edit_message_text, chat_id, message_id, text, opts})
      end

      {:ok, %{"ok" => true}}
    end

    def delete_message(_token, _chat_id, _message_id), do: {:ok, %{"ok" => true}}

    def answer_callback_query(_token, callback_id, opts \\ %{}) do
      if pid = :persistent_term.get(@pid_key, nil) do
        send(pid, {:answer_callback, callback_id, opts})
      end

      {:ok, %{"ok" => true}}
    end
  end

  @gateway_config_key :"Elixir.LemonGateway.Config"

  setup do
    stop_transport()

    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_gateway_env = Application.get_env(:lemon_gateway, @gateway_config_key)

    :persistent_term.put({AuthTestRouter, :pid}, self())
    AuthMockAPI.register_test(self())

    :ok =
      LemonCore.RouterBridge.configure(router: AuthTestRouter, run_orchestrator: AuthTestRouter)

    set_bindings([])

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({AuthMockAPI, :updates})
      :persistent_term.erase({AuthMockAPI, :pid})
      :persistent_term.erase({AuthTestRouter, :pid})
      restore_router_bridge(old_router_bridge)
      restore_gateway_env(old_gateway_env)
    end)

    :ok
  end

  test "opt-in pairing replies once to an unknown DM even with an existing allowlist" do
    chat_id = 100_020
    AuthMockAPI.set_updates([message_update(chat_id, "hello"), message_update(chat_id, "again")])

    assert {:ok, _pid} =
             start_transport(%{allowed_chat_ids: [chat_id + 1], unauthorized_dm_behavior: "pair"})

    assert_receive {:send_message, ^chat_id, reply}
    assert [_, code] = Regex.run(~r/Pairing code: ([A-HJ-NP-Z2-9]{8})/, reply)
    assert reply =~ "lemon pairing approve telegram #{code}"
    refute_receive {:send_message, ^chat_id, _}, 100
    refute_receive {:inbound, _}, 100

    assert {:ok, %{chat_id: "100020", user_id: "99"}} =
             LemonChannels.Pairing.consume("telegram", code)
  end

  test "opt-in pairing does not offer codes to unknown groups" do
    update = put_in(message_update(100_021, "hello"), ["message", "chat", "type"], "supergroup")
    AuthMockAPI.set_updates([update])

    assert {:ok, _pid} =
             start_transport(%{allowed_chat_ids: [], unauthorized_dm_behavior: "pair"})

    refute_receive {:send_message, _, _}, 150
    refute_receive {:inbound, _}, 100
  end

  test "unpaired bot drops DMs from any chat and tells the chat once how to pair" do
    chat_id = 100_010

    AuthMockAPI.set_updates([
      message_update(chat_id, "run rm -rf ~"),
      message_update(chat_id, "second attempt")
    ])

    assert {:ok, _pid} = start_transport(%{allowed_chat_ids: nil})

    assert_receive {:send_message, ^chat_id, notice}
    assert notice =~ "This bot is not paired."
    assert notice =~ "lemon gateway setup telegram"

    refute_receive {:inbound, _msg}, 250
    refute_receive {:send_message, ^chat_id, _second_notice}, 100
  end

  test "an empty allowlist is unpaired, not open" do
    chat_id = 100_011
    AuthMockAPI.set_updates([message_update(chat_id, "hello")])

    assert {:ok, _pid} = start_transport(%{allowed_chat_ids: []})

    assert_receive {:send_message, ^chat_id, notice}
    assert notice =~ "not paired"
    refute_receive {:inbound, _msg}, 250
  end

  test "/whoami answers with chat and user ids while unpaired and never reaches the router" do
    chat_id = 100_012
    AuthMockAPI.set_updates([message_update(chat_id, "/whoami")])

    assert {:ok, _pid} = start_transport(%{allowed_chat_ids: nil})

    assert_receive {:send_message, ^chat_id, reply}
    assert reply =~ "chat_id: #{chat_id}"
    assert reply =~ "user_id: 99"
    refute reply =~ "not paired"
    refute_receive {:inbound, _msg}, 250
  end

  test "allow_all_chats = true explicitly opts an unpaired bot into every chat" do
    chat_id = 100_013
    AuthMockAPI.set_updates([message_update(chat_id, "hello from anyone")])

    assert {:ok, _pid} = start_transport(%{allowed_chat_ids: nil, allow_all_chats: true})

    assert_receive {:inbound, msg}
    assert msg.message.text == "hello from anyone"
  end

  test "a non-empty allowlist wins over allow_all_chats" do
    chat_id = 100_014
    AuthMockAPI.set_updates([message_update(chat_id, "hello from stranger")])

    assert {:ok, _pid} =
             start_transport(%{allowed_chat_ids: [chat_id + 1], allow_all_chats: true})

    refute_receive {:inbound, _msg}, 250
  end

  test "unpaired bot ignores callback queries" do
    chat_id = 200_010
    AuthMockAPI.set_updates([callback_update(chat_id, "unknown|decision")])

    assert {:ok, _pid} = start_transport(%{allowed_chat_ids: nil})

    refute_receive {:answer_callback, _cb_id, _opts}, 250
  end

  test "drops message updates when chat is not in allowed_chat_ids" do
    chat_id = 100_001
    AuthMockAPI.set_updates([message_update(chat_id, "hello from disallowed chat")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id + 1],
               deny_unbound_chats: false
             })

    refute_receive {:inbound, _msg}, 250
  end

  test "drops message updates when deny_unbound_chats is true and no binding exists" do
    chat_id = 100_002
    set_bindings([])
    AuthMockAPI.set_updates([message_update(chat_id, "hello from unbound chat")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: true
             })

    refute_receive {:inbound, _msg}, 250
  end

  test "allows message updates from bound chats when deny_unbound_chats is true" do
    chat_id = 100_003
    set_bindings([scope_binding(chat_id)])
    AuthMockAPI.set_updates([message_update(chat_id, "hello from bound chat")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: true
             })

    assert_receive {:inbound, msg}
    assert msg.meta[:chat_id] == chat_id
    assert msg.message.text == "hello from bound chat"
  end

  test "ignores callback queries when chat is not in allowed_chat_ids" do
    chat_id = 200_001
    AuthMockAPI.set_updates([callback_update(chat_id, "unknown|decision")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id + 1],
               deny_unbound_chats: false
             })

    refute_receive {:answer_callback, _cb_id, _opts}, 250
  end

  test "ignores callback queries when deny_unbound_chats is true and no binding exists" do
    chat_id = 200_002
    set_bindings([])
    AuthMockAPI.set_updates([callback_update(chat_id, "unknown|decision")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: true
             })

    refute_receive {:answer_callback, _cb_id, _opts}, 250
  end

  test "bound chats reach callback rejection without consuming a malformed approval" do
    chat_id = 200_003
    set_bindings([scope_binding(chat_id)])
    id = LemonCore.Id.approval_id()

    pending =
      LemonCore.Events.ApprovalPending.new(%{
        id: id,
        run_id: LemonCore.Id.run_id(),
        session_key: "agent:default:telegram:default:dm:#{chat_id}",
        tool: "bash",
        action: %{command: "echo guarded"}
      })

    :ok = LemonCore.ExecApprovalStore.put_pending(id, pending)
    on_exit(fn -> LemonCore.ExecApprovalStore.delete_pending(id) end)
    AuthMockAPI.set_updates([callback_update(chat_id, id <> "|once")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: true
             })

    assert_receive {:answer_callback, _cb_id, %{"text" => reply}}
    assert is_binary(reply) and reply != ""
    refute reply == "Recorded"
    assert {:ok, ^pending} = LemonCore.ExecApprovalStore.fetch_pending(id)
    refute_receive {:edit_message_text, _, _, _, _}, 100
  end

  defp start_transport(overrides) when is_map(overrides) do
    token = "token-" <> Integer.to_string(System.unique_integer([:positive]))

    config =
      %{
        bot_token: token,
        api_mod: AuthMockAPI,
        poll_interval_ms: 10,
        debounce_ms: 10
      }
      |> Map.merge(overrides)

    Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(config: config)
  end

  defp set_bindings(bindings) do
    existing = Application.get_env(:lemon_gateway, @gateway_config_key, %{})

    Application.put_env(
      :lemon_gateway,
      @gateway_config_key,
      Map.put(existing, :bindings, bindings)
    )
  end

  defp restore_gateway_env(nil) do
    Application.delete_env(:lemon_gateway, @gateway_config_key)
  end

  defp restore_gateway_env(env) do
    Application.put_env(:lemon_gateway, @gateway_config_key, env)
  end

  defp restore_router_bridge(nil), do: Application.delete_env(:lemon_core, :router_bridge)
  defp restore_router_bridge(config), do: Application.put_env(:lemon_core, :router_bridge, config)

  defp scope_binding(chat_id) do
    %{
      transport: :telegram,
      chat_id: chat_id,
      topic_id: nil,
      project: nil,
      agent_id: nil,
      queue_mode: nil
    }
  end

  defp message_update(chat_id, text) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => 99, "username" => "tester", "first_name" => "Test"},
        "text" => text
      }
    }
  end

  defp callback_update(chat_id, data) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "callback_query" => %{
        "id" => "cb-" <> Integer.to_string(System.unique_integer([:positive])),
        "from" => %{"id" => 99, "username" => "tester", "first_name" => "Test"},
        "data" => data,
        "message" => %{
          "message_id" => System.unique_integer([:positive]),
          "chat" => %{"id" => chat_id, "type" => "private"}
        }
      }
    }
  end

  defp stop_transport do
    if pid = Process.whereis(Elixir.LemonChannels.Adapters.Telegram.Transport) do
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end
  catch
    :exit, _ -> :ok
  end
end
