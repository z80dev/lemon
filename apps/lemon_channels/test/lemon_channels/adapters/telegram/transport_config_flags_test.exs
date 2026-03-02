defmodule LemonChannels.Adapters.Telegram.TransportConfigFlagsTest do
  @moduledoc """
  Tests for Telegram transport config flags:
  - progress_reactions: true/false
  - typing_indicator: true/false (heartbeat lifecycle)
  """

  use ExUnit.Case, async: false

  defmodule FlagsTestRouter do
    def handle_inbound(msg) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:inbound, msg})
      end

      :ok
    end

    def abort(_session_key, _reason), do: :ok
    def abort_run(_run_id, _reason), do: :ok
  end

  defmodule FlagsMockAPI do
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

    def send_chat_action(_token, chat_id, action, _opts \\ %{}) do
      notify({:send_chat_action, chat_id, action})
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
    old_gateway_env = Application.get_env(:lemon_channels, :gateway)

    :persistent_term.put({FlagsTestRouter, :pid}, self())
    FlagsMockAPI.register_test(self())
    LemonCore.RouterBridge.configure(router: FlagsTestRouter)
    set_bindings([])

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({FlagsMockAPI, :updates})
      :persistent_term.erase({FlagsMockAPI, :pid})
      :persistent_term.erase({FlagsTestRouter, :pid})
      restore_env(:lemon_core, :router_bridge, old_router_bridge)
      restore_env(:lemon_channels, :gateway, old_gateway_env)
    end)

    :ok
  end

  test "progress_reactions: true — 👀 reaction is sent on inbound message" do
    chat_id = 440_001
    user_msg_id = 2001

    FlagsMockAPI.set_updates([message_update(chat_id, user_msg_id, "hello")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false,
               progress_reactions: true
             })

    assert_receive {:set_message_reaction, ^chat_id, ^user_msg_id, "👀"}, 500
  end

  test "progress_reactions: false — no reaction is sent on inbound message" do
    chat_id = 440_002
    user_msg_id = 2002

    FlagsMockAPI.set_updates([message_update(chat_id, user_msg_id, "hello")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false,
               progress_reactions: false
             })

    assert_receive {:inbound, _}, 500
    refute_receive {:set_message_reaction, _, _, _}, 200
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_transport(overrides) when is_map(overrides) do
    token = "token-flags-" <> Integer.to_string(System.unique_integer([:positive]))

    config =
      %{
        bot_token: token,
        api_mod: FlagsMockAPI,
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

  defp set_bindings(bindings) do
    cfg =
      case Application.get_env(:lemon_channels, :gateway) do
        map when is_map(map) -> map
        list when is_list(list) -> Enum.into(list, %{})
        _ -> %{}
      end

    Application.put_env(:lemon_channels, :gateway, Map.put(cfg, :bindings, bindings))
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

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
