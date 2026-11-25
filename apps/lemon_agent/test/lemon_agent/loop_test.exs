defmodule LemonAgent.LoopTest do
  use ExUnit.Case, async: true

  alias LemonAgent.EventStream
  alias LemonAgent.Loop
  alias LemonAgent.Test.Mocks

  alias LemonAgent.Types.{
    AgentContext,
    AgentLoopConfig,
    AgentTool,
    AgentToolResult,
    ToolSchemaSnapshot
  }

  alias LemonAi.Types.{
    AssistantMessage,
    StreamOptions,
    TextContent,
    ThinkingContent,
    ToolCall,
    ToolResultMessage,
    UserMessage
  }

  # ============================================================================
  # Setup Helpers
  # ============================================================================

  defp simple_context(opts \\ []) do
    AgentContext.new(
      system_prompt: Keyword.get(opts, :system_prompt, "You are a helpful assistant."),
      messages: Keyword.get(opts, :messages, []),
      tools: Keyword.get(opts, :tools, [])
    )
  end

  defp simple_config(opts \\ []) do
    %AgentLoopConfig{
      model: Keyword.get(opts, :model, Mocks.mock_model()),
      convert_to_llm: Keyword.get(opts, :convert_to_llm, Mocks.simple_convert_to_llm()),
      transform_context: Keyword.get(opts, :transform_context, nil),
      get_api_key: Keyword.get(opts, :get_api_key, nil),
      get_steering_messages: Keyword.get(opts, :get_steering_messages, nil),
      get_follow_up_messages: Keyword.get(opts, :get_follow_up_messages, nil),
      max_tool_turns: Keyword.get(opts, :max_tool_turns, 25),
      tool_schema_snapshot: Keyword.get(opts, :tool_schema_snapshot, nil),
      stream_options: Keyword.get(opts, :stream_options, %StreamOptions{}),
      stream_fn: Keyword.get(opts, :stream_fn, nil)
    }
  end

  # One tool-call turn followed by a final "Done" reply.
  defp tool_turn_config(tool_calls, opts \\ []) do
    responses = [
      Mocks.assistant_message_with_tool_calls(tool_calls),
      Mocks.assistant_message("Done")
    ]

    simple_config(Keyword.put(opts, :stream_fn, Mocks.mock_stream_fn(responses)))
  end

  defp tool(name, execute) do
    %AgentTool{
      name: name,
      description: name,
      parameters: %{"type" => "object", "properties" => %{}},
      label: name,
      execute: execute
    }
  end

  defp user_message(text) do
    %UserMessage{
      role: :user,
      content: text,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp run(prompt_text, context, config) do
    Loop.stream([user_message(prompt_text)], context, config) |> Enum.to_list()
  end

  defp tool_ends(events), do: for({:tool_execution_end, _, _, _, _} = event <- events, do: event)

  defp index_of(events, type), do: Enum.find_index(events, &(elem(&1, 0) == type))

  # ============================================================================
  # agent_loop/5 and stream/4
  # ============================================================================

  describe "agent_loop/5 and stream/4" do
    test "emits an ordered lifecycle and returns the prompts and reply as new messages" do
      response = Mocks.assistant_message("Unicode: \u{1F600} Tab: \t Newline: \n")
      prompts = [user_message("First message"), user_message("Second message")]
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      stream = Loop.agent_loop(prompts, simple_context(), config, nil, nil)
      assert is_pid(stream)

      events = EventStream.events(stream) |> Enum.to_list()

      assert {:agent_start} = hd(events)
      assert {:agent_end, messages} = List.last(events)
      assert messages == prompts ++ [response]

      assert for({:message_start, %UserMessage{} = message} <- events, do: message) == prompts
      starts = for {:message_start, message} <- events, do: message
      ends = for {:message_end, message} <- events, do: message
      assert length(starts) == 3
      assert length(ends) == 3
      assert index_of(events, :turn_start) < index_of(events, :message_start)
      assert index_of(events, :turn_end) < index_of(events, :agent_end)
    end

    test "emits a tool schema snapshot for the run" do
      context = simple_context(tools: [Mocks.echo_tool(), Mocks.add_tool()])
      response = Mocks.assistant_message("Response")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      events = run("Test", context, config)

      assert [
               {:agent_start},
               {:tool_schema_snapshot, %ToolSchemaSnapshot{} = snapshot},
               {:turn_start}
               | _
             ] = events

      assert snapshot.tool_names == ["echo", "add"]
      assert snapshot.id =~ ~r/^tool_schema_[a-f0-9]{16}_[a-z0-9]+$/
      assert Enum.map(snapshot.tools, & &1.name) == ["echo", "add"]
      assert Enum.all?(snapshot.tools, &is_nil(&1.execute))
    end

    test "emits explicit loop state transitions for a tool turn" do
      context = simple_context(tools: [Mocks.echo_tool()])

      config =
        tool_turn_config([Mocks.tool_call("echo", %{"text" => "hello"}, id: "call_state")])

      events = run("Echo", context, config)

      transitions =
        for {:loop_state_transition, from, to, _meta} <- events, do: {from, to}

      assert transitions == [
               {nil, :initializing},
               {:initializing, :await_model},
               {:await_model, :normalizing_response},
               {:normalizing_response, :executing_tools},
               {:executing_tools, :awaiting_tool_results},
               {:awaiting_tool_results, :await_model},
               {:await_model, :normalizing_response},
               {:normalizing_response, :finalizing}
             ]
    end

    test "uses configured tool schema snapshot for provider schema and execution" do
      parent = self()
      snapshot = ToolSchemaSnapshot.new([Mocks.echo_tool()])
      context = simple_context(tools: [Mocks.add_tool()])

      canned =
        Mocks.mock_stream_fn([
          Mocks.assistant_message_with_tool_calls([
            Mocks.tool_call("echo", %{"text" => "snapshotted"}, id: "call_snapshot")
          ]),
          Mocks.assistant_message("Done")
        ])

      stream_fn = fn model, llm_context, options ->
        send(parent, {:provider_tools, Enum.map(llm_context.tools, & &1.name)})
        canned.(model, llm_context, options)
      end

      config = simple_config(tool_schema_snapshot: snapshot, stream_fn: stream_fn)

      stream = Loop.agent_loop([user_message("Echo")], context, config, nil, nil)
      {:ok, messages} = EventStream.result(stream)

      assert_receive {:provider_tools, ["echo"]}
      assert_receive {:provider_tools, ["echo"]}

      assert [%ToolResultMessage{tool_name: "echo", is_error: false}] =
               Enum.filter(
                 messages,
                 &match?(%ToolResultMessage{tool_call_id: "call_snapshot"}, &1)
               )
    end

    test "emits terminal fallback when max tool turns are exhausted" do
      {:ok, call_counter} = Agent.start_link(fn -> 0 end)

      stream_fn = fn model, context, options ->
        call_number = Agent.get_and_update(call_counter, &{&1 + 1, &1 + 1})

        response =
          Mocks.assistant_message_with_tool_calls([
            Mocks.tool_call("echo", %{"text" => "again"}, id: "call_#{call_number}")
          ])

        Mocks.mock_stream_fn_single(response).(model, context, options)
      end

      context = simple_context(tools: [Mocks.echo_tool()])
      config = simple_config(stream_fn: stream_fn, max_tool_turns: 1)

      events = run("Loop until stopped", context, config)

      assert Agent.get(call_counter, & &1) == 1

      assert {:loop_budget_exhausted,
              %{reason: :max_tool_turns_exhausted, max_tool_turns: 1, tool_turns: 1}} =
               Enum.find(events, &match?({:loop_budget_exhausted, _}, &1))

      assert Enum.count(events, &match?({:tool_execution_end, _, "echo", _, false}, &1)) == 1

      assert {:agent_end, messages} = List.last(events)

      assert %{role: :assistant, stop_reason: :error, error_message: "max_tool_turns_exhausted"} =
               List.last(messages)

      assert [text] =
               List.last(messages).content
               |> Enum.map(&Map.get(&1, :text))
               |> Enum.reject(&is_nil/1)

      assert text =~ "maximum tool-call turn budget"
    end

    test "accepts stream_fn returning stream directly" do
      response = Mocks.assistant_message("Direct stream response")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single_direct(response))

      assert {:agent_end, [_prompt, ^response]} =
               run("Test", simple_context(), config) |> List.last()
    end

    test "independent loops sharing tools run concurrently" do
      context = simple_context(tools: [Mocks.add_tool()])

      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            config =
              tool_turn_config([Mocks.tool_call("add", %{"a" => i, "b" => 2}, id: "call_#{i}")])

            EventStream.result(Loop.agent_loop([user_message("Add")], context, config, nil, nil))
          end)
        end

      for {{:ok, messages}, i} <- Enum.with_index(Task.await_many(tasks, 5000), 1) do
        assert [%ToolResultMessage{details: %{sum: sum}}] =
                 Enum.filter(messages, &match?(%ToolResultMessage{}, &1))

        assert sum == i + 2
      end
    end
  end

  # ============================================================================
  # agent_loop_continue/4 and stream_continue/3
  # ============================================================================

  describe "agent_loop_continue/4" do
    test "rejects contexts without a continuable last message" do
      for {messages, pattern} <- [
            {[], ~r/no messages in context/},
            {[user_message("Hi"), Mocks.assistant_message("Hello")],
             ~r/Cannot continue from message role: assistant/}
          ] do
        assert_raise ArgumentError, pattern, fn ->
          Loop.agent_loop_continue(simple_context(messages: messages), simple_config(), nil, nil)
        end
      end
    end

    test "continues from a trailing user or tool_result message" do
      call = Mocks.tool_call("previous_tool", %{}, id: "call_existing")

      histories = [
        [user_message("Please continue")],
        [
          user_message("Original"),
          Mocks.assistant_message_with_tool_calls([call]),
          Mocks.tool_result_message("call_existing", "previous_tool", "Previous result")
        ]
      ]

      for history <- histories do
        response = Mocks.assistant_message("Continuing")
        config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))
        stream = Loop.agent_loop_continue(simple_context(messages: history), config, nil, nil)

        assert {:ok, [^response]} = EventStream.result(stream)
      end
    end

    test "stream_continue/3 emits the reply as the only new message" do
      context = simple_context(messages: [user_message("Start")])
      response = Mocks.assistant_message("Continue")
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))

      events = Loop.stream_continue(context, config) |> Enum.to_list()

      assert {:message_end, response} in events
      assert {:agent_end, [response]} in events
    end

    test "rejects invalid tool transcripts before calling the model" do
      parent = self()

      invalid_context =
        simple_context(
          messages: [
            %UserMessage{role: :user, content: "read the file"},
            %AssistantMessage{
              role: :assistant,
              content: [%ToolCall{id: "call_missing", name: "read", arguments: %{}}]
            },
            %UserMessage{role: :user, content: "continue before tool result"}
          ]
        )

      stream_fn = fn _model, _llm_context, _options ->
        send(parent, :stream_called)
        raise "stream should not be called for an invalid transcript"
      end

      config = simple_config(stream_fn: stream_fn)
      stream = Loop.agent_loop_continue(invalid_context, config, nil, nil)

      assert {:error, {:invalid_tool_transcript, violations}, _partial} =
               EventStream.result(stream)

      assert Enum.any?(violations, &(&1.type == :missing_tool_result))
      refute_receive :stream_called, 50
    end
  end

  # ============================================================================
  # Tool Execution
  # ============================================================================

  describe "tool execution" do
    test "reports tool start and end events and records results in transcript order" do
      context = simple_context(tools: [Mocks.echo_tool()])

      config =
        tool_turn_config([Mocks.tool_call("echo", %{"text" => "test input"}, id: "call_1")])

      events = run("Echo", context, config)

      assert {:tool_execution_start, "call_1", "echo", %{"text" => "test input"}} in events

      assert [{:tool_execution_end, "call_1", "echo", %AgentToolResult{}, false}] =
               tool_ends(events)

      assert {:agent_end, messages} = List.last(events)
      assert Enum.map(messages, & &1.role) == [:user, :assistant, :tool_result, :assistant]

      assert [%ToolResultMessage{trust: :untrusted}] =
               Enum.filter(messages, &(&1.role == :tool_result))
    end

    test "failing, crashing and unknown tools become error results without stopping the loop" do
      failing = [
        {Mocks.error_tool(), %{"message" => "Intentional error"}, ~r/Intentional error/},
        {tool("raising", fn _, _, _, _ -> raise "Intentional exception" end), %{},
         ~r/Intentional exception/},
        {tool("exiting", fn _, _, _, _ -> exit(:intentional_crash) end), %{},
         ~r/intentional_crash/},
        {tool("throwing", fn _, _, _, _ -> throw(:intentional_throw) end), %{},
         ~r/intentional_throw/},
        {tool("weird", fn _, _, _, _ -> {:unexpected, "weird_value"} end), %{}, ~r/Unexpected/}
      ]

      calls =
        for {%AgentTool{name: name}, args, _} <- failing,
            do: Mocks.tool_call(name, args, id: "call_#{name}")

      calls = calls ++ [Mocks.tool_call("unknown_tool", %{}, id: "call_unknown_tool")]

      expected =
        for({tool, _, pattern} <- failing, do: {tool.name, pattern}) ++
          [{"unknown_tool", ~r/not found/}]

      context = simple_context(tools: Enum.map(failing, &elem(&1, 0)))
      events = run("Run failing tools", context, tool_turn_config(calls))

      for {name, pattern} <- expected do
        call_id = "call_#{name}"

        assert {:tool_execution_end, ^call_id, _, %AgentToolResult{} = result, true} =
                 Enum.find(tool_ends(events), &(elem(&1, 1) == call_id))

        assert [%TextContent{text: text}] = result.content
        assert text =~ pattern
      end

      assert {:agent_end, _} = List.last(events)
    end

    test "a parallel batch settles every call independently" do
      context = simple_context(tools: [Mocks.echo_tool(), Mocks.error_tool()])

      calls =
        for(i <- 1..10, do: Mocks.tool_call("echo", %{"text" => "message #{i}"}, id: "call_#{i}")) ++
          [Mocks.tool_call("error_tool", %{"message" => "fail"}, id: "call_err")]

      ends = run("Echo many", context, tool_turn_config(calls)) |> tool_ends()

      assert length(ends) == 11
      assert for({:tool_execution_end, id, _, _, true} <- ends, do: id) == ["call_err"]
    end

    test "passes exactly one tool_result per tool call into the next model turn" do
      parent = self()
      context = simple_context(tools: [Mocks.add_tool(), Mocks.echo_tool()])

      tool_call1 = Mocks.tool_call("add", %{"a" => 1, "b" => 2}, id: "call_add")
      tool_call2 = Mocks.tool_call("echo", %{"text" => "hello"}, id: "call_echo")
      tool_response = Mocks.assistant_message_with_tool_calls([tool_call1, tool_call2])
      final_response = Mocks.assistant_message("I saw both tool results")
      canned_stream = Mocks.mock_stream_fn([tool_response, final_response])

      stream_fn = fn model, llm_context, options ->
        send(parent, {:model_turn_messages, llm_context.messages})
        canned_stream.(model, llm_context, options)
      end

      config = simple_config(stream_fn: stream_fn)
      stream = Loop.agent_loop([user_message("Run both tools")], context, config, nil, nil)

      {:ok, messages} = EventStream.result(stream)

      assert_receive {:model_turn_messages, first_turn_messages}
      assert_receive {:model_turn_messages, second_turn_messages}

      assert Enum.filter(first_turn_messages, &match?(%ToolResultMessage{}, &1)) == []

      second_turn_tool_results =
        Enum.filter(second_turn_messages, &match?(%ToolResultMessage{}, &1))

      assert Enum.map(second_turn_tool_results, & &1.tool_call_id) == ["call_add", "call_echo"]
      assert Enum.all?(second_turn_tool_results, &(&1.is_error == false))
      # The model-bound copy carries the boundary's private marker in details.
      assert Enum.map(
               second_turn_tool_results,
               &Map.delete(&1.details, :__lemon_untrusted_boundary__)
             ) == [%{sum: 3}, %{}]

      final_tool_results = Enum.filter(messages, &match?(%ToolResultMessage{}, &1))
      assert Enum.map(final_tool_results, & &1.tool_call_id) == ["call_add", "call_echo"]
      assert Enum.map(final_tool_results, & &1.details) == [%{sum: 3}, nil]

      final_answer_index =
        Enum.find_index(messages, fn
          %{role: :assistant, stop_reason: :stop} -> true
          _ -> false
        end)

      tool_result_indices =
        messages
        |> Enum.with_index()
        |> Enum.filter(fn {message, _index} -> match?(%ToolResultMessage{}, message) end)
        |> Enum.map(fn {_message, index} -> index end)

      assert final_answer_index != nil
      assert Enum.all?(tool_result_indices, &(&1 < final_answer_index))
    end

    test "large and empty tool output is passed through unchanged" do
      large_text = String.duplicate("x", 50_000)

      tools = [
        tool("large_output", fn _, _, _, _ ->
          %AgentToolResult{content: [%TextContent{type: :text, text: large_text}]}
        end),
        tool("empty_output", fn _, _, _, _ -> %AgentToolResult{content: []} end)
      ]

      calls = [
        Mocks.tool_call("large_output", %{}, id: "call_large"),
        Mocks.tool_call("empty_output", %{}, id: "call_empty")
      ]

      events = run("Outputs", simple_context(tools: tools), tool_turn_config(calls))

      assert [
               {:tool_execution_end, "call_large", _,
                %{content: [%TextContent{text: ^large_text}]}, false},
               {:tool_execution_end, "call_empty", _, %{content: []}, false}
             ] = tool_ends(events)

      assert {:agent_end, _} = List.last(events)
    end

    test "emits tool_execution_update for streaming tools" do
      context = simple_context(tools: [Mocks.streaming_tool()])

      config =
        tool_turn_config([Mocks.tool_call("streaming_tool", %{"count" => 3}, id: "call_stream")])

      updates =
        for {:tool_execution_update, "call_stream", _, _, _} = event <-
              run("Stream tool", context, config),
            do: event

      assert length(updates) == 3
    end

    test "propagates untrusted trust from tool results" do
      untrusted_tool =
        tool("untrusted_echo", fn _id, %{"text" => text}, _signal, _on_update ->
          %AgentToolResult{content: [%TextContent{type: :text, text: text}], trust: :untrusted}
        end)

      config =
        tool_turn_config([
          Mocks.tool_call("untrusted_echo", %{"text" => "from web"}, id: "call_untrusted")
        ])

      context = simple_context(tools: [untrusted_tool])
      stream = Loop.agent_loop([user_message("Run untrusted tool")], context, config, nil, nil)
      {:ok, messages} = EventStream.result(stream)

      assert [%ToolResultMessage{trust: :untrusted}] =
               Enum.filter(messages, &match?(%{tool_call_id: "call_untrusted"}, &1))
    end
  end

  # ============================================================================
  # Steering and Follow-up Messages
  # ============================================================================

  describe "steering and follow-up messages" do
    test "applies queued system prompt to follow-up turns" do
      parent = self()
      context = simple_context(system_prompt: "base prompt")

      follow_up = %{
        message: user_message("use relevant skills"),
        system_prompt: "follow-up prompt"
      }

      {:ok, follow_up_queue} = Agent.start_link(fn -> [follow_up] end)

      canned =
        Mocks.mock_stream_fn([
          Mocks.assistant_message("first"),
          Mocks.assistant_message("second")
        ])

      stream_fn = fn model, llm_context, options ->
        send(parent, {:seen_system_prompt, llm_context.system_prompt})
        canned.(model, llm_context, options)
      end

      get_follow_up = fn ->
        Agent.get_and_update(follow_up_queue, fn
          [head | tail] -> {[head], tail}
          [] -> {[], []}
        end)
      end

      config = simple_config(stream_fn: stream_fn, get_follow_up_messages: get_follow_up)

      run("initial", context, config)

      assert_receive {:seen_system_prompt, "base prompt"}
      assert_receive {:seen_system_prompt, "follow-up prompt"}
    end

    test "does not skip tool calls when steering messages arrive" do
      context = simple_context(tools: [Mocks.echo_tool()])
      steering_message = user_message("Interrupt now")
      {:ok, call_counter} = Agent.start_link(fn -> 0 end)

      get_steering = fn ->
        Agent.get_and_update(call_counter, fn
          0 -> {[], 1}
          1 -> {[steering_message], 2}
          count -> {[], count}
        end)
      end

      calls = [
        Mocks.tool_call("echo", %{"text" => "first"}, id: "call_1"),
        Mocks.tool_call("echo", %{"text" => "second"}, id: "call_2")
      ]

      events =
        run("Run tools", context, tool_turn_config(calls, get_steering_messages: get_steering))

      assert length(tool_ends(events)) == 2
      assert {:agent_end, _} = List.last(events)
    end

    test "each follow-up batch starts another turn after the agent would stop" do
      follow_ups = [[user_message("First follow-up")], [user_message("Second follow-up")]]
      {:ok, queue} = Agent.start_link(fn -> follow_ups end)

      get_follow_up = fn ->
        Agent.get_and_update(queue, fn
          [head | tail] -> {head, tail}
          [] -> {[], []}
        end)
      end

      responses = for i <- 1..3, do: Mocks.assistant_message("Response #{i}")

      config =
        simple_config(
          get_follow_up_messages: get_follow_up,
          stream_fn: Mocks.mock_stream_fn(responses)
        )

      events = run("Start", simple_context(), config)

      assert Enum.count(events, &match?({:turn_start}, &1)) == 3
      assert {:agent_end, messages} = List.last(events)

      assert for(%UserMessage{content: content} <- messages, do: content) ==
               ["Start", "First follow-up", "Second follow-up"]
    end
  end

  # ============================================================================
  # Context Callbacks and Failures
  # ============================================================================

  describe "context callbacks and failures" do
    test "accepted transform_context and convert_to_llm results reach the model" do
      response = Mocks.assistant_message("Ok")

      for overrides <- [
            [transform_context: fn messages, _signal -> {:ok, messages} end],
            [convert_to_llm: fn _messages -> [] end],
            [convert_to_llm: fn _messages -> {:ok, []} end]
          ] do
        config =
          simple_config([stream_fn: Mocks.mock_stream_fn_single(response)] ++ overrides)

        assert {:agent_end, [_prompt, ^response]} =
                 run("Test", simple_context(), config) |> List.last()
      end
    end

    test "callback and provider failures end the run with their original reason" do
      cases = [
        {[stream_fn: Mocks.mock_stream_fn_error(:api_unavailable)], :api_unavailable},
        {[convert_to_llm: fn _messages -> {:error, :bad_convert} end], :bad_convert},
        {[transform_context: fn _messages, _signal -> {:error, :bad_transform} end],
         :bad_transform},
        {[stream_fn: fn _, _, _ -> {:unexpected, "weird result"} end],
         {:invalid_stream, {:unexpected, "weird result"}}},
        {[stream_fn: fn _, _, _ -> nil end], {:invalid_stream, nil}}
      ]

      for {overrides, expected_reason} <- cases do
        stream =
          Loop.agent_loop(
            [user_message("Test")],
            simple_context(),
            simple_config(overrides),
            nil,
            nil
          )

        assert {:error, ^expected_reason, _partial} = EventStream.result(stream)
      end
    end

    test "a raising stream_fn ends the run with an error" do
      config = simple_config(stream_fn: fn _, _, _ -> raise "Intentional crash" end)
      stream = Loop.agent_loop([user_message("Test")], simple_context(), config, nil, nil)

      assert {:error, _reason, _partial} = EventStream.result(stream)
    end
  end

  # ============================================================================
  # Assistant Terminal Responses
  # ============================================================================

  describe "assistant terminal responses" do
    test "empty and thinking-only stop responses become an assistant error after continuations" do
      empty = %{Mocks.assistant_message("") | content: []}

      thinking_only = %{
        Mocks.assistant_message("")
        | content: [%ThinkingContent{type: :thinking, thinking: "internal reasoning"}]
      }

      for {response, assistant_count} <- [{empty, 1}, {thinking_only, 4}] do
        config = simple_config(stream_fn: Mocks.mock_stream_fn_single(response))
        stream = Loop.agent_loop([user_message("Test")], simple_context(), config, nil, nil)

        assert {:error, {:assistant_error, "empty_assistant_response"}, %{new_messages: messages}} =
                 EventStream.result(stream)

        assistants = Enum.filter(messages, &match?(%AssistantMessage{}, &1))
        assert length(assistants) == assistant_count

        assert %{stop_reason: :error, error_message: "empty_assistant_response"} =
                 List.last(assistants)

        assert [%TextContent{text: "The provider returned an empty assistant response."}] =
                 List.last(assistants).content
      end
    end

    test "a stream that completes without a done event finalizes the partial message" do
      partial_response = Mocks.assistant_message("Partial")

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = LemonAi.EventStream.start_link()

        Task.start(fn ->
          LemonAi.EventStream.push(stream, {:start, partial_response})
          LemonAi.EventStream.complete(stream, partial_response)
        end)

        {:ok, stream}
      end

      config = simple_config(stream_fn: stream_fn)
      stream = Loop.agent_loop([user_message("Test")], simple_context(), config, nil, nil)

      assert {:ok, [_prompt, %AssistantMessage{content: [%TextContent{text: "Partial"}]}]} =
               EventStream.result(stream)
    end

    test "error stop reasons end the loop with an assistant error" do
      error_response = Mocks.assistant_message("Error occurred", stop_reason: :error)

      mid_stream_error = fn _model, _context, _options ->
        partial = Mocks.assistant_message("Partial", stop_reason: :error)
        {:ok, stream} = LemonAi.EventStream.start_link()

        Task.start(fn ->
          LemonAi.EventStream.push(stream, {:start, partial})
          LemonAi.EventStream.push(stream, {:text_start, 0})
          LemonAi.EventStream.push(stream, {:error, :rate_limited, partial})
          LemonAi.EventStream.complete(stream, partial)
        end)

        {:ok, stream}
      end

      for stream_fn <- [Mocks.mock_stream_fn_single(error_response), mid_stream_error] do
        events = run("Test", simple_context(), simple_config(stream_fn: stream_fn))

        assert {:turn_end, %{stop_reason: :error}, _} =
                 Enum.find(events, &match?({:turn_end, _, _}, &1))

        assert {:error, :assistant_error, %{new_messages: _}} = List.last(events)
      end
    end

    test "an aborted stop reason ends the loop without agent_end" do
      aborted_response = Mocks.assistant_message("Aborted", stop_reason: :aborted)
      config = simple_config(stream_fn: Mocks.mock_stream_fn_single(aborted_response))

      events = run("Test", simple_context(), config)

      assert {:canceled, :assistant_aborted} = List.last(events)
      refute Enum.any?(events, &match?({:agent_end, _}, &1))
    end

    test "a provider-canceled stream becomes an aborted assistant message" do
      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = LemonAi.EventStream.start_link()

        Task.start(fn ->
          LemonAi.EventStream.push(stream, {:start, Mocks.assistant_message("Partial response")})
          LemonAi.EventStream.cancel(stream, :aborted)
        end)

        {:ok, stream}
      end

      stream =
        Loop.agent_loop(
          [user_message("Test")],
          simple_context(),
          simple_config(stream_fn: stream_fn),
          nil,
          nil
        )

      events_task = Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)
      assert {:error, {:canceled, :assistant_aborted}} = EventStream.result(stream)

      assert %{stop_reason: :aborted, error_message: error_message} =
               Enum.find_value(Task.await(events_task, 5000), fn
                 {:message_end, %{role: :assistant} = message} -> message
                 _ -> nil
               end)

      assert error_message =~ "canceled"
    end
  end

  # ============================================================================
  # API Key Resolution
  # ============================================================================

  describe "get_api_key" do
    test "resolves the provider key as an atom, then a string, then the stream option" do
      parent = self()
      response = Mocks.assistant_message("Ok")

      stream_fn = fn model, llm_context, options ->
        send(parent, {:api_key, options.api_key})
        Mocks.mock_stream_fn_single(response).(model, llm_context, options)
      end

      cases = [
        {fn
           :mock_provider -> "atom_key"
           _ -> nil
         end, "atom_key"},
        {fn
           "mock_provider" -> "string_key"
           _ -> nil
         end, "string_key"},
        {fn _provider -> nil end, "fallback"}
      ]

      for {get_api_key, expected} <- cases do
        config =
          simple_config(
            get_api_key: get_api_key,
            stream_options: %StreamOptions{api_key: "fallback"},
            stream_fn: stream_fn
          )

        run("Test", simple_context(), config)
        assert_receive {:api_key, ^expected}
      end
    end
  end
end
