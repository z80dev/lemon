defmodule LemonChannels.Adapters.Telegram.TransportTopicTest do
  alias Elixir.LemonChannels, as: LemonChannels
  use ExUnit.Case, async: false

  alias LemonChannels.BindingResolver
  alias LemonChannels.Types.ChatScope

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

  test "/cwd sets topic working directory and new sessions use it" do
    chat_id = 444_003
    topic_id = 101
    msg_id = System.unique_integer([:positive])
    cwd = Path.join(System.tmp_dir!(), "lemon-topic-cwd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(cwd) end)

    MockAPI.set_updates([
      topic_message_update(chat_id, topic_id, "/cwd #{cwd}", msg_id + 1),
      topic_message_update(chat_id, topic_id, "/new", msg_id + 2),
      topic_message_update(chat_id, topic_id, "hello", msg_id + 3)
    ])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, cwd_msg, _reply_to_or_opts, _parse_mode}, 800
    assert cwd_msg =~ "Working directory set for this topic"
    assert cwd_msg =~ Path.expand(cwd)

    assert_receive {:send_message, ^chat_id, new_session_msg, _reply_to_or_opts, _parse_mode},
                   800

    assert String.starts_with?(new_session_msg, "Started a new session.")
    assert String.contains?(new_session_msg, "Model:")
    assert String.contains?(new_session_msg, "Provider:")
    assert String.contains?(new_session_msg, "CWD: #{Path.expand(cwd)}")

    assert_receive {:inbound, inbound}, 1_200
    assert inbound.message.text == "hello"
    assert inbound.meta[:cwd] == Path.expand(cwd)
    assert inbound.meta[:topic_id] == topic_id

    scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}
    assert BindingResolver.resolve_cwd(scope) == Path.expand(cwd)
  end

  test "/cwd clear removes topic working directory override" do
    chat_id = 444_004
    topic_id = 102
    msg_id = System.unique_integer([:positive])
    cwd = Path.join(System.tmp_dir!(), "lemon-topic-cwd-#{System.unique_integer([:positive])}")
    project_id = "tmp_#{System.unique_integer([:positive])}"
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(cwd) end)

    scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}

    _ =
      LemonCore.Store.put(:channels_projects_dynamic, project_id, %{
        root: cwd,
        default_engine: nil
      })

    _ = LemonCore.Store.put(:channels_project_overrides, scope, project_id)
    _ = LemonCore.Store.put(:gateway_project_overrides, scope, project_id)

    on_exit(fn ->
      _ = LemonCore.Store.delete(:channels_projects_dynamic, project_id)
      _ = LemonCore.Store.delete(:channels_project_overrides, scope)
      _ = LemonCore.Store.delete(:gateway_project_overrides, scope)
    end)

    MockAPI.set_updates([
      topic_message_update(chat_id, topic_id, "/cwd clear", msg_id + 1)
    ])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, clear_msg, _reply_to_or_opts, _parse_mode}, 800
    assert clear_msg == "Cleared working directory override for this topic."
    assert BindingResolver.resolve_cwd(scope) == nil
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

  defp topic_message_update(chat_id, topic_id, text, message_id) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => message_id,
        "message_thread_id" => topic_id,
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
