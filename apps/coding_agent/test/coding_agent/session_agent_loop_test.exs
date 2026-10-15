defmodule CodingAgent.SessionAgentLoopTest do
  @moduledoc """
  Session-level behavior of the coding agent loop: unlimited tool turns by
  default, the cache-stable environment block in the system prompt, and
  session retry of transient provider failures.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.Session
  alias CodingAgent.SettingsManager
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{AssistantMessage, Model, ModelCost, TextContent, ToolCall, Usage}

  @moduletag :tmp_dir

  defp mock_model do
    %Model{
      id: "mock-model-1",
      name: "Mock Model",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://api.mock.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.0, output: 0.0},
      context_window: 128_000,
      max_tokens: 4096,
      headers: %{},
      compat: nil
    }
  end

  defp assistant(content, stop_reason, error_message \\ nil) do
    %AssistantMessage{
      role: :assistant,
      content: content,
      api: :mock,
      provider: :mock_provider,
      model: "mock-model-1",
      usage: %Usage{},
      stop_reason: stop_reason,
      error_message: error_message,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp tool_call_message(n) do
    assistant(
      [
        %ToolCall{type: :tool_call, id: "call_#{n}", name: "echo", arguments: %{"text" => "#{n}"}}
      ],
      :tool_use
    )
  end

  defp to_stream(%AssistantMessage{} = response) do
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, response})

      response.content
      |> Enum.with_index()
      |> Enum.each(fn
        {%TextContent{text: text}, idx} ->
          LemonAi.EventStream.push(stream, {:text_start, idx, response})
          LemonAi.EventStream.push(stream, {:text_delta, idx, text, response})
          LemonAi.EventStream.push(stream, {:text_end, idx, response})

        {%ToolCall{} = tool_call, idx} ->
          LemonAi.EventStream.push(stream, {:tool_call_start, idx, response})
          LemonAi.EventStream.push(stream, {:tool_call_end, idx, tool_call, response})
      end)

      if response.stop_reason == :error do
        LemonAi.EventStream.error(stream, response)
      else
        LemonAi.EventStream.complete(stream, response)
      end
    end)

    stream
  end

  defp error_stream(text) do
    {:ok, stream} = LemonAi.EventStream.start_link()
    message = assistant([], :error, text)

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, message})
      LemonAi.EventStream.error(stream, message)
    end)

    stream
  end

  # Serves `responses` in order, one per model call.
  defp scripted_stream_fn(responses) do
    {:ok, script} = Agent.start_link(fn -> responses end)

    fn _model, _context, _options ->
      case Agent.get_and_update(script, fn [next | rest] -> {next, rest} end) do
        {:error_text, text} -> {:ok, error_stream(text)}
        %AssistantMessage{} = response -> {:ok, to_stream(response)}
      end
    end
  end

  defp echo_tool do
    %AgentTool{
      name: "echo",
      description: "Echoes the input text back",
      parameters: %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      },
      label: "Echo",
      execute: fn _id, %{"text" => text}, _signal, _on_update ->
        %AgentToolResult{content: [%TextContent{type: :text, text: "Echo: #{text}"}]}
      end
    }
  end

  defp start_session(tmp_dir, opts) do
    defaults = [
      cwd: tmp_dir,
      workspace_dir: Path.join(tmp_dir, "workspace"),
      model: mock_model(),
      tools: [echo_tool()],
      settings_manager: %SettingsManager{base_delay_ms: 1}
    ]

    {:ok, session} = Session.start_link(Keyword.merge(defaults, opts))
    _unsubscribe = Session.subscribe(session)
    session
  end

  defp await_agent_end(session) do
    %{session_manager: %{header: %{id: session_id}}} = Session.get_state(session)
    deadline = System.monotonic_time(:millisecond) + 15_000
    messages = do_await_agent_end(session_id, deadline)
    wait_idle(session)
    messages
  end

  defp do_await_agent_end(session_id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    assert remaining > 0, "Timed out waiting for session agent_end"

    # Selective receive of only agent_end would retain progress events until the
    # bounded subscription overflows and fences delivery of the terminal payload.
    assert_receive {:session_event, ^session_id, event}, remaining

    case event do
      {:agent_end, messages} ->
        messages

      {:stream_resync, details} ->
        flunk("Session subscription overflowed: #{inspect(details)}")

      _ ->
        do_await_agent_end(session_id, deadline)
    end
  end

  defp wait_idle(session) do
    if Session.get_state(session).is_streaming do
      Process.sleep(10)
      wait_idle(session)
    else
      :ok
    end
  end

  describe "tool turn budget" do
    test "a turn with more than 25 sequential tool calls runs to completion", %{tmp_dir: tmp_dir} do
      tool_turns = 40

      responses =
        Enum.map(1..tool_turns, &tool_call_message/1) ++
          [assistant([%TextContent{type: :text, text: "all done"}], :stop)]

      session = start_session(tmp_dir, stream_fn: scripted_stream_fn(responses))
      :ok = Session.prompt(session, "run the echo tool 40 times")

      messages = await_agent_end(session)

      tool_results = Enum.filter(messages, &match?(%{role: :tool_result}, &1))
      assert length(tool_results) == tool_turns

      assert %AssistantMessage{stop_reason: :stop, content: [%TextContent{text: "all done"}]} =
               List.last(messages)

      refute Enum.any?(messages, &match?(%{error_message: "max_tool_turns_exhausted"}, &1))
    end

    test "an explicit :max_tool_turns option still caps the turn", %{tmp_dir: tmp_dir} do
      responses = Enum.map(1..5, &tool_call_message/1)

      session =
        start_session(tmp_dir, stream_fn: scripted_stream_fn(responses), max_tool_turns: 2)

      :ok = Session.prompt(session, "loop")

      messages = await_agent_end(session)

      assert length(Enum.filter(messages, &match?(%{role: :tool_result}, &1))) == 2
      assert %AssistantMessage{error_message: "max_tool_turns_exhausted"} = List.last(messages)
    end

    test "[runtime] max_tool_turns config caps the turn", %{tmp_dir: tmp_dir} do
      responses = Enum.map(1..5, &tool_call_message/1)

      session =
        start_session(tmp_dir,
          stream_fn: scripted_stream_fn(responses),
          settings_manager: %SettingsManager{base_delay_ms: 1, max_tool_turns: 3}
        )

      :ok = Session.prompt(session, "loop")

      messages = await_agent_end(session)
      assert length(Enum.filter(messages, &match?(%{role: :tool_result}, &1))) == 3
    end
  end

  describe "system prompt environment block" do
    test "ends the prompt with cwd and date and stays byte-identical across turns", %{
      tmp_dir: tmp_dir
    } do
      responses = [
        assistant([%TextContent{type: :text, text: "one"}], :stop),
        assistant([%TextContent{type: :text, text: "two"}], :stop)
      ]

      session = start_session(tmp_dir, stream_fn: scripted_stream_fn(responses))
      initial_prompt = Session.get_state(session).system_prompt

      [_, environment] = String.split(initial_prompt, "## Environment\n", parts: 2)
      assert environment =~ "Working directory: #{tmp_dir}"
      assert environment =~ "Today's date: #{Date.to_iso8601(Date.utc_today())}"
      assert environment =~ ~r/Today's date: \d{4}-\d{2}-\d{2}\z/

      # Static coding guidance precedes the volatile block.
      {coding_at, _} = :binary.match(initial_prompt, "## Working on code")
      {env_at, _} = :binary.match(initial_prompt, "## Environment")
      assert coding_at < env_at

      :ok = Session.prompt(session, "first")
      await_agent_end(session)
      File.write!(Path.join(tmp_dir, "new_file.txt"), "changes the working tree")
      :ok = Session.prompt(session, "second")
      await_agent_end(session)

      assert Session.get_state(session).system_prompt == initial_prompt
    end
  end

  describe "provider retry" do
    test "a transient provider error is retried and the turn succeeds", %{tmp_dir: tmp_dir} do
      responses = [
        {:error_text, "Service temporarily unavailable (HTTP 503)"},
        assistant([%TextContent{type: :text, text: "recovered"}], :stop)
      ]

      session = start_session(tmp_dir, stream_fn: scripted_stream_fn(responses))
      %{session_manager: %{header: %{id: session_id}}} = Session.get_state(session)
      :ok = Session.prompt(session, "hello")

      assert_receive {:session_event, ^session_id,
                      {:provider_retry, %{attempt: 1, max_retries: 3, category: :transient}}},
                     5_000

      messages = await_agent_end(session)

      assert %AssistantMessage{stop_reason: :stop, content: [%TextContent{text: "recovered"}]} =
               List.last(messages)

      refute Enum.any?(messages, &match?(%AssistantMessage{stop_reason: :error}, &1))
    end
  end
end
