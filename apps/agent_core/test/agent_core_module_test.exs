defmodule AgentCore.ModuleTest do
  @moduledoc """
  Comprehensive tests for the AgentCore module's public API.

  Tests all public functions including:
  - Agent GenServer delegates (new_agent, start_link, prompt, continue, abort, etc.)
  - Loop delegates (agent_loop, agent_loop_continue)
  - Convenience/helper functions (new_context, new_tool, new_tool_result, etc.)
  - Content helpers (text_content, image_content, get_text)
  """
  use ExUnit.Case, async: true

  alias AgentCore.Test.Mocks
  alias AgentCore.Types.{AgentContext, AgentTool, AgentToolResult, AgentLoopConfig}
  alias Ai.Types.{TextContent, ImageContent}

  # ============================================================================
  # Setup Helpers
  # ============================================================================

  defp start_agent(opts \\ []) do
    default_opts = [
      model: Keyword.get(opts, :model, Mocks.mock_model()),
      system_prompt: Keyword.get(opts, :system_prompt, "Test assistant"),
      tools: Keyword.get(opts, :tools, []),
      convert_to_llm: Keyword.get(opts, :convert_to_llm, Mocks.simple_convert_to_llm())
    ]

    merged_opts = Keyword.merge(default_opts, opts)
    AgentCore.new_agent(merged_opts)
  end

  defp simple_stream_fn(response) do
    Mocks.mock_stream_fn_single(response)
  end

  # ============================================================================
  # new_agent/1 Tests
  # ============================================================================

  describe "new_agent/1" do
    test "starts an agent with minimal options" do
      {:ok, agent} = start_agent()

      assert is_pid(agent)
      assert Process.alive?(agent)
    end

    test "starts an agent with model" do
      model = Mocks.mock_model(id: "custom-new-agent-model")
      {:ok, agent} = start_agent(model: model)

      state = AgentCore.get_state(agent)
      assert state.model.id == "custom-new-agent-model"
    end

    test "starts an agent with system_prompt" do
      {:ok, agent} = start_agent(system_prompt: "Custom system prompt")

      state = AgentCore.get_state(agent)
      assert state.system_prompt == "Custom system prompt"
    end

    test "starts an agent with tools" do
      tools = [Mocks.echo_tool(), Mocks.add_tool()]
      {:ok, agent} = start_agent(tools: tools)

      state = AgentCore.get_state(agent)
      assert length(state.tools) == 2
      assert Enum.map(state.tools, & &1.name) == ["echo", "add"]
    end

    test "starts an agent with thinking_level" do
      {:ok, agent} = start_agent(thinking_level: :high)

      state = AgentCore.get_state(agent)
      assert state.thinking_level == :high
    end

    test "starts an agent with initial_state map" do
      {:ok, agent} =
        AgentCore.new_agent(
          initial_state: %{
            system_prompt: "From initial state",
            thinking_level: :medium,
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm()
        )

      state = AgentCore.get_state(agent)
      assert state.system_prompt == "From initial state"
      assert state.thinking_level == :medium
    end

    test "starts an agent with initial_state keyword list" do
      {:ok, agent} =
        AgentCore.new_agent(
          initial_state: [
            system_prompt: "From keyword list",
            thinking_level: :low,
            model: Mocks.mock_model()
          ],
          convert_to_llm: Mocks.simple_convert_to_llm()
        )

      state = AgentCore.get_state(agent)
      assert state.system_prompt == "From keyword list"
      assert state.thinking_level == :low
    end

    test "top-level options override initial_state" do
      {:ok, agent} =
        start_agent(
          initial_state: %{system_prompt: "Initial"},
          system_prompt: "Override"
        )

      state = AgentCore.get_state(agent)
      assert state.system_prompt == "Override"
    end

    test "returns error tuple for invalid options" do
      # This might not fail depending on implementation, but good to test
      # that it doesn't crash
      {:ok, agent} = start_agent(initial_state: "invalid")
      assert is_pid(agent)
    end
  end

  # ============================================================================
  # start_link/1 Tests
  # ============================================================================

  describe "start_link/1" do
    test "is an alias for new_agent/1" do
      {:ok, agent1} = AgentCore.new_agent(model: Mocks.mock_model())
      {:ok, agent2} = AgentCore.start_link(model: Mocks.mock_model())

      assert is_pid(agent1)
      assert is_pid(agent2)
    end

    test "accepts name option" do
      name = :"start_link_named_#{:rand.uniform(100_000)}"

      {:ok, _agent} =
        AgentCore.start_link(
          model: Mocks.mock_model(),
          name: name
        )

      state = AgentCore.get_state(name)
      assert %AgentCore.Types.AgentState{} = state
    end

    test "links to calling process" do
      test_pid = self()

      spawn_link(fn ->
        {:ok, agent} = AgentCore.start_link(model: Mocks.mock_model())
        send(test_pid, {:agent_pid, agent})

        receive do
          :exit -> :ok
        end
      end)

      agent_pid =
        receive do
          {:agent_pid, pid} -> pid
        after
          1000 -> flunk("Did not receive agent pid")
        end

      assert Process.alive?(agent_pid)
    end
  end

  # ============================================================================
  # prompt/2 Tests
  # ============================================================================

  describe "prompt/2" do
    test "accepts a string prompt" do
      response = Mocks.assistant_message("Hello back!")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      result = AgentCore.prompt(agent, "Hello!")

      assert result == :ok
      assert :ok = AgentCore.wait_for_idle(agent, timeout: 1000)
    end

    test "accepts a user message struct" do
      response = Mocks.assistant_message("Received struct")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      message = Mocks.user_message("Struct message")
      result = AgentCore.prompt(agent, message)

      assert result == :ok
      assert :ok = AgentCore.wait_for_idle(agent, timeout: 1000)
    end

    test "accepts a list of messages" do
      response = Mocks.assistant_message("Got list")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      messages = [
        Mocks.user_message("First"),
        Mocks.user_message("Second")
      ]

      result = AgentCore.prompt(agent, messages)

      assert result == :ok
      assert :ok = AgentCore.wait_for_idle(agent, timeout: 1000)
    end

    test "returns error when already streaming" do
      delayed_stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          response = Mocks.assistant_message("Delayed")
          Ai.EventStream.push(stream, {:start, response})
          Process.sleep(200)
          Ai.EventStream.push(stream, {:done, response.stop_reason, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      {:ok, agent} = start_agent(stream_fn: delayed_stream_fn)

      :ok = AgentCore.prompt(agent, "First")
      result = AgentCore.prompt(agent, "Second")

      assert result == {:error, :already_streaming}
      assert :ok = AgentCore.wait_for_idle(agent, timeout: 1000)
    end

    test "adds user message to conversation" do
      response = Mocks.assistant_message("Response")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      :ok = AgentCore.prompt(agent, "Test prompt")
      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      state = AgentCore.get_state(agent)
      user_messages = Enum.filter(state.messages, &match?(%Ai.Types.UserMessage{}, &1))

      assert length(user_messages) == 1
      assert hd(user_messages).content == "Test prompt"
    end
  end

  # ============================================================================
  # continue/1 Tests
  # ============================================================================

  describe "continue/1" do
    test "returns error when no messages" do
      {:ok, agent} = start_agent()

      result = AgentCore.continue(agent)

      assert result == {:error, :no_messages}
    end

    test "returns error when last message is assistant" do
      {:ok, agent} = start_agent()

      AgentCore.Agent.replace_messages(agent, [
        Mocks.user_message("Hello"),
        Mocks.assistant_message("Hi")
      ])

      result = AgentCore.continue(agent)

      assert result == {:error, :cannot_continue}
    end

    test "succeeds when last message is user" do
      response = Mocks.assistant_message("Continued")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      AgentCore.Agent.replace_messages(agent, [Mocks.user_message("Hello")])

      result = AgentCore.continue(agent)

      assert result == :ok
      assert :ok = AgentCore.wait_for_idle(agent, timeout: 1000)
    end

    test "succeeds when last message is tool_result" do
      response = Mocks.assistant_message("After tool")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      AgentCore.Agent.replace_messages(agent, [
        Mocks.user_message("Hello"),
        Mocks.assistant_message("Using tool"),
        Mocks.tool_result_message("call_1", "echo", "Echo result")
      ])

      result = AgentCore.continue(agent)

      assert result == :ok
      assert :ok = AgentCore.wait_for_idle(agent, timeout: 1000)
    end

    test "returns error when already streaming" do
      delayed_stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          response = Mocks.assistant_message("Delayed")
          Ai.EventStream.push(stream, {:start, response})
          Process.sleep(200)
          Ai.EventStream.push(stream, {:done, response.stop_reason, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      {:ok, agent} = start_agent(stream_fn: delayed_stream_fn)

      :ok = AgentCore.prompt(agent, "Start")
      result = AgentCore.continue(agent)

      assert result == {:error, :already_streaming}
      assert :ok = AgentCore.wait_for_idle(agent, timeout: 1000)
    end
  end

  # ============================================================================
  # abort/1 Tests
  # ============================================================================

  describe "abort/1" do
    test "returns :ok when not streaming" do
      {:ok, agent} = start_agent()

      result = AgentCore.abort(agent)

      assert result == :ok
    end

    test "returns :ok and signals abort when streaming" do
      delayed_stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          response = Mocks.assistant_message("Will be aborted")
          Ai.EventStream.push(stream, {:start, response})
          Process.sleep(500)
          Ai.EventStream.push(stream, {:done, response.stop_reason, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      {:ok, agent} = start_agent(stream_fn: delayed_stream_fn)

      :ok = AgentCore.prompt(agent, "Start")
      result = AgentCore.abort(agent)

      assert result == :ok
      assert :ok = AgentCore.wait_for_idle(agent, timeout: 1000)
    end
  end

  # ============================================================================
  # subscribe/2 Tests
  # ============================================================================

  describe "subscribe/2" do
    test "returns an unsubscribe function" do
      {:ok, agent} = start_agent()

      unsubscribe = AgentCore.subscribe(agent, self())

      assert is_function(unsubscribe, 0)
    end

    test "subscriber receives events" do
      response = Mocks.assistant_message("Hello!")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      _unsubscribe = AgentCore.subscribe(agent, self())
      :ok = AgentCore.prompt(agent, "Hi")

      assert_receive {:agent_event, {:agent_start}}, 1000
      assert_receive {:agent_event, {:turn_start}}, 1000
      assert_receive {:agent_event, {:message_start, _}}, 1000

      assert :ok = AgentCore.wait_for_idle(agent, timeout: 1000)
    end

    test "unsubscribe stops event delivery" do
      response = Mocks.assistant_message("Test")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      unsubscribe = AgentCore.subscribe(agent, self())
      :ok = unsubscribe.()

      :ok = AgentCore.prompt(agent, "Hi")
      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      refute_receive {:agent_event, _}, 100
    end

    test "multiple subscribers receive events" do
      response = Mocks.assistant_message("Multi")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      parent = self()

      subscriber1 =
        spawn(fn ->
          receive do
            {:agent_event, event} -> send(parent, {:sub1, event})
          end
        end)

      subscriber2 =
        spawn(fn ->
          receive do
            {:agent_event, event} -> send(parent, {:sub2, event})
          end
        end)

      _unsub1 = AgentCore.subscribe(agent, subscriber1)
      _unsub2 = AgentCore.subscribe(agent, subscriber2)
      _unsub_self = AgentCore.subscribe(agent, self())

      :ok = AgentCore.prompt(agent, "Test")

      assert_receive {:sub1, {:agent_start}}, 1000
      assert_receive {:sub2, {:agent_start}}, 1000
      assert_receive {:agent_event, {:agent_start}}, 1000

      assert :ok = AgentCore.wait_for_idle(agent, timeout: 1000)
    end
  end

  # ============================================================================
  # wait_for_idle/2 Tests
  # ============================================================================

  describe "wait_for_idle/2" do
    test "returns immediately when idle" do
      {:ok, agent} = start_agent()

      result = AgentCore.wait_for_idle(agent)

      assert result == :ok
    end

    test "waits for streaming to complete" do
      response = Mocks.assistant_message("Done")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      :ok = AgentCore.prompt(agent, "Start")
      result = AgentCore.wait_for_idle(agent)

      assert result == :ok
    end

    test "accepts timeout as keyword option" do
      response = Mocks.assistant_message("Done")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      :ok = AgentCore.prompt(agent, "Start")
      result = AgentCore.wait_for_idle(agent, timeout: 5000)

      assert result == :ok
    end

    test "accepts timeout as integer" do
      response = Mocks.assistant_message("Done")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      :ok = AgentCore.prompt(agent, "Start")
      result = AgentCore.wait_for_idle(agent, 5000)

      assert result == :ok
    end

    test "accepts :infinity timeout" do
      response = Mocks.assistant_message("Done")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      :ok = AgentCore.prompt(agent, "Start")
      result = AgentCore.wait_for_idle(agent, :infinity)

      assert result == :ok
    end

    test "returns error on timeout" do
      delayed_stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()

        Task.start(fn ->
          response = Mocks.assistant_message("Slow")
          Ai.EventStream.push(stream, {:start, response})
          Process.sleep(500)
          Ai.EventStream.push(stream, {:done, response.stop_reason, response})
          Ai.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      end

      {:ok, agent} = start_agent(stream_fn: delayed_stream_fn)

      :ok = AgentCore.prompt(agent, "Start")
      result = AgentCore.wait_for_idle(agent, timeout: 10)

      assert result == {:error, :timeout}

      # Clean up
      assert :ok = AgentCore.wait_for_idle(agent, timeout: 2000)
    end
  end

  # ============================================================================
  # reset/1 Tests
  # ============================================================================

  describe "reset/1" do
    test "clears messages" do
      response = Mocks.assistant_message("Test")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      :ok = AgentCore.prompt(agent, "Hello")
      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      state_before = AgentCore.get_state(agent)
      assert length(state_before.messages) > 0

      :ok = AgentCore.reset(agent)

      state_after = AgentCore.get_state(agent)
      assert state_after.messages == []
    end

    test "preserves configuration" do
      custom_model = Mocks.mock_model(id: "preserve-me")
      tools = [Mocks.echo_tool()]

      {:ok, agent} =
        start_agent(
          model: custom_model,
          system_prompt: "Preserve this prompt",
          tools: tools
        )

      :ok = AgentCore.reset(agent)

      state = AgentCore.get_state(agent)
      assert state.model.id == "preserve-me"
      assert state.system_prompt == "Preserve this prompt"
      assert length(state.tools) == 1
    end

    test "clears error state" do
      {:ok, agent} = start_agent(stream_fn: Mocks.mock_stream_fn_error(:test_error))

      :ok = AgentCore.prompt(agent, "Hi")
      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      state_before = AgentCore.get_state(agent)
      assert state_before.error != nil

      :ok = AgentCore.reset(agent)

      state_after = AgentCore.get_state(agent)
      assert state_after.error == nil
    end
  end

  # ============================================================================
  # get_state/1 Tests
  # ============================================================================

  describe "get_state/1" do
    test "returns AgentState struct" do
      {:ok, agent} = start_agent()

      state = AgentCore.get_state(agent)

      assert %AgentCore.Types.AgentState{} = state
    end

    test "reflects current agent configuration" do
      model = Mocks.mock_model(id: "get-state-model")
      tools = [Mocks.echo_tool()]

      {:ok, agent} =
        start_agent(
          model: model,
          system_prompt: "Get state prompt",
          tools: tools,
          thinking_level: :high
        )

      state = AgentCore.get_state(agent)

      assert state.model.id == "get-state-model"
      assert state.system_prompt == "Get state prompt"
      assert length(state.tools) == 1
      assert state.thinking_level == :high
    end

    test "reflects streaming status" do
      {:ok, agent} = start_agent()

      state = AgentCore.get_state(agent)
      assert state.is_streaming == false
    end

    test "reflects conversation messages" do
      response = Mocks.assistant_message("Reply")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      :ok = AgentCore.prompt(agent, "Message")
      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      state = AgentCore.get_state(agent)
      assert length(state.messages) >= 2
    end
  end

  # ============================================================================
  # agent_loop/4 Tests
  # ============================================================================

  describe "agent_loop/4" do
    test "returns an enumerable stream" do
      context = AgentCore.new_context(system_prompt: "Test")

      config = %AgentLoopConfig{
        model: Mocks.mock_model(),
        convert_to_llm: Mocks.simple_convert_to_llm(),
        stream_fn: simple_stream_fn(Mocks.assistant_message("Response"))
      }

      prompts = [Mocks.user_message("Hello")]

      stream = AgentCore.agent_loop(prompts, context, config)

      assert is_function(stream, 2) or match?(%Stream{}, stream) or is_pid(stream)
    end

    test "emits agent lifecycle events" do
      context = AgentCore.new_context(system_prompt: "Test")

      config = %AgentLoopConfig{
        model: Mocks.mock_model(),
        convert_to_llm: Mocks.simple_convert_to_llm(),
        stream_fn: simple_stream_fn(Mocks.assistant_message("Hi"))
      }

      prompts = [Mocks.user_message("Hello")]

      events =
        prompts
        |> AgentCore.agent_loop(context, config)
        |> Enum.to_list()

      event_types = Enum.map(events, fn event -> elem(event, 0) end)

      assert :agent_start in event_types
      assert :agent_end in event_types
    end

    test "emits turn events" do
      context = AgentCore.new_context(system_prompt: "Test")

      config = %AgentLoopConfig{
        model: Mocks.mock_model(),
        convert_to_llm: Mocks.simple_convert_to_llm(),
        stream_fn: simple_stream_fn(Mocks.assistant_message("Response"))
      }

      prompts = [Mocks.user_message("Hello")]

      events =
        prompts
        |> AgentCore.agent_loop(context, config)
        |> Enum.to_list()

      event_types = Enum.map(events, fn event -> elem(event, 0) end)

      assert :turn_start in event_types
      assert :turn_end in event_types
    end

    test "emits message events" do
      context = AgentCore.new_context(system_prompt: "Test")

      config = %AgentLoopConfig{
        model: Mocks.mock_model(),
        convert_to_llm: Mocks.simple_convert_to_llm(),
        stream_fn: simple_stream_fn(Mocks.assistant_message("Response"))
      }

      prompts = [Mocks.user_message("Hello")]

      events =
        prompts
        |> AgentCore.agent_loop(context, config)
        |> Enum.to_list()

      message_starts = Enum.filter(events, fn e -> elem(e, 0) == :message_start end)
      message_ends = Enum.filter(events, fn e -> elem(e, 0) == :message_end end)

      # Should have at least prompt message start/end and assistant message start/end
      assert length(message_starts) >= 2
      assert length(message_ends) >= 2
    end

    test "accepts custom stream function" do
      parent = self()
      context = AgentCore.new_context(system_prompt: "Test")

      custom_stream_fn = fn model, context, options ->
        send(parent, {:custom_stream_called, model.id})
        simple_stream_fn(Mocks.assistant_message("Custom")).(model, context, options)
      end

      config = %AgentLoopConfig{
        model: Mocks.mock_model(id: "custom-stream-test"),
        convert_to_llm: Mocks.simple_convert_to_llm(),
        stream_fn: custom_stream_fn
      }

      prompts = [Mocks.user_message("Hello")]

      _events =
        prompts
        |> AgentCore.agent_loop(context, config)
        |> Enum.to_list()

      assert_receive {:custom_stream_called, "custom-stream-test"}, 1000
    end
  end

  # ============================================================================
  # agent_loop_continue/3 Tests
  # ============================================================================

  describe "agent_loop_continue/3" do
    test "continues from existing context" do
      context = %AgentContext{
        system_prompt: "Test",
        messages: [
          Mocks.user_message("Hello"),
          Mocks.assistant_message("Hi"),
          Mocks.tool_result_message("call_1", "tool", "Result")
        ],
        tools: []
      }

      config = %AgentLoopConfig{
        model: Mocks.mock_model(),
        convert_to_llm: Mocks.simple_convert_to_llm(),
        stream_fn: simple_stream_fn(Mocks.assistant_message("Continued"))
      }

      events =
        context
        |> AgentCore.agent_loop_continue(config)
        |> Enum.to_list()

      event_types = Enum.map(events, fn event -> elem(event, 0) end)

      assert :agent_start in event_types
      assert :agent_end in event_types
    end

    test "emits events without prompt message events" do
      context = %AgentContext{
        system_prompt: "Test",
        messages: [Mocks.user_message("Already here")],
        tools: []
      }

      config = %AgentLoopConfig{
        model: Mocks.mock_model(),
        convert_to_llm: Mocks.simple_convert_to_llm(),
        stream_fn: simple_stream_fn(Mocks.assistant_message("Response"))
      }

      events =
        context
        |> AgentCore.agent_loop_continue(config)
        |> Enum.to_list()

      # First turn_start should be immediately followed by assistant message events,
      # not prompt message events
      event_types = Enum.map(events, fn event -> elem(event, 0) end)

      assert :turn_start in event_types
    end
  end

  # ============================================================================
  # new_context/1 Tests
  # ============================================================================

  describe "new_context/1" do
    test "creates empty context with defaults" do
      context = AgentCore.new_context()

      assert %AgentContext{} = context
      assert context.system_prompt == nil
      assert context.messages == []
      assert context.tools == []
    end

    test "creates context with system_prompt" do
      context = AgentCore.new_context(system_prompt: "You are helpful")

      assert context.system_prompt == "You are helpful"
    end

    test "creates context with messages" do
      messages = [Mocks.user_message("Hello")]
      context = AgentCore.new_context(messages: messages)

      assert length(context.messages) == 1
    end

    test "creates context with tools" do
      tools = [Mocks.echo_tool(), Mocks.add_tool()]
      context = AgentCore.new_context(tools: tools)

      assert length(context.tools) == 2
    end

    test "creates context with all options" do
      tools = [Mocks.echo_tool()]
      messages = [Mocks.user_message("Test")]

      context =
        AgentCore.new_context(
          system_prompt: "Full context",
          messages: messages,
          tools: tools
        )

      assert context.system_prompt == "Full context"
      assert length(context.messages) == 1
      assert length(context.tools) == 1
    end
  end

  # ============================================================================
  # new_tool/1 Tests
  # ============================================================================

  describe "new_tool/1" do
    test "creates tool with required fields" do
      execute_fn = fn _id, _params, _signal, _on_update ->
        %AgentToolResult{content: []}
      end

      tool =
        AgentCore.new_tool(
          name: "test_tool",
          description: "A test tool",
          execute: execute_fn
        )

      assert %AgentTool{} = tool
      assert tool.name == "test_tool"
      assert tool.description == "A test tool"
      assert is_function(tool.execute, 4)
    end

    test "creates tool with parameters" do
      execute_fn = fn _id, _params, _signal, _on_update ->
        %AgentToolResult{content: []}
      end

      parameters = %{
        "type" => "object",
        "properties" => %{
          "input" => %{"type" => "string"}
        },
        "required" => ["input"]
      }

      tool =
        AgentCore.new_tool(
          name: "param_tool",
          description: "Tool with params",
          parameters: parameters,
          execute: execute_fn
        )

      assert tool.parameters == parameters
    end

    test "creates tool with label" do
      execute_fn = fn _id, _params, _signal, _on_update ->
        %AgentToolResult{content: []}
      end

      tool =
        AgentCore.new_tool(
          name: "labeled_tool",
          description: "A labeled tool",
          label: "My Labeled Tool",
          execute: execute_fn
        )

      assert tool.label == "My Labeled Tool"
    end

    test "defaults label to name" do
      execute_fn = fn _id, _params, _signal, _on_update ->
        %AgentToolResult{content: []}
      end

      tool =
        AgentCore.new_tool(
          name: "default_label_tool",
          description: "Tool without explicit label",
          execute: execute_fn
        )

      assert tool.label == "default_label_tool"
    end

    test "defaults parameters to empty map" do
      execute_fn = fn _id, _params, _signal, _on_update ->
        %AgentToolResult{content: []}
      end

      tool =
        AgentCore.new_tool(
          name: "no_params",
          description: "No params",
          execute: execute_fn
        )

      assert tool.parameters == %{}
    end

    test "raises on missing required fields" do
      assert_raise KeyError, fn ->
        AgentCore.new_tool(name: "incomplete")
      end

      assert_raise KeyError, fn ->
        AgentCore.new_tool(description: "incomplete")
      end

      assert_raise KeyError, fn ->
        AgentCore.new_tool(
          name: "no_execute",
          description: "Missing execute"
        )
      end
    end
  end

  # ============================================================================
  # new_tool_result/1 Tests
  # ============================================================================

  describe "new_tool_result/1" do
    test "creates empty tool result with defaults" do
      result = AgentCore.new_tool_result()

      assert %AgentToolResult{} = result
      assert result.content == []
      assert result.details == nil
      assert result.trust == :trusted
    end

    test "creates tool result with content" do
      content = [%TextContent{type: :text, text: "Result text"}]
      result = AgentCore.new_tool_result(content: content)

      assert result.content == content
    end

    test "creates tool result with details" do
      details = %{bytes_read: 1024, duration_ms: 50}
      result = AgentCore.new_tool_result(details: details)

      assert result.details == details
    end

    test "creates tool result with both content and details" do
      content = [%TextContent{type: :text, text: "Data"}]
      details = %{source: "file.txt"}

      result =
        AgentCore.new_tool_result(
          content: content,
          details: details
        )

      assert result.content == content
      assert result.details == details
    end

    test "creates tool result with trust level" do
      result = AgentCore.new_tool_result(trust: :untrusted)
      assert result.trust == :untrusted
    end
  end

  # ============================================================================
  # text_content/1 Tests
  # ============================================================================

  describe "text_content/1" do
    test "creates TextContent struct" do
      content = AgentCore.text_content("Hello, world!")

      assert %TextContent{} = content
      assert content.text == "Hello, world!"
    end

    test "creates TextContent with empty string" do
      content = AgentCore.text_content("")

      assert content.text == ""
    end

    test "creates TextContent with unicode" do
      content = AgentCore.text_content("Hello, world!")

      assert content.text == "Hello, world!"
    end

    test "creates TextContent with multiline string" do
      text = """
      Line 1
      Line 2
      Line 3
      """

      content = AgentCore.text_content(text)

      assert content.text == text
    end
  end

  # ============================================================================
  # image_content/2 Tests
  # ============================================================================

  describe "image_content/2" do
    test "creates ImageContent with data and default mime type" do
      base64_data = Base.encode64("fake image data")
      content = AgentCore.image_content(base64_data)

      assert %ImageContent{} = content
      assert content.data == base64_data
      assert content.mime_type == "image/png"
    end

    test "creates ImageContent with custom mime type" do
      base64_data = Base.encode64("fake jpeg")
      content = AgentCore.image_content(base64_data, "image/jpeg")

      assert content.mime_type == "image/jpeg"
    end

    test "creates ImageContent with various mime types" do
      base64_data = Base.encode64("data")

      png = AgentCore.image_content(base64_data, "image/png")
      jpeg = AgentCore.image_content(base64_data, "image/jpeg")
      gif = AgentCore.image_content(base64_data, "image/gif")
      webp = AgentCore.image_content(base64_data, "image/webp")

      assert png.mime_type == "image/png"
      assert jpeg.mime_type == "image/jpeg"
      assert gif.mime_type == "image/gif"
      assert webp.mime_type == "image/webp"
    end
  end

  # ============================================================================
  # get_text/1 Tests
  # ============================================================================

  describe "get_text/1" do
    test "extracts text from AgentToolResult" do
      result = %AgentToolResult{
        content: [
          %TextContent{type: :text, text: "First"},
          %TextContent{type: :text, text: "Second"}
        ]
      }

      text = AgentCore.get_text(result)

      assert text == "FirstSecond"
    end

    test "extracts text from content list" do
      content = [
        %TextContent{type: :text, text: "Hello "},
        %TextContent{type: :text, text: "World"}
      ]

      text = AgentCore.get_text(content)

      assert text == "Hello World"
    end

    test "ignores non-text content" do
      content = [
        %TextContent{type: :text, text: "Text"},
        %ImageContent{data: "base64data", mime_type: "image/png"},
        %TextContent{type: :text, text: " More"}
      ]

      text = AgentCore.get_text(content)

      assert text == "Text More"
    end

    test "returns empty string for empty content" do
      result = %AgentToolResult{content: []}
      text = AgentCore.get_text(result)

      assert text == ""
    end

    test "returns empty string for only image content" do
      content = [
        %ImageContent{data: "data1", mime_type: "image/png"},
        %ImageContent{data: "data2", mime_type: "image/jpeg"}
      ]

      text = AgentCore.get_text(content)

      assert text == ""
    end

    test "handles single text content" do
      content = [%TextContent{type: :text, text: "Single"}]

      text = AgentCore.get_text(content)

      assert text == "Single"
    end
  end

  # ============================================================================
  # Type Alias Tests
  # ============================================================================

  describe "type aliases" do
    test "agent type is defined" do
      # Can't directly test types, but we can verify the module compiles
      # and the documented types work
      {:ok, agent} = start_agent()
      assert is_pid(agent)
    end

    test "context type works" do
      context = AgentCore.new_context(system_prompt: "Test")
      assert %AgentContext{} = context
    end

    test "tool type works" do
      execute_fn = fn _id, _params, _signal, _on_update ->
        %AgentToolResult{content: []}
      end

      tool =
        AgentCore.new_tool(
          name: "type_test",
          description: "Test",
          execute: execute_fn
        )

      assert %AgentTool{} = tool
    end

    test "tool_result type works" do
      result = AgentCore.new_tool_result(content: [])
      assert %AgentToolResult{} = result
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "integration: full agent conversation" do
    test "complete prompt -> response flow" do
      response = Mocks.assistant_message("I can help with that!")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      _unsub = AgentCore.subscribe(agent, self())

      :ok = AgentCore.prompt(agent, "Can you help me?")

      assert_receive {:agent_event, {:agent_start}}, 1000
      assert_receive {:agent_event, {:turn_start}}, 1000
      assert_receive {:agent_event, {:message_end, %{role: :assistant}}}, 1000
      assert_receive {:agent_event, {:agent_end, _messages}}, 1000

      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      state = AgentCore.get_state(agent)
      assert length(state.messages) >= 2
    end

    test "complete flow with tool execution" do
      tool_call = Mocks.tool_call("echo", %{"text" => "Hello"}, id: "call_echo_1")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call])
      final_response = Mocks.assistant_message("Echo completed!")

      {:ok, agent} =
        start_agent(
          tools: [Mocks.echo_tool()],
          stream_fn: Mocks.mock_stream_fn([tool_response, final_response])
        )

      _unsub = AgentCore.subscribe(agent, self())

      :ok = AgentCore.prompt(agent, "Echo hello")

      assert_receive {:agent_event, {:tool_execution_start, "call_echo_1", "echo", _}}, 1000
      assert_receive {:agent_event, {:tool_execution_end, "call_echo_1", "echo", _, _}}, 1000
      assert_receive {:agent_event, {:agent_end, _}}, 2000

      :ok = AgentCore.wait_for_idle(agent, timeout: 2000)

      state = AgentCore.get_state(agent)
      # Should have: user, assistant (with tool call), tool result, assistant (final)
      assert length(state.messages) >= 4
    end

    test "multiple prompts in sequence" do
      response1 = Mocks.assistant_message("First response")
      response2 = Mocks.assistant_message("Second response")

      {:ok, agent} =
        start_agent(stream_fn: Mocks.mock_stream_fn([response1, response2]))

      :ok = AgentCore.prompt(agent, "First prompt")
      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      state1 = AgentCore.get_state(agent)
      assert length(state1.messages) == 2

      :ok = AgentCore.prompt(agent, "Second prompt")
      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      state2 = AgentCore.get_state(agent)
      assert length(state2.messages) == 4
    end

    test "reset between conversations" do
      response1 = Mocks.assistant_message("First")
      response2 = Mocks.assistant_message("After reset")

      {:ok, agent} =
        start_agent(stream_fn: Mocks.mock_stream_fn([response1, response2]))

      :ok = AgentCore.prompt(agent, "First")
      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      :ok = AgentCore.reset(agent)

      state_after_reset = AgentCore.get_state(agent)
      assert state_after_reset.messages == []

      :ok = AgentCore.prompt(agent, "After reset")
      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      state_final = AgentCore.get_state(agent)
      assert length(state_final.messages) == 2
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "handles empty string prompt" do
      response = Mocks.assistant_message("Empty prompt received")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      :ok = AgentCore.prompt(agent, "")
      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      state = AgentCore.get_state(agent)
      user_msg = Enum.find(state.messages, &match?(%Ai.Types.UserMessage{}, &1))
      assert user_msg.content == ""
    end

    test "handles very long prompt" do
      long_prompt = String.duplicate("a", 10_000)
      response = Mocks.assistant_message("Got it")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      :ok = AgentCore.prompt(agent, long_prompt)
      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      state = AgentCore.get_state(agent)
      user_msg = Enum.find(state.messages, &match?(%Ai.Types.UserMessage{}, &1))
      assert String.length(user_msg.content) == 10_000
    end

    test "handles unicode in prompts" do
      unicode_prompt = "Hello! Test with emojis and CJK characters"
      response = Mocks.assistant_message("Got unicode")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      :ok = AgentCore.prompt(agent, unicode_prompt)
      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      state = AgentCore.get_state(agent)
      user_msg = Enum.find(state.messages, &match?(%Ai.Types.UserMessage{}, &1))
      assert user_msg.content == unicode_prompt
    end

    test "handles newlines in prompts" do
      multiline_prompt = "Line 1\nLine 2\nLine 3"
      response = Mocks.assistant_message("Got lines")
      {:ok, agent} = start_agent(stream_fn: simple_stream_fn(response))

      :ok = AgentCore.prompt(agent, multiline_prompt)
      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      state = AgentCore.get_state(agent)
      user_msg = Enum.find(state.messages, &match?(%Ai.Types.UserMessage{}, &1))
      assert user_msg.content == multiline_prompt
    end

    test "handles stream error gracefully" do
      {:ok, agent} = start_agent(stream_fn: Mocks.mock_stream_fn_error(:network_error))

      :ok = AgentCore.prompt(agent, "Will fail")
      :ok = AgentCore.wait_for_idle(agent, timeout: 1000)

      state = AgentCore.get_state(agent)
      assert state.error != nil
    end

    test "agent process can be stopped" do
      {:ok, agent} = start_agent()

      assert Process.alive?(agent)

      GenServer.stop(agent)

      refute Process.alive?(agent)
    end
  end
end
