defmodule LemonChannels.Adapters.Telegram.TransportCancelTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Store
  alias LemonGateway.Types.ChatScope

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

  test "progress 'Running…' message includes an inline cancel button" do
    chat_id = 333_001
    user_msg_id = 1234
    MockAPI.set_updates([message_update(chat_id, user_msg_id, "hello")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:send_message, ^chat_id, "Running…", opts, nil}, 400
    assert is_map(opts)
    assert opts["reply_to_message_id"] == user_msg_id

    reply_markup = opts["reply_markup"]
    assert is_map(reply_markup)

    assert reply_markup["inline_keyboard"] == [
             [
               %{
                 "text" => "cancel",
                 "callback_data" => "lemon:cancel"
               }
             ]
           ]
  end

  test "cancel callback cancels the run mapped to the progress message id" do
    chat_id = 333_002
    progress_msg_id = 555
    cb_id = "cb-1"
    scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: nil}

    test_pid = self()

    run_pid =
      spawn(fn ->
        receive do
          msg -> send(test_pid, {:run_received, msg})
        end
      end)

    Store.put_progress_mapping(scope, progress_msg_id, run_pid)

    MockAPI.set_updates([cancel_callback_update(chat_id, cb_id, progress_msg_id, "lemon:cancel")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:answer_callback, ^cb_id, %{"text" => "cancelling..."}}, 400
    assert_receive {:run_received, {:"$gen_cast", {:cancel, :user_requested}}}, 400
  end

  test "cancel callback with a run id cancels the run registered under that id" do
    chat_id = 333_003
    progress_msg_id = 777
    cb_id = "cb-2"
    run_id = "run_#{System.unique_integer([:positive])}"

    test_pid = self()

    run_pid =
      spawn(fn ->
        Registry.register(LemonGateway.RunRegistry, run_id, %{})

        receive do
          msg -> send(test_pid, {:run_received, msg})
        end
      end)

    assert Process.alive?(run_pid)

    MockAPI.set_updates([
      cancel_callback_update(chat_id, cb_id, progress_msg_id, "lemon:cancel:" <> run_id)
    ])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:answer_callback, ^cb_id, %{"text" => "cancelling..."}}, 400
    assert_receive {:run_received, {:"$gen_cast", {:cancel, :user_requested}}}, 400
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

  defp cancel_callback_update(chat_id, cb_id, message_id, data) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "callback_query" => %{
        "id" => cb_id,
        "from" => %{"id" => 99, "username" => "tester", "first_name" => "Test"},
        "data" => data,
        "message" => %{
          "message_id" => message_id,
          "chat" => %{"id" => chat_id, "type" => "private"}
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

