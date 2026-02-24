defmodule LemonChannels.Adapters.Telegram.TransportCancelTest do
  alias Elixir.LemonChannels, as: LemonChannels
  use ExUnit.Case, async: false

  alias LemonCore.Store

  defmodule CancelTestRouter do
    def handle_inbound(msg) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:inbound, msg})
      end

      :ok
    end

    def abort(session_key, reason) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:abort_session, session_key, reason})
      end

      :ok
    end

    def abort_run(run_id, reason) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:abort_run, run_id, reason})
      end

      :ok
    end
  end

  defmodule CancelMockAPI do
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

    def set_message_reaction(_token, chat_id, message_id, emoji, _opts \\ %{}) do
      notify({:set_message_reaction, chat_id, message_id, emoji})
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
    old_gateway_config_env = Application.get_env(:lemon_channels, :gateway)

    :persistent_term.put({CancelTestRouter, :pid}, self())
    CancelMockAPI.register_test(self())
    LemonCore.RouterBridge.configure(router: CancelTestRouter)
    set_bindings([])

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({CancelMockAPI, :updates})
      :persistent_term.erase({CancelMockAPI, :pid})
      :persistent_term.erase({CancelTestRouter, :pid})
      restore_router_bridge(old_router_bridge)
      restore_gateway_config_env(old_gateway_config_env)
    end)

    :ok
  end

  test "progress '👀' reaction is set on user message" do
    chat_id = 333_001
    user_msg_id = 1234
    CancelMockAPI.set_updates([message_update(chat_id, user_msg_id, "hello")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    # Should set 👀 reaction on the user's message
    assert_receive {:set_message_reaction, ^chat_id, ^user_msg_id, "👀"}, 400
  end

  test "cancel callback cancels the run mapped to the progress message id" do
    chat_id = 333_002
    progress_msg_id = 555
    cb_id = "cb-1"

    session_key =
      LemonCore.SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: Integer.to_string(chat_id)
      })

    _ = Store.put(:telegram_msg_session, {"default", chat_id, nil, progress_msg_id}, session_key)

    CancelMockAPI.set_updates([cancel_callback_update(chat_id, cb_id, progress_msg_id, "lemon:cancel")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:answer_callback, ^cb_id, %{"text" => "cancelling..."}}, 400
    assert_receive {:abort_session, ^session_key, :user_requested}, 400
  end

  test "cancel callback with a run id cancels the run registered under that id" do
    chat_id = 333_003
    progress_msg_id = 777
    cb_id = "cb-2"
    run_id = "run_#{System.unique_integer([:positive])}"

    CancelMockAPI.set_updates([
      cancel_callback_update(chat_id, cb_id, progress_msg_id, "lemon:cancel:" <> run_id)
    ])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:answer_callback, ^cb_id, %{"text" => "cancelling..."}}, 400
    assert_receive {:abort_run, ^run_id, :user_requested}, 400
  end

  defp start_transport(overrides) when is_map(overrides) do
    token = "token-" <> Integer.to_string(System.unique_integer([:positive]))

    config =
      %{
        bot_token: token,
        api_mod: CancelMockAPI,
        poll_interval_ms: 10,
        debounce_ms: 10
      }
      |> Map.merge(overrides)

    Elixir.LemonChannels.Adapters.Telegram.Transport.start_link(config: config)
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
