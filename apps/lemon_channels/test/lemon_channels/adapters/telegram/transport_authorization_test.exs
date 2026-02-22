defmodule LemonChannels.Adapters.Telegram.TransportAuthorizationTest do
  use ExUnit.Case, async: false

  defmodule LemonChannels.Adapters.Telegram.TransportAuthorizationTest.TestRouter do
    def handle_inbound(msg) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:inbound, msg})
      end

      :ok
    end
  end

  defmodule LemonChannels.Adapters.Telegram.TransportAuthorizationTest.MockAPI do
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

    def send_message(_token, _chat_id, _text, _reply_to_or_opts \\ nil, _parse_mode \\ nil) do
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

  setup do
    stop_transport()

    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_gateway_config_env = Application.get_env(:lemon_channels, :gateway)

    :persistent_term.put({LemonChannels.Adapters.Telegram.TransportAuthorizationTest.TestRouter, :pid}, self())
    LemonChannels.Adapters.Telegram.TransportAuthorizationTest.MockAPI.register_test(self())
    LemonCore.RouterBridge.configure(router: LemonChannels.Adapters.Telegram.TransportAuthorizationTest.TestRouter)
    set_bindings([])

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({LemonChannels.Adapters.Telegram.TransportAuthorizationTest.MockAPI, :updates})
      :persistent_term.erase({LemonChannels.Adapters.Telegram.TransportAuthorizationTest.MockAPI, :pid})
      :persistent_term.erase({LemonChannels.Adapters.Telegram.TransportAuthorizationTest.TestRouter, :pid})
      restore_router_bridge(old_router_bridge)
      restore_gateway_config_env(old_gateway_config_env)
    end)

    :ok
  end

  test "drops message updates when chat is not in allowed_chat_ids" do
    chat_id = 100_001
    LemonChannels.Adapters.Telegram.TransportAuthorizationTest.MockAPI.set_updates([message_update(chat_id, "hello from disallowed chat")])

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
    LemonChannels.Adapters.Telegram.TransportAuthorizationTest.MockAPI.set_updates([message_update(chat_id, "hello from unbound chat")])

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
    LemonChannels.Adapters.Telegram.TransportAuthorizationTest.MockAPI.set_updates([message_update(chat_id, "hello from bound chat")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: true
             })

    assert_receive {:inbound, msg}, 400
    assert msg.meta[:chat_id] == chat_id
    assert msg.message.text == "hello from bound chat"
  end

  test "ignores callback queries when chat is not in allowed_chat_ids" do
    chat_id = 200_001
    LemonChannels.Adapters.Telegram.TransportAuthorizationTest.MockAPI.set_updates([callback_update(chat_id, "unknown|decision")])

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
    LemonChannels.Adapters.Telegram.TransportAuthorizationTest.MockAPI.set_updates([callback_update(chat_id, "unknown|decision")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: true
             })

    refute_receive {:answer_callback, _cb_id, _opts}, 250
  end

  test "handles callback queries from bound chats when guards pass" do
    chat_id = 200_003
    set_bindings([scope_binding(chat_id)])
    LemonChannels.Adapters.Telegram.TransportAuthorizationTest.MockAPI.set_updates([callback_update(chat_id, "unknown|decision")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: true
             })

    assert_receive {:answer_callback, _cb_id, %{"text" => "Unknown"}}, 300
  end

  defp start_transport(overrides) when is_map(overrides) do
    token = "token-" <> Integer.to_string(System.unique_integer([:positive]))

    config =
      %{
        bot_token: token,
        api_mod: LemonChannels.Adapters.Telegram.TransportAuthorizationTest.MockAPI,
        poll_interval_ms: 10,
        debounce_ms: 10
      }
      |> Map.merge(overrides)

    LemonChannels.Adapters.Telegram.Transport.start_link(config: config)
  end

  defp set_bindings(bindings) do
    cfg =
      case Application.get_env(:lemon_channels, :gateway) do
        map when is_map(map) -> map
        list when is_list(list) -> Enum.into(list, %{})
        _ -> %{}
      end

    Application.put_env(:lemon_channels, :gateway, Map.put(cfg, :bindings, bindings))
  end

  defp restore_gateway_config_env(nil) do
    Application.delete_env(:lemon_channels, :gateway)
  end

  defp restore_gateway_config_env(env) do
    Application.put_env(:lemon_channels, :gateway, env)
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
      default_engine: nil,
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
    if pid = Process.whereis(LemonChannels.Adapters.Telegram.Transport) do
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end
  catch
    :exit, _ -> :ok
  end
end
