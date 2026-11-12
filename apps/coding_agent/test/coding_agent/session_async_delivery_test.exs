defmodule CodingAgent.SessionAsyncDeliveryTest do
  use ExUnit.Case, async: true

  import CodingAgent.AsyncHelpers

  alias CodingAgent.Session
  alias CodingAgent.Tools.Task, as: TaskTool
  alias CodingAgent.Tools.Task.Runner
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{AssistantMessage, TextContent, ToolResultMessage, UserMessage}

  @tag :tmp_dir
  test "an async completion waits for every issued tool and reaches the next model request", %{
    tmp_dir: cwd
  } do
    session = start_session(cwd)
    :ok = Session.prompt(session, "Do the batch")
    running = await_tools(8)

    owner = self()

    receipt =
      TaskTool.execute(
        "child-launch",
        %{"description" => "Child", "prompt" => "Find the answer", "async" => true},
        nil,
        nil,
        cwd,
        session_pid: session,
        session_key: "agent:async-delivery:#{Path.basename(cwd)}",
        run_override: fn _on_update, _signal ->
          send(owner, {:child_waiting, self()})

          receive do
            :complete -> result("child answer")
          end
        end
      )

    assert receipt.details.status == "queued"
    assert_receive {:child_waiting, child}, 2_000
    send(child, :complete)
    await_turn_input(session)

    release_tools(running)
    release_tools(await_tools(2))

    assert_receive {:model_request, 2, messages}, 2_000
    assert Enum.count(messages, &match?(%ToolResultMessage{is_error: false}, &1)) == 10
    assert Enum.any?(messages, &(message_text(&1) =~ "child answer"))
    assert Enum.any?(messages, &(message_text(&1) =~ "SYSTEM-DELIVERED ASYNC COMPLETION"))
    refute Enum.any?(messages, &match?(%ToolResultMessage{is_error: true}, &1))
    assert :ok = LemonAgent.Agent.wait_for_idle(Session.get_state(session).agent)
  end

  @tag :tmp_dir
  test "human steering still skips calls that have not started", %{tmp_dir: cwd} do
    session = start_session(cwd)
    :ok = Session.prompt(session, "Do the batch")
    running = await_tools(8)

    :ok = Session.steer(session, "Human correction")
    agent = Session.get_state(session).agent

    assert [%{message: %UserMessage{content: "Human correction"}}] =
             :sys.get_state(agent).steering_queue

    release_tools(running)
    assert_receive {:model_request, 2, messages}, 2_000
    assert Enum.count(messages, &match?(%ToolResultMessage{is_error: false}, &1)) == 8

    skipped = Enum.filter(messages, &match?(%ToolResultMessage{is_error: true}, &1))
    assert Enum.map(skipped, & &1.tool_call_id) == ["call-9", "call-10"]
    assert Enum.all?(skipped, &(&1.details.reason == :steering))
    assert Enum.any?(messages, &(message_text(&1) == "Human correction"))
    refute_receive {:tool_started, _, _}
    assert :ok = LemonAgent.Agent.wait_for_idle(agent)
  end

  @tag :tmp_dir
  test "a synchronous child's budget notice preserves its batch and precedes its next request", %{
    tmp_dir: cwd
  } do
    session = start_session(cwd)

    runner =
      Task.async(fn ->
        Runner.resume_session(
          session,
          %{
            start_opts: [],
            description: "Budget child",
            role_id: nil,
            opts: [request_budget: 1, task_session_timeout_ms: 5_000]
          },
          "Do the batch",
          nil,
          nil
        )
      end)

    running = await_tools(8)
    await_turn_input(session)
    release_tools(running)
    release_tools(await_tools(2))

    assert_receive {:model_request, 2, messages}, 2_000
    assert Enum.count(messages, &match?(%ToolResultMessage{is_error: false}, &1)) == 10
    assert Enum.any?(messages, &(message_text(&1) =~ "You have reached your request budget (1)"))
    refute Enum.any?(messages, &match?(%ToolResultMessage{is_error: true}, &1))
    assert %AgentToolResult{} = Task.await(runner, 5_000)
  end

  defp start_session(cwd) do
    owner = self()
    tool_calls = for n <- 1..10, do: Mocks.tool_call("gated", %{}, id: "call-#{n}")
    batch = Mocks.assistant_message_with_tool_calls(tool_calls)
    final = Mocks.assistant_message("Done")

    stream_fn = fn model, context, options ->
      turn = 1 + Enum.count(context.messages, &match?(%AssistantMessage{}, &1))
      send(owner, {:model_request, turn, context.messages})
      response = if turn == 1, do: batch, else: final
      Mocks.mock_stream_fn_single(response).(model, context, options)
    end

    tool = %AgentTool{
      name: "gated",
      parallel_safe: true,
      description: "A deterministic gated operation",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn id, _params, _signal, _on_update ->
        send(owner, {:tool_started, id, self()})

        receive do
          :release -> result("finished #{id}")
        end
      end
    }

    start_supervised!(
      {Session,
       cwd: cwd,
       workspace_dir: Path.join(cwd, "workspace"),
       model: Mocks.mock_model(),
       tools: [tool],
       stream_fn: stream_fn}
    )
  end

  defp await_tools(count) do
    for _ <- 1..count do
      assert_receive {:tool_started, id, pid}, 2_000
      {id, pid}
    end
  end

  defp release_tools(tools), do: Enum.each(tools, fn {_id, pid} -> send(pid, :release) end)

  defp await_turn_input(session) do
    assert_eventually(fn -> Session.diagnostics(session).follow_up_queue_size == 1 end)
    queue = :sys.get_state(Session.get_state(session).agent).steering_queue
    assert [%{preempt: false}] = queue
  end

  defp result(text), do: %AgentToolResult{content: [%TextContent{text: text}]}
  defp message_text(%{content: text}) when is_binary(text), do: text

  defp message_text(%{content: content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %TextContent{text: text} -> text
      _ -> ""
    end)
  end
end
