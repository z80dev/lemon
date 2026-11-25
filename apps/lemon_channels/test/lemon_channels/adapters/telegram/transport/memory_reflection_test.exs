defmodule LemonChannels.Adapters.Telegram.Transport.MemoryReflectionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonChannels.Adapters.Telegram.Transport.MemoryReflection
  alias LemonCore.{ChatScope, ChatStateStore, RouterBridge, RunHistoryStore, RunRequest, RunStore}

  defmodule CapturingRouter do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def submit(%RunRequest{} = request) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:submitted, request})

      :persistent_term.get(
        {__MODULE__, :submit_result},
        {:ok, "reflection-run"}
      )
    end
  end

  setup do
    previous_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    :persistent_term.put({CapturingRouter, :test_pid}, self())
    :ok = RouterBridge.configure(router: CapturingRouter, run_orchestrator: CapturingRouter)

    on_exit(fn ->
      :persistent_term.erase({CapturingRouter, :test_pid})
      :persistent_term.erase({CapturingRouter, :submit_result})
      restore_router_bridge(previous_router_bridge)
    end)

    :ok
  end

  test "reflects history with a native top-level run despite stale inbound vendor metadata" do
    chat_id = System.unique_integer([:positive])
    thread_id = System.unique_integer([:positive])
    user_msg_id = System.unique_integer([:positive])
    account_id = "reflection-account-#{chat_id}"
    session_key = "telegram:reflection:#{chat_id}"
    history_run_id = "history-#{chat_id}"

    on_exit(fn ->
      RunStore.delete_history(session_key)
      ChatStateStore.delete(session_key)
    end)

    :ok =
      RunHistoryStore.put(
        session_key,
        System.system_time(:millisecond),
        history_run_id,
        %{
          run_id: history_run_id,
          session_key: session_key,
          summary: %{
            prompt: "Remember that I prefer native routing.",
            completed: %{answer: "Noted."}
          }
        }
      )

    :ok = ChatStateStore.put(session_key, %{last_engine: "claude"})

    inbound = %{
      channel_id: "telegram",
      account_id: account_id,
      peer: %{kind: :group, id: Integer.to_string(chat_id)},
      sender: %{id: "sender-#{chat_id}"},
      raw: %{update_id: chat_id},
      meta: %{
        agent_id: "research-agent",
        engine_id: "codex",
        model: "native-model",
        request_marker: "preserve-me"
      }
    }

    callbacks = %{
      maybe_subscribe_to_run: fn run_id -> send(self(), {:subscribed, run_id}) end,
      current_thread_generation: fn _state, ^chat_id, ^thread_id -> 4 end
    }

    assert :ok =
             MemoryReflection.submit_before_new(
               %{account_id: account_id},
               inbound,
               %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id},
               session_key,
               chat_id,
               thread_id,
               user_msg_id,
               callbacks
             )

    assert_receive {:submitted, request}
    assert_receive {:subscribed, "reflection-run"}

    refute Map.has_key?(request.meta, :engine_id)
    refute Map.has_key?(request.meta, "engine_id")
    assert request.agent_id == "research-agent"
    assert request.queue_mode == :collect
    assert request.session_key == MemoryReflection.reflection_session_key(session_key)
    # The router resolves thinking from the PolicyStore rows, not channel meta.
    refute Map.has_key?(request.meta, :thinking_level)
    assert request.meta[:model] == "native-model"
    assert request.meta[:request_marker] == "preserve-me"
    assert request.meta[:record_memories] == true
    assert request.meta[:thread_generation] == 4
    assert request.meta[:user_msg_id] == user_msg_id
    assert request.meta[:channel_id] == inbound.channel_id
    assert request.meta[:account_id] == inbound.account_id
    assert request.meta[:peer] == inbound.peer
    assert request.meta[:sender] == inbound.sender
    assert request.meta[:raw] == inbound.raw
    assert request.prompt =~ "Remember that I prefer native routing."
    assert request.prompt =~ "Noted."
  end

  test "preserves an ambiguous reflection submission and logs only its bounded class" do
    chat_id = System.unique_integer([:positive])
    session_key = "telegram:reflection-failure:#{chat_id}"
    history_run_id = "history-failure-#{chat_id}"
    secret = "router-secret-#{chat_id}"
    failure = {:error, {:unexpected_answer, secret}}

    on_exit(fn -> RunStore.delete_history(session_key) end)

    :ok =
      RunHistoryStore.put(
        session_key,
        System.system_time(:millisecond),
        history_run_id,
        %{
          run_id: history_run_id,
          session_key: session_key,
          summary: %{prompt: "Remember this safely.", completed: %{answer: "Okay."}}
        }
      )

    :persistent_term.put({CapturingRouter, :submit_result}, failure)

    inbound = %{
      channel_id: "telegram",
      account_id: "default",
      peer: %{kind: :dm, id: Integer.to_string(chat_id)},
      sender: %{id: "sender"},
      raw: %{},
      meta: %{}
    }

    callbacks = %{
      maybe_subscribe_to_run: fn run_id -> send(self(), {:subscribed, run_id}) end,
      current_thread_generation: fn _state, _chat_id, _thread_id -> 0 end
    }

    log =
      capture_log([level: :warning], fn ->
        assert ^failure =
                 MemoryReflection.submit_before_new(
                   %{account_id: "default"},
                   inbound,
                   %ChatScope{transport: :telegram, chat_id: chat_id},
                   session_key,
                   chat_id,
                   nil,
                   nil,
                   callbacks
                 )
      end)

    assert_receive {:submitted, %RunRequest{session_key: reflection_session_key}}
    assert reflection_session_key == MemoryReflection.reflection_session_key(session_key)
    refute_receive {:subscribed, _run_id}
    assert log =~ "reason=unexpected_answer"
    refute log =~ secret
    refute log =~ session_key
  end

  test "private cron forwarded history and foreign private runs never enter a legacy reflection" do
    chat_id = System.unique_integer([:positive])
    session_key = "telegram:reflection-private:#{chat_id}"
    on_exit(fn -> RunStore.delete_history(session_key) end)

    put = fn run_id, at, summary ->
      :ok =
        RunHistoryStore.put(session_key, at, run_id, %{
          run_id: run_id,
          session_key: session_key,
          summary: summary
        })
    end

    now = System.system_time(:millisecond)

    # Exactly the summary CronManager forwards into the base session for a cron run.
    put.("cron_notify_cron-#{chat_id}", now, %{
      prompt: "Cron job summary",
      completed: %{ok: true, answer: "PRIVATE-CRON-ANSWER"},
      engine: "cron",
      meta: %{
        origin: :cron,
        cron_forwarded_summary: true,
        memory_ingest: false,
        memory_scope: :unproven,
        cron_run_id: "cron-#{chat_id}"
      }
    })

    put.("private-#{chat_id}", now + 1, %{
      prompt: "PRIVATE-ACTOR-PROMPT",
      completed: %{answer: "PRIVATE-ACTOR-ANSWER"},
      meta: %{
        memory_context_key: "private-actor",
        memory_context_verified: true,
        invocation_context_key: "inv-1"
      }
    })

    put.("unproven-#{chat_id}", now + 2, %{
      prompt: "UNPROVEN-PROMPT",
      completed: %{answer: "x"},
      meta: %{"sharedMemoryGrant" => true}
    })

    put.("legacy-#{chat_id}", now + 3, %{
      prompt: "Legacy preference stays reflectable.",
      completed: %{answer: "Noted."}
    })

    inbound = %{
      channel_id: "telegram",
      account_id: "default",
      peer: %{kind: :dm, id: Integer.to_string(chat_id)},
      sender: %{id: "sender"},
      raw: %{},
      meta: %{}
    }

    callbacks = %{
      maybe_subscribe_to_run: fn _ -> :ok end,
      current_thread_generation: fn _state, _chat_id, _thread_id -> 0 end
    }

    submit = fn inbound ->
      MemoryReflection.submit_before_new(
        %{account_id: "default"},
        inbound,
        %ChatScope{transport: :telegram, chat_id: chat_id},
        session_key,
        chat_id,
        nil,
        nil,
        callbacks
      )
    end

    assert :ok = submit.(inbound)
    assert_receive {:submitted, %RunRequest{prompt: prompt}}
    assert prompt =~ "Legacy preference stays reflectable."
    refute prompt =~ "PRIVATE-CRON-ANSWER"
    refute prompt =~ "PRIVATE-ACTOR"
    refute prompt =~ "UNPROVEN-PROMPT"

    # The matching private actor reflects only its own runs.
    private_meta = %{
      memory_context_key: "private-actor",
      memory_context_verified: true,
      invocation_context_key: "inv-2"
    }

    assert :ok = submit.(%{inbound | meta: private_meta})
    assert_receive {:submitted, %RunRequest{prompt: prompt}}
    assert prompt =~ "PRIVATE-ACTOR-PROMPT"
    refute prompt =~ "Legacy preference"
    refute prompt =~ "PRIVATE-CRON-ANSWER"

    # An unproven reflection context reflects nothing.
    assert :skip = submit.(%{inbound | meta: %{memory_context_key: "private-actor"}})
    refute_receive {:submitted, _}
  end

  test "reflection keys of canonical channel sessions are canonical sub-session keys" do
    key = "agent:default:telegram:default:group:-100:thread:7"
    reflection = MemoryReflection.reflection_session_key(key)

    assert %{kind: :channel_peer, channel_id: "telegram", peer_id: "-100", thread_id: "7"} =
             parsed = LemonCore.SessionKey.parse(reflection)

    assert parsed.sub_id == "new_reflection"
    refute reflection == key

    sub = MemoryReflection.reflection_session_key(key <> ":sub:abc")
    assert %{kind: :channel_peer, sub_id: "abc_new_reflection"} = LemonCore.SessionKey.parse(sub)
  end

  defp restore_router_bridge(nil), do: Application.delete_env(:lemon_core, :router_bridge)
  defp restore_router_bridge(config), do: Application.put_env(:lemon_core, :router_bridge, config)
end
