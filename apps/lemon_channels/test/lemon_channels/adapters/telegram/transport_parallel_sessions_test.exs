defmodule LemonChannels.Adapters.Telegram.TransportParallelSessionsTest do
  alias Elixir.LemonChannels, as: LemonChannels
  use ExUnit.Case, async: false

  alias LemonCore.Store, as: CoreStore
  alias LemonCore.SessionKey

  defmodule ParallelTestRouter do
    def handle_inbound(msg) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:inbound, msg})
      end

      :ok
    end

    def submit(params) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:submit_run, params})
      end

      {:ok, "run_#{System.unique_integer([:positive])}"}
    end
  end

  defmodule ParallelMockAPI do
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
    ensure_session_registry()

    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_gateway_config_env = Application.get_env(:lemon_channels, :gateway)

    :persistent_term.put({ParallelTestRouter, :pid}, self())
    ParallelMockAPI.register_test(self())

    LemonCore.RouterBridge.configure(
      router: ParallelTestRouter,
      run_orchestrator: ParallelTestRouter
    )

    set_bindings([])

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({ParallelMockAPI, :updates})
      :persistent_term.erase({ParallelMockAPI, :pid})
      :persistent_term.erase({ParallelTestRouter, :pid})
      restore_router_bridge(old_router_bridge)
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

    {:ok, _} = Registry.register(LemonRouter.SessionRegistry, base_session_key, %{run_id: "busy"})
    on_exit(fn -> safe_unregister_session(base_session_key) end)

    ParallelMockAPI.set_updates([message_update(chat_id, user_msg_id, "hello")])

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

    {:ok, _} = Registry.register(LemonRouter.SessionRegistry, base_session_key, %{run_id: "busy"})
    on_exit(fn -> safe_unregister_session(base_session_key) end)

    resume = %Elixir.LemonChannels.Types.ResumeToken{engine: "lemon", value: "tok"}
    _ = CoreStore.put(:telegram_selected_resume, {"default", chat_id, nil}, resume)

    ParallelMockAPI.set_updates([message_update(chat_id, user_msg_id, "hello")])

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

    {:ok, _} = Registry.register(LemonRouter.SessionRegistry, base_session_key, %{run_id: "busy"})
    on_exit(fn -> safe_unregister_session(base_session_key) end)

    ParallelMockAPI.set_updates([message_update(chat_id, user_msg_id1, "first")])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:inbound, msg1}, 800
    fork_session_key = msg1.meta[:session_key]
    assert is_binary(fork_session_key)

    # The user's message ID should be stored in telegram_msg_session for reply routing
    # (reactions are set on the user's message, not on a separate progress message)
    stored_session =
      CoreStore.get(:telegram_msg_session, {"default", chat_id, nil, 0, user_msg_id1})

    assert stored_session == fork_session_key

    # Reply to the original user message should route to the forked session
    ParallelMockAPI.set_updates([reply_update(chat_id, user_msg_id2, "followup", user_msg_id1)])

    assert_receive {:inbound, msg2}, 800
    assert msg2.meta[:session_key] == fork_session_key
    refute msg2.meta[:session_key] == base_session_key

    refute_receive {:send_message, ^chat_id, "Resuming session:" <> _rest, _opts, _parse_mode},
                   150
  end

  test "/new clears stale topic reply routing and selected resume state" do
    chat_id = System.unique_integer([:positive])
    topic_id = 777
    reply_to_id = 9_001
    new_msg_id = System.unique_integer([:positive])
    followup_msg_id = System.unique_integer([:positive])

    base_session_key =
      SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :group,
        peer_id: Integer.to_string(chat_id),
        thread_id: Integer.to_string(topic_id)
      })

    stale_session_key = base_session_key <> ":sub:legacy"
    stale_resume = %Elixir.LemonChannels.Types.ResumeToken{engine: "codex", value: "thread_old"}

    _ =
      CoreStore.put(
        :telegram_selected_resume,
        {"default", chat_id, topic_id},
        stale_resume
      )

    _ =
      CoreStore.put(
        :telegram_msg_session,
        {"default", chat_id, topic_id, 0, reply_to_id},
        stale_session_key
      )

    _ =
      CoreStore.put(
        :telegram_msg_resume,
        {"default", chat_id, topic_id, 0, reply_to_id},
        stale_resume
      )

    ParallelMockAPI.set_updates([
      topic_message_update(chat_id, topic_id, new_msg_id, "/new"),
      topic_message_update(chat_id, topic_id, followup_msg_id, "after new", reply_to_id)
    ])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:inbound, msg}, 1_200
    assert msg.message.text == "after new"
    assert msg.meta[:session_key] == base_session_key
    refute msg.meta[:session_key] == stale_session_key

    assert CoreStore.get(:telegram_selected_resume, {"default", chat_id, topic_id}) == nil

    assert eventually(fn ->
             CoreStore.get(:telegram_msg_session, {"default", chat_id, topic_id, 0, reply_to_id}) ==
               nil
           end)

    assert eventually(fn ->
             CoreStore.get(:telegram_msg_resume, {"default", chat_id, topic_id, 0, reply_to_id}) ==
               nil
           end)
  end

  test "/new in topic suppresses stale resume while memory reflection is pending" do
    chat_id = System.unique_integer([:positive])
    topic_id = 778
    new_msg_id = System.unique_integer([:positive])
    followup_msg_id = System.unique_integer([:positive])
    history_run_id = "run_#{System.unique_integer([:positive])}"
    history_started_at = System.system_time(:millisecond) - 1

    base_session_key =
      SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :group,
        peer_id: Integer.to_string(chat_id),
        thread_id: Integer.to_string(topic_id)
      })

    scope = %Elixir.LemonChannels.Types.ChatScope{
      transport: :telegram,
      chat_id: chat_id,
      topic_id: topic_id
    }

    stale_resume = %Elixir.LemonChannels.Types.ResumeToken{engine: "codex", value: "thread_old"}

    _ =
      CoreStore.put(
        :run_history,
        {base_session_key, history_started_at, history_run_id},
        %{
          events: [],
          summary: %{
            prompt: "old prompt",
            completed: %{answer: "old answer"}
          },
          scope: scope,
          session_key: base_session_key,
          run_id: history_run_id,
          started_at: history_started_at
        }
      )

    _ = CoreStore.put(:telegram_selected_resume, {"default", chat_id, topic_id}, stale_resume)

    ParallelMockAPI.set_updates([
      topic_message_update(chat_id, topic_id, new_msg_id, "/new"),
      topic_message_update(chat_id, topic_id, followup_msg_id, "after new")
    ])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:inbound, first_msg}, 1_200

    followup_msg =
      if first_msg.message.text == "after new" do
        first_msg
      else
        assert_receive {:inbound, second_msg}, 1_200
        second_msg
      end

    assert followup_msg.message.text == "after new"
    refute followup_msg.message.text =~ "thread_old"

    assert CoreStore.get(:telegram_selected_resume, {"default", chat_id, topic_id}) == nil
  end

  test "auto-compacts the next prompt after an overflow marker is set" do
    chat_id = System.unique_integer([:positive])
    user_msg_id = System.unique_integer([:positive])
    run_id = "run_#{System.unique_integer([:positive])}"
    started_at = System.system_time(:millisecond) - 1

    session_key =
      SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: Integer.to_string(chat_id)
      })

    scope = %Elixir.LemonChannels.Types.ChatScope{
      transport: :telegram,
      chat_id: chat_id,
      topic_id: nil
    }

    _ =
      CoreStore.put(
        :run_history,
        {session_key, started_at, run_id},
        %{
          events: [],
          summary: %{
            prompt: "Please build a parser",
            completed: %{answer: "Implemented parser and tests."}
          },
          scope: scope,
          session_key: session_key,
          run_id: run_id,
          started_at: started_at
        }
      )

    pending_key = {"default", chat_id, nil}

    _ =
      CoreStore.put(
        :telegram_pending_compaction,
        pending_key,
        %{
          reason: "overflow",
          session_key: session_key,
          set_at_ms: System.system_time(:millisecond)
        }
      )

    ParallelMockAPI.set_updates([
      message_update(chat_id, user_msg_id, "continue and polish output")
    ])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:inbound, msg}, 1_200

    assert msg.meta[:auto_compacted] == true
    assert msg.message.text =~ "<previous_conversation>"
    assert msg.message.text =~ "Please build a parser"
    assert msg.message.text =~ "Implemented parser and tests."
    assert msg.message.text =~ "User:\ncontinue and polish output"
    assert CoreStore.get(:telegram_pending_compaction, pending_key) == nil
  end

  test "approval requests for topic sessions are posted in the same topic" do
    chat_id = System.unique_integer([:positive])
    topic_id = 320
    approval_id = "ap_#{System.unique_integer([:positive])}"

    session_key =
      SessionKey.channel_peer(%{
        agent_id: "default",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :group,
        peer_id: Integer.to_string(chat_id),
        thread_id: Integer.to_string(topic_id)
      })

    assert {:ok, transport_pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    event =
      LemonCore.Event.new(
        :approval_requested,
        %{
          approval_id: approval_id,
          pending: %{
            session_key: session_key,
            tool: "shell",
            action: %{"cmd" => "pwd"}
          }
        }
      )

    send(transport_pid, event)

    assert_receive {:send_message, ^chat_id, text, opts, _parse_mode}, 800
    assert text =~ "Approval requested"
    assert opts["message_thread_id"] == topic_id
  end

  test "ignores topic creation events and waits for the next topic message" do
    chat_id = System.unique_integer([:positive])
    topic_id = 901
    first_msg_id = System.unique_integer([:positive])
    second_msg_id = System.unique_integer([:positive])

    ParallelMockAPI.set_updates([
      topic_created_update(chat_id, topic_id, first_msg_id),
      topic_message_update(chat_id, topic_id, second_msg_id, "hello after create")
    ])

    assert {:ok, _pid} =
             start_transport(%{
               allowed_chat_ids: [chat_id],
               deny_unbound_chats: false
             })

    assert_receive {:inbound, msg}, 1_200
    assert msg.message.text == "hello after create"
    assert msg.peer.thread_id == Integer.to_string(topic_id)
    assert msg.meta[:user_msg_id] == second_msg_id
  end

  defp start_transport(overrides) when is_map(overrides) do
    token = "token-" <> Integer.to_string(System.unique_integer([:positive]))

    config =
      %{
        bot_token: token,
        api_mod: ParallelMockAPI,
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

  defp topic_message_update(chat_id, topic_id, message_id, text, reply_to_id \\ nil) do
    message =
      %{
        "message_id" => message_id,
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "supergroup"},
        "from" => %{"id" => 99, "username" => "tester", "first_name" => "Test"},
        "text" => text,
        "message_thread_id" => topic_id
      }
      |> maybe_put_topic_reply(chat_id, reply_to_id)

    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => message
    }
  end

  defp topic_created_update(chat_id, topic_id, message_id) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => message_id,
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "supergroup"},
        "from" => %{"id" => 99, "username" => "tester", "first_name" => "Test"},
        "is_topic_message" => true,
        "message_thread_id" => topic_id,
        "forum_topic_created" => %{"name" => "topic-#{topic_id}", "icon_color" => 7_326_044}
      }
    }
  end

  defp maybe_put_topic_reply(message, _chat_id, nil), do: message

  defp maybe_put_topic_reply(message, chat_id, reply_to_id) do
    Map.put(message, "reply_to_message", %{
      "message_id" => reply_to_id,
      "date" => 1,
      "chat" => %{"id" => chat_id, "type" => "supergroup"},
      "text" => "earlier"
    })
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

  defp ensure_session_registry do
    if Process.whereis(LemonRouter.SessionRegistry) == nil do
      {:ok, _} = Registry.start_link(keys: :unique, name: LemonRouter.SessionRegistry)
    end

    :ok
  end

  defp safe_unregister_session(key) do
    if Process.whereis(LemonRouter.SessionRegistry) do
      try do
        _ = Registry.unregister(LemonRouter.SessionRegistry, key)
      rescue
        ArgumentError -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp eventually(fun, timeout_ms \\ 1_500) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline_ms) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        false
      else
        Process.sleep(20)
        do_eventually(fun, deadline_ms)
      end
    end
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
      safe_stop(pid)
    end
  catch
    :exit, _ -> :ok
  end

  defp safe_stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp safe_stop(_), do: :ok
end
