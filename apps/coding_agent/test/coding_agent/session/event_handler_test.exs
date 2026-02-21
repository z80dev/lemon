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

    test "{:tool_start, tool_call} sends working message", %{
      state: state,
      callbacks: callbacks
    } do
      tool_call = %{id: "tc_1", name: "read", arguments: %{}}

      EventHandler.handle({:tool_start, tool_call}, state, callbacks)

      assert_receive {:working_msg, "Running read..."}
    end

    test "{:tool_end, tool_call, result} clears working message", %{
      state: state,
      callbacks: callbacks
    } do
      tool_call = %{id: "tc_1", name: "read", arguments: %{}}
      result = %{content: "ok", is_error: false}

      EventHandler.handle({:tool_end, tool_call, result}, state, callbacks)

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
end
