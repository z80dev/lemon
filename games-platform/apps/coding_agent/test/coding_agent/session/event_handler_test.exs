defmodule CodingAgent.Session.EventHandlerTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.EventHandler

  setup do
    test_pid = self()

    callbacks = %{
      set_working_message: fn _state, msg ->
        send(test_pid, {:working_msg, msg})
        :ok
      end,
      notify: fn _state, msg, type ->
        send(test_pid, {:notify, msg, type})
        :ok
      end,
      complete_event_streams: fn _state, event ->
        send(test_pid, {:complete, event})
        :ok
      end,
      maybe_trigger_compaction: fn state -> state end,
      persist_message: fn state, _msg -> state end
    }

    state = %{
      hooks: [],
      is_streaming: true,
      steering_queue: :queue.new(),
      event_streams: %{}
    }

    %{callbacks: callbacks, state: state}
  end

  describe "handle/3" do
    test "{:agent_start} returns state unchanged", %{state: state, callbacks: callbacks} do
      result = EventHandler.handle({:agent_start}, state, callbacks)

      assert result == state
    end

    test "{:turn_start} returns state unchanged", %{state: state, callbacks: callbacks} do
      result = EventHandler.handle({:turn_start}, state, callbacks)

      assert result == state
    end

    test "{:tool_execution_start, id, name, args} sends working message", %{
      state: state,
      callbacks: callbacks
    } do
      EventHandler.handle({:tool_execution_start, "tc_1", "read", %{}}, state, callbacks)

      assert_receive {:working_msg, "Running read..."}
    end

    test "{:tool_execution_end, id, name, result, is_error} clears working message", %{
      state: state,
      callbacks: callbacks
    } do
      result = %{content: "ok"}

      EventHandler.handle({:tool_execution_end, "tc_1", "read", result, false}, state, callbacks)

      assert_receive {:working_msg, nil}
    end

    test "{:agent_end, messages} sets is_streaming to false", %{
      state: state,
      callbacks: callbacks
    } do
      result = EventHandler.handle({:agent_end, []}, state, callbacks)

      assert result.is_streaming == false
      assert_receive {:working_msg, nil}
      assert_receive {:complete, {:agent_end, []}}
    end

    test "{:error, reason, partial} sets is_streaming to false and notifies", %{
      state: state,
      callbacks: callbacks
    } do
      result = EventHandler.handle({:error, :timeout, nil}, state, callbacks)

      assert result.is_streaming == false
      assert_receive {:working_msg, nil}
      assert_receive {:notify, msg, :error}
      assert msg =~ "timeout"
      assert_receive {:complete, {:error, :timeout, nil}}
    end

    test "{:canceled, reason} sets is_streaming to false", %{
      state: state,
      callbacks: callbacks
    } do
      result = EventHandler.handle({:canceled, :user_abort}, state, callbacks)

      assert result.is_streaming == false
      assert_receive {:working_msg, nil}
      assert_receive {:complete, {:canceled, :user_abort}}
    end

    test "unknown event returns state unchanged", %{state: state, callbacks: callbacks} do
      result = EventHandler.handle({:some_unknown_event, :data}, state, callbacks)

      assert result == state
    end
  end

  describe "handle/3 - aborted message paths" do
    test "{:turn_end} with aborted AssistantMessage clears streaming state", %{
      state: state,
      callbacks: callbacks
    } do
      aborted_msg = %Ai.Types.AssistantMessage{stop_reason: :aborted, content: []}

      result = EventHandler.handle({:turn_end, aborted_msg, []}, state, callbacks)

      assert result.is_streaming == false
      assert :queue.is_empty(result.steering_queue)
      assert result.event_streams == %{}
      assert_receive {:working_msg, nil}
      assert_receive {:complete, {:turn_end, ^aborted_msg, []}}
    end

    test "{:turn_end} with non-aborted message returns state unchanged", %{
      state: state,
      callbacks: callbacks
    } do
      normal_msg = %Ai.Types.AssistantMessage{stop_reason: :stop, content: []}

      result = EventHandler.handle({:turn_end, normal_msg, []}, state, callbacks)

      assert result == state
      refute_receive {:working_msg, _}
    end

    test "{:turn_end} with plain map message returns state unchanged", %{
      state: state,
      callbacks: callbacks
    } do
      plain_msg = %{stop_reason: :stop}

      result = EventHandler.handle({:turn_end, plain_msg, []}, state, callbacks)

      assert result == state
    end

    test "{:message_end} with aborted AssistantMessage clears streaming and persists", %{
      callbacks: callbacks
    } do
      test_pid = self()

      persist_callbacks = %{
        callbacks
        | persist_message: fn state, msg ->
            send(test_pid, {:persist, msg})
            state
          end
      }

      state = %{
        hooks: [],
        is_streaming: true,
        steering_queue: :queue.from_list([:item1, :item2]),
        event_streams: %{"s1" => :r1}
      }

      aborted_msg = %Ai.Types.AssistantMessage{stop_reason: :aborted, content: []}

      result = EventHandler.handle({:message_end, aborted_msg}, state, persist_callbacks)

      assert result.is_streaming == false
      assert :queue.is_empty(result.steering_queue)
      assert result.event_streams == %{}
      assert_receive {:persist, ^aborted_msg}
      assert_receive {:working_msg, nil}
      assert_receive {:complete, {:canceled, :assistant_aborted}}
    end

    test "{:message_end} with normal message persists but keeps streaming", %{
      callbacks: callbacks
    } do
      test_pid = self()

      persist_callbacks = %{
        callbacks
        | persist_message: fn state, msg ->
            send(test_pid, {:persist, msg})
            state
          end
      }

      state = %{
        hooks: [],
        is_streaming: true,
        steering_queue: :queue.new(),
        event_streams: %{"s1" => :r1}
      }

      normal_msg = %Ai.Types.AssistantMessage{stop_reason: :stop, content: []}

      result = EventHandler.handle({:message_end, normal_msg}, state, persist_callbacks)

      assert result.is_streaming == true
      assert result.event_streams == %{"s1" => :r1}
      assert_receive {:persist, ^normal_msg}
      refute_receive {:complete, _}
    end
  end

  describe "handle/3 - :message_start" do
    test "returns state unchanged", %{state: state, callbacks: callbacks} do
      message = %{role: :assistant, content: []}

      result = EventHandler.handle({:message_start, message}, state, callbacks)

      assert result == state
    end
  end

  describe "handle/3 - :agent_end clears steering queue" do
    test "drains non-empty steering queue", %{callbacks: callbacks} do
      state = %{
        hooks: [],
        is_streaming: true,
        steering_queue: :queue.from_list([:pending1, :pending2]),
        event_streams: %{"s1" => :r1}
      }

      result = EventHandler.handle({:agent_end, []}, state, callbacks)

      assert :queue.is_empty(result.steering_queue)
      assert result.event_streams == %{}
    end
  end
end
