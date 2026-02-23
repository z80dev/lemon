defmodule LemonChannels.Adapters.Telegram.TransportTopicTest do
  alias Elixir.LemonChannels, as: LemonChannels
  use ExUnit.Case, async: false

  defmodule TestRouter do
    def handle_inbound(msg) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:inbound, msg})
      end

      :ok
    end
  end

  defmodule MockAPI do
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

    def send_message(_token, chat_id, text, reply_to_or_opts \\ nil, parse_mode \\ nil) do
      notify({:send_message, chat_id, text, reply_to_or_opts, parse_mode})
      {:ok, %{"ok" => true, "result" => %{"message_id" => System.unique_integer([:positive])}}}
    end

    def create_forum_topic(_token, chat_id, name) do
      notify({:create_forum_topic, chat_id, name})

      {:ok,
       %{
         "ok" => true,
         "result" => %{"message_thread_id" => System.unique_integer([:positive])}
       }}
    end

    defp notify(msg) do
      if pid = :persistent_term.get(@pid_key, nil) do
        send(pid, msg)
      end

      :ok
    end
  end

  setup do
    stop_transport()

    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_gateway_config_env = Application.get_env(:lemon_channels, :gateway)

    :persistent_term.put({TestRouter, :pid}, self())

    MockAPI.register_test(self())

    LemonCore.RouterBridge.configure(router: TestRouter)

    set_bindings([])

    on_exit(fn ->
      stop_transport()

      :persistent_term.erase({MockAPI, :updates})

      :persistent_term.erase({MockAPI, :pid})

      :persistent_term.erase({TestRouter, :pid})

      restore_router_bridge(old_router_bridge)
      restore_gateway_config_env(old_gateway_config_env)
    end)

    :ok
  end

  test "/topic <name> creates a forum topic and replies with confirmation" do
    chat_id = 444_001
    topic_name = "foo"

    MockAPI.set_updates([group_message_update(chat_id, "/topic #{topic_name}")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:create_forum_topic, ^chat_id, ^topic_name}, 400

    assert_receive {:send_message, ^chat_id, text, _reply_to_or_opts, _parse_mode}, 400
    assert String.starts_with?(text, "Created topic \"foo\"")
    refute_receive {:inbound, _msg}, 250
  end

  test "/topic without a name returns usage and does not create a topic" do
    chat_id = 444_002

    MockAPI.set_updates([group_message_update(chat_id, "/topic")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    refute_receive {:create_forum_topic, ^chat_id, _name}, 250

    assert_receive {:send_message, ^chat_id, "Usage: /topic <name>", _reply_to_or_opts,
                    _parse_mode},
                   400

    refute_receive {:inbound, _msg}, 250
  end

  defp start_transport(overrides) when is_map(overrides) do
    token = "token-" <> Integer.to_string(System.unique_integer([:positive]))

    config =
      %{
        bot_token: token,
        api_mod: MockAPI,
        poll_interval_ms: 10,
        debounce_ms: 10
      }
      |> Map.merge(overrides)

    Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(config: config)
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

  defp group_message_update(chat_id, text) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "supergroup"},
        "from" => %{"id" => 99, "username" => "tester", "first_name" => "Test"},
        "text" => text
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
