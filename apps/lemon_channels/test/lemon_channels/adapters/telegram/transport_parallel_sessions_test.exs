defmodule LemonChannels.Adapters.Telegram.TransportParallelSessionsTest do
  use ExUnit.Case, async: false

  alias LemonCore.Store, as: CoreStore
  alias LemonCore.SessionKey
  alias LemonGateway.ThreadWorker

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

    def edit_message_text(_token, chat_id, message_id, text, opts \\ nil) do
      notify({:edit_message_text, chat_id, message_id, text, opts})
      {:ok, %{"ok" => true}}
    end

    def delete_message(_token, chat_id, message_id) do
      notify({:delete_message, chat_id, message_id})
      {:ok, %{"ok" => true}}
    end

    def answer_callback_query(_token, callback_id, opts \\ %{}) do
      notify({:answer_callback, callback_id, opts})
      {:ok, %{"ok" => true}}
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
    old_gateway_config_env = Application.get_env(:lemon_gateway, LemonGateway.Config)

    old_gateway_config_state =
      case Process.whereis(LemonGateway.Config) do
        pid when is_pid(pid) -> :sys.get_state(pid)
        _ -> nil
      end

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
      restore_gateway_config_state(old_gateway_config_state)
      restore_gateway_config_env(old_gateway_config_env)
    end)

    :ok
  end

  test "auto-forks a new session_key when the base session is busy" do
    chat_id = System.unique_integer([:positive])
    user_msg_id = System.unique_integer([:positive])

    base_session_key =
      SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: Integer.to_string(chat_id)
      })

    {:ok, worker_pid} = ThreadWorker.start_link(thread_key: {:session, base_session_key})
    :sys.replace_state(worker_pid, fn st -> Map.put(st, :current_run, self()) end)

    on_exit(fn ->
      if is_pid(worker_pid) and Process.alive?(worker_pid),
        do: GenServer.stop(worker_pid, :normal)
    end)

    MockAPI.set_updates([message_update(chat_id, user_msg_id, "hello")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:inbound, msg}, 800
    assert msg.meta[:session_key] == base_session_key <> ":sub:" <> Integer.to_string(user_msg_id)
    assert msg.meta[:forked_session] == true
  end

  test "does not prefix the selected resume token when auto-forking" do
    chat_id = System.unique_integer([:positive])
    user_msg_id = System.unique_integer([:positive])

    base_session_key =
      SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: Integer.to_string(chat_id)
      })

    {:ok, worker_pid} = ThreadWorker.start_link(thread_key: {:session, base_session_key})
    :sys.replace_state(worker_pid, fn st -> Map.put(st, :current_run, self()) end)

    on_exit(fn ->
      if is_pid(worker_pid) and Process.alive?(worker_pid),
        do: GenServer.stop(worker_pid, :normal)
    end)

    resume = %LemonGateway.Types.ResumeToken{engine: "lemon", value: "tok"}
    _ = CoreStore.put(:telegram_selected_resume, {"default", chat_id, nil}, resume)

    MockAPI.set_updates([message_update(chat_id, user_msg_id, "hello")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:inbound, msg}, 800
    assert msg.meta[:forked_session] == true
    assert msg.message.text == "hello"
  end

  test "reply-to routes followups into the mapped session_key" do
    chat_id = System.unique_integer([:positive])
    user_msg_id1 = System.unique_integer([:positive])
    user_msg_id2 = System.unique_integer([:positive])

    base_session_key =
      SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: Integer.to_string(chat_id)
      })

    {:ok, worker_pid} = ThreadWorker.start_link(thread_key: {:session, base_session_key})
    :sys.replace_state(worker_pid, fn st -> Map.put(st, :current_run, self()) end)

    on_exit(fn ->
      if is_pid(worker_pid) and Process.alive?(worker_pid),
        do: GenServer.stop(worker_pid, :normal)
    end)

    MockAPI.set_updates([message_update(chat_id, user_msg_id1, "first")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:inbound, msg1}, 800
    fork_session_key = msg1.meta[:session_key]
    assert is_binary(fork_session_key)

    progress_msg_id =
      CoreStore.list(:telegram_msg_session)
      |> Enum.find_value(fn
        {{account_id, ^chat_id, nil, msg_id}, ^fork_session_key}
        when account_id in ["default", :default] and msg_id != user_msg_id1 ->
          msg_id

        _ ->
          nil
      end)

    assert is_integer(progress_msg_id)

    MockAPI.set_updates([reply_update(chat_id, user_msg_id2, "followup", progress_msg_id)])

    assert_receive {:inbound, msg2}, 800
    assert msg2.meta[:session_key] == fork_session_key
    refute msg2.meta[:session_key] == base_session_key
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

    LemonChannels.Adapters.Telegram.Transport.start_link(config: config)
  end

  defp message_update(chat_id, message_id, text) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => message_id,
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => 99, "username" => "tester", "first_name" => "Test"},
        "text" => text
      }
    }
  end

  defp reply_update(chat_id, message_id, text, reply_to_id) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => message_id,
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "from" => %{"id" => 99, "username" => "tester", "first_name" => "Test"},
        "text" => text,
        "reply_to_message" => %{
          "message_id" => reply_to_id,
          "date" => 1,
          "chat" => %{"id" => chat_id, "type" => "private"},
          "text" => "Running..."
        }
      }
    }
  end

  defp set_bindings(bindings) do
    case Process.whereis(LemonGateway.Config) do
      pid when is_pid(pid) ->
        :sys.replace_state(pid, fn state ->
          Map.put(state, :bindings, bindings)
        end)

      _ ->
        cfg =
          case Application.get_env(:lemon_gateway, LemonGateway.Config) do
            map when is_map(map) -> map
            list when is_list(list) -> Enum.into(list, %{})
            _ -> %{}
          end

        Application.put_env(
          :lemon_gateway,
          LemonGateway.Config,
          Map.put(cfg, :bindings, bindings)
        )
    end
  end

  defp restore_gateway_config_state(nil), do: :ok

  defp restore_gateway_config_state(old_state) do
    case Process.whereis(LemonGateway.Config) do
      pid when is_pid(pid) -> :sys.replace_state(pid, fn _ -> old_state end)
      _ -> :ok
    end
  end

  defp restore_gateway_config_env(nil) do
    Application.delete_env(:lemon_gateway, LemonGateway.Config)
  end

  defp restore_gateway_config_env(env) do
    Application.put_env(:lemon_gateway, LemonGateway.Config, env)
  end

  defp restore_router_bridge(nil), do: Application.delete_env(:lemon_core, :router_bridge)
  defp restore_router_bridge(config), do: Application.put_env(:lemon_core, :router_bridge, config)

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
