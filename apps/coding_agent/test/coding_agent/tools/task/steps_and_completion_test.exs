defmodule CodingAgent.Tools.Task.StepsAndCompletionTest do
  use ExUnit.Case, async: false

  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task, as: TaskTool
  alias CodingAgent.Tools.Task.Followup
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @tag :tmp_dir
  test "steps run in order on one child session and the last answer is the result",
       %{tmp_dir: cwd} do
    {stream_fn, contexts} = recording_stream(["Stage one: found the parser", "Stage two: done"])

    result =
      run(cwd, stream_fn, %{"steps" => ["Find the parser.", "Now add the flag to it."]})

    assert result.details.status == "completed"
    assert text(result) == "Stage two: done"
    assert [first, second] = contexts.()
    assert last_user_text(first) =~ "Find the parser."
    assert last_user_text(second) =~ "Now add the flag to it."
    # The second stage continues the same conversation.
    assert Enum.any?(second.messages, &(message_text(&1) =~ "Stage one: found the parser"))
  end

  @tag :tmp_dir
  test "prompt and steps are mutually exclusive and steps are bounded", %{tmp_dir: cwd} do
    {stream_fn, _contexts} = recording_stream([])

    assert {:error, "Provide either prompt or steps, not both"} =
             run(cwd, stream_fn, %{"prompt" => "x", "steps" => ["y"]})

    assert {:error, "steps must be a list of 1 to 4 non-empty strings"} =
             run(cwd, stream_fn, %{"steps" => ~w(a b c d e)})

    assert {:error, "steps must be non-empty strings"} =
             run(cwd, stream_fn, %{"steps" => ["a", " "]})
  end

  test "completion names the child and marks failures that carry partial output" do
    id = TaskStore.new_task(%{description: "Audit", name: "Auditor", role: "reviewer"})
    on_exit(fn -> TaskStore.delete_task(id) end)

    ok = Followup.task_auto_followup_text(%{}, id, nil, {:ok, result("All clear")})
    assert ok == "Task Auditor (#{id}) [reviewer] completed.\n\nAll clear"

    failed =
      Followup.task_auto_followup_text(
        %{},
        id,
        nil,
        {:ok, %{result("half done") | details: %{status: "error", error: "timed out"}}}
      )

    assert failed == "Task Auditor (#{id}) [reviewer] failed: timed out\n\nhalf done"
  end

  test "long completions keep a preview and point at the full output" do
    id = TaskStore.new_task(%{description: "Dump"})
    on_exit(fn -> TaskStore.delete_task(id) end)
    long = "HEAD" <> String.duplicate("x", 20_000) <> "TAIL"

    text = Followup.task_auto_followup_text(%{}, id, nil, {:ok, result(long)})

    assert text =~ "Task #{id} completed.\n\nHEAD"
    refute text =~ "TAIL"

    assert text =~
             "first 10000 of 20008 characters shown. Read agent://#{id} for the full output."

    assert String.length(text) < 10_200
  end

  defp run(cwd, stream_fn, params) do
    params = Map.merge(%{"async" => false, "auto_followup" => false}, params)

    opts = [
      parent_session: "steps-#{System.unique_integer([:positive])}",
      model: "openai-codex:gpt-6.1-sol",
      stream_fn: stream_fn
    ]

    TaskTool.execute("call-#{System.unique_integer([:positive])}", params, nil, nil, cwd, opts)
  end

  defp recording_stream(texts) do
    {:ok, store} = Agent.start_link(fn -> [] end)
    responses = Mocks.mock_stream_fn(Enum.map(texts, &Mocks.assistant_message/1))

    stream_fn = fn model, context, options ->
      Agent.update(store, &[context | &1])
      responses.(model, context, options)
    end

    {stream_fn, fn -> store |> Agent.get(& &1) |> Enum.reverse() end}
  end

  defp last_user_text(context) do
    context.messages
    |> Enum.filter(&match?(%LemonAi.Types.UserMessage{}, &1))
    |> List.last()
    |> message_text()
  end

  defp message_text(%{content: content}) when is_binary(content), do: content

  defp message_text(%{content: content}) when is_list(content),
    do: Enum.map_join(content, "", &Map.get(&1, :text, ""))

  defp message_text(_message), do: ""

  defp text(%AgentToolResult{content: content}), do: Enum.map_join(content, "", & &1.text)
  defp result(text), do: %AgentToolResult{content: [%TextContent{text: text}], details: %{}}
end
