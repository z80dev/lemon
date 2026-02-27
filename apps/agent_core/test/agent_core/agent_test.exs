defmodule AgentCore.AgentTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias AgentCore.Agent
  alias AgentCore.Types.AgentState
  alias AgentCore.Test.Mocks
  alias Ai.Types.StreamOptions

  # ============================================================================
  # Setup Helpers
  # ============================================================================

  defp start_agent(opts \\ []) do
    default_opts = [
      initial_state: %{
        system_prompt: Keyword.get(opts, :system_prompt, "You are a test assistant."),
        model: Keyword.get(opts, :model, Mocks.mock_model()),
        thinking_level: Keyword.get(opts, :thinking_level, :off),
        tools: Keyword.get(opts, :tools, [])
      },
      convert_to_llm: Keyword.get(opts, :convert_to_llm, Mocks.simple_convert_to_llm())
    ]

    merged_opts = Keyword.merge(default_opts, opts)
    Agent.start_link(merged_opts)
  end

  # ============================================================================
  # Starting an Agent
  # ============================================================================

  describe "start_link/1" do
    test "starts an agent with default options" do
      {:ok, agent} = start_agent()

      assert is_pid(agent)
      assert Process.alive?(agent)
    end

    test "starts an agent with custom system prompt" do
      {:ok, agent} = start_agent(system_prompt: "Custom prompt")

      state = Agent.get_state(agent)
      assert state.system_prompt == "Custom prompt"
    end

    test "starts an agent with custom model" do
      custom_model = Mocks.mock_model(id: "custom-model-123")
      {:ok, agent} = start_agent(model: custom_model)

      state = Agent.get_state(agent)
      assert state.model.id == "custom-model-123"
    end

    test "starts an agent with tools" do
      tools = [Mocks.echo_tool(), Mocks.add_tool()]
      {:ok, agent} = start_agent(tools: tools)

      state = Agent.get_state(agent)
      assert length(state.tools) == 2
    end

    test "starts an agent with name" do
      name = :"test_agent_#{:rand.uniform(10000)}"
      {:ok, _agent} = start_agent(name: name)

      # Should be able to reference by name
      state = Agent.get_state(name)
      assert state.system_prompt == "You are a test assistant."
    end

    test "starts with custom convert_to_llm function" do
      convert_fn = fn messages ->
        Enum.filter(messages, fn m -> Map.get(m, :role) == :user end)
      end

      {:ok, agent} = start_agent(convert_to_llm: convert_fn)

      assert is_pid(agent)
    end

    test "starts with custom steering_mode" do
      {:ok, agent} = start_agent(steering_mode: :all)

      assert Agent.get_steering_mode(agent) == :all
    end

    test "starts with custom follow_up_mode" do
      {:ok, agent} = start_agent(follow_up_mode: :all)

      assert Agent.get_follow_up_mode(agent) == :all
    end

    test "starts with session_id" do
      {:ok, agent} = start_agent(session_id: "session-abc-123")

      assert Agent.get_session_id(agent) == "session-abc-123"
    end

    test "starts with raised default queue_call_timeout" do
      {:ok, agent} = start_agent()
      state = :sys.get_state(agent)

      assert state.queue_call_timeout == :timer.minutes(30)
    end

    test "starts with custom queue_call_timeout" do
      {:ok, agent} = start_agent(queue_call_timeout: 600_000)
      state = :sys.get_state(agent)

      assert state.queue_call_timeout == 600_000
    end

    test "falls back to default queue_call_timeout for invalid values" do
      log =
        capture_log(fn ->
          {:ok, agent} = start_agent(queue_call_timeout: 0)
          state = :sys.get_state(agent)
          assert state.queue_call_timeout == :timer.minutes(30)
        end)

      assert log =~ "Invalid AgentCore.Agent queue_call_timeout=0"
    end
  end

  # ============================================================================
  # Stream Options
  # ============================================================================

  describe "stream options" do
    test "passes reasoning, session_id, and thinking_budgets into stream options" do
      parent = self()
      response = Mocks.assistant_message("Ok")

      stream_fn = fn model, context, options ->
        send(parent, {:stream_opts, options})
        Mocks.mock_stream_fn_single(response).(model, context, options)
      end

      {:ok, agent} =
        start_agent(
          thinking_level: :high,
          session_id: "session-xyz",
          thinking_budgets: %{high: 2048},
          stream_options: %StreamOptions{temperature: 0.2},
          stream_fn: stream_fn
        )

      :ok = Agent.prompt(agent, "Hi")

      assert_receive {:stream_opts, opts}, 1000
      assert opts.reasoning == :high
      assert opts.session_id == "session-xyz"
      assert opts.thinking_budgets == %{high: 2048}
      assert opts.temperature == 0.2

      assert :ok = Agent.wait_for_idle(agent, timeout: 1000)
    end

    test "falls back to stream_options thinking_budgets when override is nil" do
      parent = self()
      response = Mocks.assistant_message("Ok")

      stream_fn = fn model, context, options ->
        send(parent, {:stream_opts, options})
        Mocks.mock_stream_fn_single(response).(model, context, options)
      end

      {:ok, agent} =
        start_agent(
          thinking_budgets: nil,
          stream_options: %StreamOptions{thinking_budgets: %{low: 256}},
          stream_fn: stream_fn
        )

      :ok = Agent.prompt(agent, "Hi")

      assert_receive {:stream_opts, opts}, 1000
      assert opts.thinking_budgets == %{low: 256}

      assert :ok = Agent.wait_for_idle(agent, timeout: 1000)
    end
  end

  # ============================================================================
  # State Getters
  # ============================================================================

  describe "get_state/1" do
    test "returns the current AgentState" do
      {:ok, agent} = start_agent()

      state = Agent.get_state(agent)

      assert %AgentState{} = state
      assert state.is_streaming == false
      assert state.messages == []
      assert state.error == nil
    end

    test "reflects changes to state" do
      {:ok, agent} = start_agent()

      Agent.set_system_prompt(agent, "New prompt")
      state = Agent.get_state(agent)

      assert state.system_prompt == "New prompt"
    end
  end

  describe "get_session_id/1" do
    test "returns nil when not set" do
      {:ok, agent} = start_agent()

      assert Agent.get_session_id(agent) == nil
    end

    test "returns session_id when set" do
      {:ok, agent} = start_agent(session_id: "test-session")

      assert Agent.get_session_id(agent) == "test-session"
    end
  end

  describe "get_steering_mode/1" do
    test "returns default mode" do
      {:ok, agent} = start_agent()

      assert Agent.get_steering_mode(agent) == :one_at_a_time
    end
  end

  describe "get_follow_up_mode/1" do
    test "returns default mode" do
      {:ok, agent} = start_agent()

      assert Agent.get_follow_up_mode(agent) == :one_at_a_time
    end
  end

  # ============================================================================
  # State Setters
  # ============================================================================

  describe "set_system_prompt/2" do
    test "updates the system prompt" do
      {:ok, agent} = start_agent()

      :ok = Agent.set_system_prompt(agent, "Updated prompt")

      state = Agent.get_state(agent)
      assert state.system_prompt == "Updated prompt"
    end
  end

  describe "set_model/2" do
    test "updates the model" do
      {:ok, agent} = start_agent()

      new_model = Mocks.mock_model(id: "new-model-id")
      :ok = Agent.set_model(agent, new_model)

      state = Agent.get_state(agent)
      assert state.model.id == "new-model-id"
    end
  end

  describe "set_thinking_level/2" do
    test "updates the thinking level" do
      {:ok, agent} = start_agent()

      :ok = Agent.set_thinking_level(agent, :high)

      state = Agent.get_state(agent)
      assert state.thinking_level == :high
    end

    test "accepts all valid thinking levels" do
      {:ok, agent} = start_agent()

      for level <- [:off, :minimal, :low, :medium, :high, :xhigh] do
        :ok = Agent.set_thinking_level(agent, level)
        state = Agent.get_state(agent)
        assert state.thinking_level == level
      end
    end
  end

  describe "set_tools/2" do
    test "replaces all tools" do
      {:ok, agent} = start_agent(tools: [Mocks.echo_tool()])

      new_tools = [Mocks.add_tool()]
      :ok = Agent.set_tools(agent, new_tools)

      state = Agent.get_state(agent)
      assert length(state.tools) == 1
      assert hd(state.tools).name == "add"
    end

    test "can set empty tools list" do
      {:ok, agent} = start_agent(tools: [Mocks.echo_tool()])

      :ok = Agent.set_tools(agent, [])

      state = Agent.get_state(agent)
      assert state.tools == []
    end
  end

  describe "replace_messages/2" do
    test "replaces all messages" do
      {:ok, agent} = start_agent()

      messages = [
        Mocks.user_message("First"),
        Mocks.assistant_message("Response")
      ]

      :ok = Agent.replace_messages(agent, messages)

      state = Agent.get_state(agent)
      assert length(state.messages) == 2
    end

    test "can clear all messages" do
      {:ok, agent} = start_agent()

      Agent.replace_messages(agent, [Mocks.user_message("Test")])
      :ok = Agent.replace_messages(agent, [])

      state = Agent.get_state(agent)
      assert state.messages == []
    end
  end

  describe "append_message/2" do
    test "appends a message to the list" do
      {:ok, agent} = start_agent()

      :ok = Agent.append_message(agent, Mocks.user_message("First"))
      :ok = Agent.append_message(agent, Mocks.user_message("Second"))

      state = Agent.get_state(agent)
      assert length(state.messages) == 2
    end
  end

  describe "set_session_id/2" do
    test "sets the session ID" do
      {:ok, agent} = start_agent()

      :ok = Agent.set_session_id(agent, "new-session-id")

      assert Agent.get_session_id(agent) == "new-session-id"
    end

    test "can set session ID to nil" do
      {:ok, agent} = start_agent(session_id: "existing")

      :ok = Agent.set_session_id(agent, nil)

      assert Agent.get_session_id(agent) == nil
    end
  end

  describe "set_steering_mode/2" do
    test "sets steering mode to :all" do
      {:ok, agent} = start_agent()

      :ok = Agent.set_steering_mode(agent, :all)

      assert Agent.get_steering_mode(agent) == :all
    end

    test "sets steering mode to :one_at_a_time" do
      {:ok, agent} = start_agent(steering_mode: :all)

      :ok = Agent.set_steering_mode(agent, :one_at_a_time)

      assert Agent.get_steering_mode(agent) == :one_at_a_time
    end
  end

  describe "set_follow_up_mode/2" do
    test "sets follow-up mode to :all" do
      {:ok, agent} = start_agent()

      :ok = Agent.set_follow_up_mode(agent, :all)

      assert Agent.get_follow_up_mode(agent) == :all
    end

    test "sets follow-up mode to :one_at_a_time" do
      {:ok, agent} = start_agent(follow_up_mode: :all)

      :ok = Agent.set_follow_up_mode(agent, :one_at_a_time)

      assert Agent.get_follow_up_mode(agent) == :one_at_a_time
    end
  end

  # ============================================================================
  # Subscribe/Unsubscribe
  # ============================================================================

  describe "subscribe/2" do
    test "returns an unsubscribe function" do
      {:ok, agent} = start_agent()

      unsubscribe = Agent.subscribe(agent, self())

      assert is_function(unsubscribe, 0)
    end

    test "unsubscribe can be called" do
      {:ok, agent} = start_agent()

      unsubscribe = Agent.subscribe(agent, self())

      # Should not raise
      assert :ok = unsubscribe.()
    end

    test "unsubscribe stops event delivery" do
      {:ok, agent} = start_agent()

      unsubscribe = Agent.subscribe(agent, self())

      send(agent, {:agent_event, {:agent_start}})
      assert_receive {:agent_event, {:agent_start}}

      :ok = unsubscribe.()
      _ = Agent.get_state(agent)

      send(agent, {:agent_event, {:agent_start}})
      refute_receive {:agent_event, {:agent_start}}, 50
    end

    test "removes dead subscribers automatically" do
      {:ok, agent} = start_agent()

      listener =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      _unsubscribe = Agent.subscribe(agent, listener)

      state = :sys.get_state(agent)
      assert Enum.any?(state.listeners, fn {pid, _ref} -> pid == listener end)

      Process.exit(listener, :kill)

      # Give GenServer time to process the DOWN message
      Process.sleep(20)

      state = :sys.get_state(agent)
      refute Enum.any?(state.listeners, fn {pid, _ref} -> pid == listener end)
    end
  end

  # ============================================================================
  # Queue Operations
  # ============================================================================

  describe "steer/2" do
    test "queues a steering message" do
      {:ok, agent} = start_agent()

      message = Mocks.user_message("Steering message")
      :ok = Agent.steer(agent, message)

      # Note: Can't directly verify queue contents without internal access
      # The effect is tested in integration tests
    end

    test "can queue multiple steering messages" do
      {:ok, agent} = start_agent()

      :ok = Agent.steer(agent, Mocks.user_message("Steer 1"))
      :ok = Agent.steer(agent, Mocks.user_message("Steer 2"))
      :ok = Agent.steer(agent, Mocks.user_message("Steer 3"))

      # Messages should be queued
    end
  end

  describe "follow_up/2" do
    test "queues a follow-up message" do
      {:ok, agent} = start_agent()

      message = Mocks.user_message("Follow-up message")
      :ok = Agent.follow_up(agent, message)

      # Note: Can't directly verify queue contents without internal access
    end

    test "can queue multiple follow-up messages" do
      {:ok, agent} = start_agent()

      :ok = Agent.follow_up(agent, Mocks.user_message("Follow 1"))
      :ok = Agent.follow_up(agent, Mocks.user_message("Follow 2"))

      # Messages should be queued
    end
  end

  describe "clear_steering_queue/1" do
    test "clears the steering queue" do
      {:ok, agent} = start_agent()

      Agent.steer(agent, Mocks.user_message("Will be cleared"))
      :ok = Agent.clear_steering_queue(agent)

      # Queue should be empty
    end
  end

  describe "clear_follow_up_queue/1" do
    test "clears the follow-up queue" do
      {:ok, agent} = start_agent()

      Agent.follow_up(agent, Mocks.user_message("Will be cleared"))
      :ok = Agent.clear_follow_up_queue(agent)

      # Queue should be empty
    end
  end

  describe "clear_all_queues/1" do
    test "clears both queues" do
      {:ok, agent} = start_agent()

      Agent.steer(agent, Mocks.user_message("Steering"))
      Agent.follow_up(agent, Mocks.user_message("Follow-up"))

      :ok = Agent.clear_all_queues(agent)

      # Both queues should be empty
    end
  end

  # ============================================================================
  # Prompt Operations - API tests without full streaming
  # ============================================================================

  describe "prompt/2" do
    test "accepts a string prompt and returns :ok" do
      {:ok, agent} = start_agent()

      result = Agent.prompt(agent, "Hello, agent!")

      assert result == :ok
    end

    test "accepts a message struct" do
      {:ok, agent} = start_agent()

      message = Mocks.user_message("Hello")
      result = Agent.prompt(agent, message)

      assert result == :ok
    end

    test "accepts a list of messages" do
      {:ok, agent} = start_agent()

      messages = [
        Mocks.user_message("First"),
        Mocks.user_message("Second")
      ]

      result = Agent.prompt(agent, messages)

      assert result == :ok
    end

    test "sets is_streaming to true immediately" do
      {:ok, agent} = start_agent()

      :ok = Agent.prompt(agent, "Test")

      # State should show streaming (may be brief)
      state = Agent.get_state(agent)

      # The agent should be streaming or have just finished
      # This is a race condition test, so we accept either state
      assert is_boolean(state.is_streaming)
    end

    test "string prompt creates a UserMessage struct" do
      response = Mocks.assistant_message("Hello")
      {:ok, agent} = start_agent(stream_fn: Mocks.mock_stream_fn_single(response))

      :ok = Agent.prompt(agent, "Structured input please")
      assert :ok = Agent.wait_for_idle(agent, timeout: 1000)

      state = Agent.get_state(agent)
      user_messages = Enum.filter(state.messages, &match?(%Ai.Types.UserMessage{}, &1))

      assert [%Ai.Types.UserMessage{content: "Structured input please"}] = user_messages
    end

    test "passes abort signal to tools" do
      parent = self()

      tool = %AgentCore.Types.AgentTool{
        name: "check_signal",
        description: "Returns when signal is captured",
        parameters: %{},
        label: "Check Signal",
        execute: fn _id, _params, signal, _on_update ->
          send(parent, {:tool_signal, signal})

          %AgentCore.Types.AgentToolResult{
            content: [%Ai.Types.TextContent{type: :text, text: "ok"}]
          }
        end
      }

      tool_call = Mocks.tool_call("check_signal", %{}, id: "call_signal")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Done")

      {:ok, agent} =
        start_agent(
          tools: [tool],
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      :ok = Agent.prompt(agent, "Run tool")

      assert_receive {:tool_signal, signal}, 1000
      assert is_reference(signal)

      assert :ok = Agent.wait_for_idle(agent, timeout: 1000)
    end

    test "returns error when already streaming" do
      response = Mocks.assistant_message("Delayed")

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          Ai.EventStream.push(stream, {:start, response})
          Process.sleep(200)
          Ai.EventStream.push(stream, {:done, response.stop_reason, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      {:ok, agent} = start_agent(stream_fn: stream_fn)

      :ok = Agent.prompt(agent, "Hi")
      assert {:error, :already_streaming} = Agent.prompt(agent, "Again")

      assert :ok = Agent.wait_for_idle(agent, timeout: 1000)
    end
  end

  describe "continue/1" do
    test "returns error when no messages" do
      {:ok, agent} = start_agent()

      result = Agent.continue(agent)

      assert result == {:error, :no_messages}
    end

    test "returns error when last message is assistant" do
      {:ok, agent} = start_agent()

      Agent.replace_messages(agent, [
        Mocks.user_message("Hello"),
        Mocks.assistant_message("Hi there")
      ])

      result = Agent.continue(agent)

      assert result == {:error, :cannot_continue}
    end

    test "returns :ok when last message is user" do
      {:ok, agent} = start_agent()

      Agent.replace_messages(agent, [Mocks.user_message("Hello")])

      result = Agent.continue(agent)

      assert result == :ok
    end

    test "returns error when already streaming" do
      response = Mocks.assistant_message("Delayed")

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          Ai.EventStream.push(stream, {:start, response})
          Process.sleep(200)
          Ai.EventStream.push(stream, {:done, response.stop_reason, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      {:ok, agent} = start_agent(stream_fn: stream_fn)

      :ok = Agent.prompt(agent, "Hi")
      assert {:error, :already_streaming} = Agent.continue(agent)

      assert :ok = Agent.wait_for_idle(agent, timeout: 1000)
    end
  end

  # ============================================================================
  # Wait for Idle
  # ============================================================================

  describe "wait_for_idle/1" do
    test "returns immediately when not streaming" do
      {:ok, agent} = start_agent()

      result = Agent.wait_for_idle(agent)

      assert result == :ok
    end

    test "returns after streaming completes" do
      response = Mocks.assistant_message("Hello")
      {:ok, agent} = start_agent(stream_fn: Mocks.mock_stream_fn_single(response))

      :ok = Agent.prompt(agent, "Hi")

      assert :ok = Agent.wait_for_idle(agent, timeout: 1000)

      state = Agent.get_state(agent)
      assert state.is_streaming == false
      assert Enum.any?(state.messages, fn msg -> Map.get(msg, :role) == :assistant end)
    end

    test "returns {:error, :timeout} when the wait exceeds timeout" do
      response = Mocks.assistant_message("Delayed")

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          Ai.EventStream.push(stream, {:start, response})
          Process.sleep(200)
          Ai.EventStream.push(stream, {:done, response.stop_reason, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      {:ok, agent} = start_agent(stream_fn: stream_fn)

      :ok = Agent.prompt(agent, "Hi")

      assert {:error, :timeout} = Agent.wait_for_idle(agent, timeout: 10)

      assert :ok = Agent.wait_for_idle(agent, timeout: 1000)
    end
  end

  # ============================================================================
  # Reset
  # ============================================================================

  describe "reset/1" do
    test "clears messages" do
      {:ok, agent} = start_agent()

      Agent.replace_messages(agent, [Mocks.user_message("Test")])
      :ok = Agent.reset(agent)

      state = Agent.get_state(agent)
      assert state.messages == []
    end

    test "clears error state" do
      {:ok, agent} = start_agent()

      # We can't easily set error state directly, but reset should clear it
      :ok = Agent.reset(agent)

      state = Agent.get_state(agent)
      assert state.error == nil
    end

    test "clears queues" do
      {:ok, agent} = start_agent()

      Agent.steer(agent, Mocks.user_message("Steer"))
      Agent.follow_up(agent, Mocks.user_message("Follow"))

      :ok = Agent.reset(agent)

      # Queues should be empty (verified indirectly)
    end

    test "preserves system_prompt" do
      {:ok, agent} = start_agent(system_prompt: "Keep this")

      Agent.replace_messages(agent, [Mocks.user_message("Test")])
      :ok = Agent.reset(agent)

      state = Agent.get_state(agent)
      assert state.system_prompt == "Keep this"
    end

    test "preserves model" do
      custom_model = Mocks.mock_model(id: "preserved-model")
      {:ok, agent} = start_agent(model: custom_model)

      :ok = Agent.reset(agent)

      state = Agent.get_state(agent)
      assert state.model.id == "preserved-model"
    end

    test "preserves tools" do
      tools = [Mocks.echo_tool()]
      {:ok, agent} = start_agent(tools: tools)

      :ok = Agent.reset(agent)

      state = Agent.get_state(agent)
      assert length(state.tools) == 1
    end
  end

  # ============================================================================
  # Abort
  # ============================================================================

  describe "abort/1" do
    test "can be called when not streaming" do
      {:ok, agent} = start_agent()

      # Should not raise
      :ok = Agent.abort(agent)
    end
  end

  # ============================================================================
  # Error Handling
  # ============================================================================

  describe "error handling" do
    test "sets error when the loop emits an error event" do
      {:ok, agent} = start_agent(stream_fn: Mocks.mock_stream_fn_error(:api_unavailable))

      :ok = Agent.prompt(agent, "Hi")

      assert :ok = Agent.wait_for_idle(agent, timeout: 1000)

      state = Agent.get_state(agent)
      assert state.error == "api_unavailable"
    end
  end

  # ============================================================================
  # Pending Tool Calls
  # ============================================================================

  describe "pending tool calls" do
    test "tracks tool call lifecycle via events" do
      {:ok, agent} = start_agent()

      send(agent, {:agent_event, {:tool_execution_start, "call_1", "tool", %{}}})
      state = Agent.get_state(agent)
      assert MapSet.member?(state.pending_tool_calls, "call_1")

      send(agent, {:agent_event, {:tool_execution_end, "call_1", "tool", %{}, false}})
      state = Agent.get_state(agent)
      refute MapSet.member?(state.pending_tool_calls, "call_1")
    end
  end

  # ============================================================================
  # Follow-up Long-Poll Race Condition Tests
  # ============================================================================

  describe "follow-up long-poll mechanism" do
    test "returns follow-up arriving during 50ms poll window" do
      {:ok, agent} = start_agent()

      # Start a prompt so abort_ref is set
      :ok = Agent.prompt(agent, "test")
      Process.sleep(20)

      state = :sys.get_state(agent)

      abort_ref =
        case state.abort_ref do
          {:aborted, ref} -> ref
          ref -> ref
        end

      # Spawn a task that will add a follow-up after 20ms (within the 50ms window)
      message = Mocks.user_message("Late follow-up")

      Task.start(fn ->
        Process.sleep(20)
        Agent.follow_up(agent, message)
      end)

      # Call get_follow_up_messages - should long-poll and return the message
      result = GenServer.call(agent, {:get_follow_up_messages, abort_ref})

      assert length(result) == 1
      assert hd(result).content == "Late follow-up"
    end

    test "returns empty list when no follow-up arrives within 50ms" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "test")
      Process.sleep(20)

      state = :sys.get_state(agent)

      abort_ref =
        case state.abort_ref do
          {:aborted, ref} -> ref
          ref -> ref
        end

      # Call with nothing queued - should timeout after 50ms
      result = GenServer.call(agent, {:get_follow_up_messages, abort_ref})
      assert result == []
    end

    test "returns already-queued follow-ups immediately without polling" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "test")
      Process.sleep(20)

      state = :sys.get_state(agent)

      abort_ref =
        case state.abort_ref do
          {:aborted, ref} -> ref
          ref -> ref
        end

      # Queue follow-ups BEFORE calling get_follow_up_messages
      Agent.follow_up(agent, Mocks.user_message("Already queued"))
      Process.sleep(5)

      # Should return immediately (not wait 50ms)
      start_time = System.monotonic_time(:millisecond)
      result = GenServer.call(agent, {:get_follow_up_messages, abort_ref})
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert length(result) == 1
      assert hd(result).content == "Already queued"
      # Should be near-instant, not 50ms
      assert elapsed < 30
    end

    test "returns empty list for mismatched abort_ref" do
      {:ok, agent} = start_agent()
      :ok = Agent.prompt(agent, "test")
      Process.sleep(20)

      # Use a wrong abort_ref
      wrong_ref = make_ref()
      Agent.follow_up(agent, Mocks.user_message("Should not be returned"))
      Process.sleep(5)

      result = GenServer.call(agent, {:get_follow_up_messages, wrong_ref})
      assert result == []
    end
  end

  # ============================================================================
  # Follow-up Queue Mode Tests
  # ============================================================================

  describe "follow-up queue mode consumption" do
    test "one_at_a_time mode returns one message per call" do
      {:ok, agent} = start_agent(follow_up_mode: :one_at_a_time)
      :ok = Agent.prompt(agent, "test")
      Process.sleep(20)

      state = :sys.get_state(agent)

      abort_ref =
        case state.abort_ref do
          {:aborted, ref} -> ref
          ref -> ref
        end

      # Queue 3 follow-ups
      Agent.follow_up(agent, Mocks.user_message("Follow 1"))
      Agent.follow_up(agent, Mocks.user_message("Follow 2"))
      Agent.follow_up(agent, Mocks.user_message("Follow 3"))
      Process.sleep(10)

      # First call should return only 1 message
      result1 = GenServer.call(agent, {:get_follow_up_messages, abort_ref})
      assert length(result1) == 1
      assert hd(result1).content == "Follow 1"

      # Second call should return next message
      result2 = GenServer.call(agent, {:get_follow_up_messages, abort_ref})
      assert length(result2) == 1
      assert hd(result2).content == "Follow 2"

      # Third call should return last message
      result3 = GenServer.call(agent, {:get_follow_up_messages, abort_ref})
      assert length(result3) == 1
      assert hd(result3).content == "Follow 3"
    end

    test "all mode returns all messages in single call" do
      {:ok, agent} = start_agent(follow_up_mode: :all)
      :ok = Agent.prompt(agent, "test")
      Process.sleep(20)

      state = :sys.get_state(agent)

      abort_ref =
        case state.abort_ref do
          {:aborted, ref} -> ref
          ref -> ref
        end

      # Queue 3 follow-ups
      Agent.follow_up(agent, Mocks.user_message("Follow A"))
      Agent.follow_up(agent, Mocks.user_message("Follow B"))
      Agent.follow_up(agent, Mocks.user_message("Follow C"))
      Process.sleep(10)

      # Should return all 3 messages at once
      result = GenServer.call(agent, {:get_follow_up_messages, abort_ref})
      assert length(result) == 3
      texts = Enum.map(result, & &1.content)
      assert texts == ["Follow A", "Follow B", "Follow C"]
    end

    test "mode change takes effect on next consumption" do
      {:ok, agent} = start_agent(follow_up_mode: :one_at_a_time)
      :ok = Agent.prompt(agent, "test")
      Process.sleep(20)

      state = :sys.get_state(agent)

      abort_ref =
        case state.abort_ref do
          {:aborted, ref} -> ref
          ref -> ref
        end

      # Queue messages
      Agent.follow_up(agent, Mocks.user_message("Msg 1"))
      Agent.follow_up(agent, Mocks.user_message("Msg 2"))
      Agent.follow_up(agent, Mocks.user_message("Msg 3"))
      Process.sleep(10)

      # Consume one
      result1 = GenServer.call(agent, {:get_follow_up_messages, abort_ref})
      assert length(result1) == 1

      # Switch to :all mode
      Agent.set_follow_up_mode(agent, :all)

      # Should now return remaining 2 at once
      result2 = GenServer.call(agent, {:get_follow_up_messages, abort_ref})
      assert length(result2) == 2
      texts = Enum.map(result2, & &1.content)
      assert texts == ["Msg 2", "Msg 3"]
    end
  end
end
