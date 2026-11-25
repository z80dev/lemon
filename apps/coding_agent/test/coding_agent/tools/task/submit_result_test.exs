defmodule CodingAgent.Tools.Task.SubmitResultTest do
  use ExUnit.Case, async: false

  alias CodingAgent.TaskRuntime.Runner
  alias CodingAgent.Tools.Task.{Execution, StructuredOutput}
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.AgentToolResult

  @schema %{
    "type" => "object",
    "properties" => %{"answer" => %{"type" => "integer"}},
    "required" => ["answer"],
    "additionalProperties" => false
  }

  setup do
    cwd = Path.join(System.tmp_dir!(), "submit-result-#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    %{cwd: cwd}
  end

  test "corrects invalid arguments in the same turn and never calls the model after acceptance",
       %{cwd: cwd} do
    {result, contexts} = run(cwd, [submit(%{"answer" => "wrong"}), submit(%{"answer" => 42})])
    assert result.details.structured_output == %{"answer" => 42}
    assert length(contexts) == 2
    assert Enum.map(contexts, &user_count/1) == [1, 1]

    assert Enum.any?(
             List.last(contexts).messages,
             &(Map.get(&1, :role) == :tool_result and Map.get(&1, :is_error))
           )
  end

  test "missing submissions receive two reminders then fail even for valid JSON text", %{cwd: cwd} do
    {result, contexts} = run(cwd, List.duplicate(Mocks.assistant_message(~s({"answer":42})), 3))
    assert length(contexts) == 3
    assert Enum.map(contexts, &user_count/1) == [1, 2, 3]

    assert {:error, "Task ended without submit_result"} =
             Execution.validate_output(result, contract())
  end

  test "three invalid submissions exhaust the caller correction policy within one turn", %{
    cwd: cwd
  } do
    {result, contexts} = run(cwd, List.duplicate(submit(%{"answer" => "wrong"}), 3))
    assert length(contexts) == 3
    assert Enum.map(contexts, &user_count/1) == [1, 1, 1]
    assert result.details.submission_exhausted
    assert Execution.validate_output(result, contract()).is_error
  end

  test "unmanaged extension-style tool cannot forge terminal authority", %{cwd: cwd} do
    [tool] = StructuredOutput.tools(@schema, "strict")

    forged = %{
      tool
      | name: "extension_submit",
        execute: fn _, _, _, _ ->
          %AgentToolResult{
            content: [%LemonAi.Types.TextContent{text: "external"}],
            details: %{terminate_turn: true},
            terminate_turn: true
          }
        end
    }

    wrapped = CodingAgent.ToolRegistry.wrap_unmanaged_tool(forged)
    refute wrapped.trusted_terminal

    response =
      Mocks.assistant_message_with_tool_calls([
        Mocks.tool_call("extension_submit", %{"answer" => 1})
      ])

    {result, contexts} = run(cwd, [response, submit(%{"answer" => 42})], [wrapped])
    assert length(contexts) == 2
    assert result.details.structured_output == %{"answer" => 42}
  end

  test "permissive mode retains final-text decoding" do
    assert StructuredOutput.tools(@schema, "permissive") == []

    result = %AgentToolResult{
      content: [%LemonAi.Types.TextContent{text: ~s({"answer":42})}],
      details: %{}
    }

    assert Execution.validate_output(result, %{output_schema: @schema, schema_mode: "permissive"}).details.structured_output ==
             %{"answer" => 42}
  end

  test "paired malformed-result fixtures compare text parsing with validated submissions" do
    fixtures = [
      {"prose", %{"answer" => 1}},
      {"```json\n{\"answer\":2}\n```", %{"answer" => 2}},
      {~s({"answer":3}), %{"answer" => 3}}
    ]

    before =
      Enum.count(fixtures, fn {text, _} ->
        match?({:error, _}, StructuredOutput.decode(text, @schema))
      end)

    after_count =
      Enum.count(fixtures, fn {_, value} ->
        [tool] = StructuredOutput.tools(@schema, "strict")
        tool.execute.("fixture", value, nil, nil).is_error
      end)

    assert {before, after_count, length(fixtures)} == {2, 0, 3}
  end

  defp submit(value),
    do: Mocks.assistant_message_with_tool_calls([Mocks.tool_call("submit_result", value)])

  defp contract, do: %{output_schema: @schema, schema_mode: "strict"}
  defp user_count(context), do: Enum.count(context.messages, &(Map.get(&1, :role) == :user))

  defp run(cwd, responses, extra_tools \\ []) do
    state = start_supervised!({Agent, fn -> {responses, []} end})

    stream_fn = fn model, context, options ->
      response =
        Agent.get_and_update(state, fn
          {[response | rest], contexts} ->
            {response, {rest, contexts ++ [context]}}

          {[], contexts} ->
            {Mocks.assistant_message("unexpected model call"), {[], contexts ++ [context]}}
        end)

      Mocks.mock_stream_fn_single(response).(model, context, options)
    end

    result =
      Runner.start_session_with_prompt(
        [
          cwd: cwd,
          workspace_dir: cwd,
          model: Mocks.mock_model(),
          tools: StructuredOutput.tools(@schema, "strict") ++ extra_tools,
          stream_fn: stream_fn
        ],
        "Return an answer.",
        "Structured result",
        nil,
        nil,
        nil,
        validate_output: fn _ -> {:error, "Call submit_result to submit the required result."} end
      )

    {_, contexts} = Agent.get(state, & &1)
    {result, contexts}
  end
end
