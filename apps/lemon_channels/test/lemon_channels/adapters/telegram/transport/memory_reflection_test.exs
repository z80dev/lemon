defmodule LemonChannels.Adapters.Telegram.Transport.MemoryReflectionTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Transport.MemoryReflection
  alias LemonChannels.Telegram.StateStore
  alias LemonCore.{ChatScope, ChatStateStore, RouterBridge, RunHistoryStore, RunRequest, RunStore}

  defmodule CapturingRouter do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def submit(%RunRequest{} = request) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:submitted, request})
      {:ok, "reflection-run"}
    end
  end

  setup do
    previous_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    :persistent_term.put({CapturingRouter, :test_pid}, self())
    :ok = RouterBridge.configure(router: CapturingRouter, run_orchestrator: CapturingRouter)

    on_exit(fn ->
      :persistent_term.erase({CapturingRouter, :test_pid})
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
    thinking_key = {account_id, chat_id, thread_id}

    on_exit(fn ->
      RunStore.delete_history(session_key)
      ChatStateStore.delete(session_key)
      StateStore.delete_default_thinking(thinking_key)
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
    :ok = StateStore.put_default_thinking(thinking_key, "high")

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
      current_thread_generation: fn _state, ^chat_id, ^thread_id -> 4 end,
      maybe_put: fn
        map, _key, nil -> map
        map, key, value -> Map.put(map, key, value)
      end
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
    assert request.meta[:thinking_level] == "high"
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

  defp restore_router_bridge(nil), do: Application.delete_env(:lemon_core, :router_bridge)
  defp restore_router_bridge(config), do: Application.put_env(:lemon_core, :router_bridge, config)
end
