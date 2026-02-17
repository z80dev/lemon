defmodule CodingAgent.Tools.AgentTest do
  use ExUnit.Case, async: false

  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Agent, as: AgentTool
  alias LemonCore.{Bus, Event, RunRequest}

  defmodule StubRunOrchestrator do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{owner: nil, count: 0} end, name: __MODULE__)
    end

    def configure(owner) when is_pid(owner) do
      Agent.update(__MODULE__, fn _ -> %{owner: owner, count: 0} end)
    end

    def submit(%RunRequest{} = request) do
      Agent.get_and_update(__MODULE__, fn %{owner: owner, count: count} = state ->
        next = count + 1

        if is_pid(owner) do
          send(owner, {:router_submit, request, next})
        end

        {{:ok, "run_stub_#{next}"}, %{state | count: next}}
      end)
    end
  end

  defmodule SessionSpy do
    def follow_up(pid, text) do
      send(pid, {:session_follow_up, text})
      :ok
    end
  end

  defmodule UnknownAgentRunOrchestrator do
    def submit(%RunRequest{}), do: {:error, {:unknown_agent_id, "missing-agent"}}
  end

  setup do
    start_supervised!(StubRunOrchestrator)
    StubRunOrchestrator.configure(self())

    try do
      TaskStore.clear()
    catch
      _, _ -> :ok
    end

    :ok
  end

  test "tool/2 returns definition with run and poll actions" do
    tool = AgentTool.tool("/tmp", available_agent_ids: ["oracle", "coder"])
    assert tool.name == "agent"
    assert tool.label == "Delegate To Agent"
    assert is_function(tool.execute, 4)
    assert tool.parameters["properties"]["action"]["enum"] == ["run", "poll"]
    assert tool.parameters["properties"]["agent_id"]["enum"] == ["coder", "default", "oracle"]
  end

  test "execute run async queues delegated run and poll returns completion" do
    result =
      AgentTool.execute(
        "call_1",
        %{
          "agent_id" => "oracle",
          "prompt" => "Answer with hello",
          "async" => true,
          "auto_followup" => false
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: StubRunOrchestrator,
        session_key: "agent:main:main",
        session_id: "sess_main",
        agent_id: "main"
      )

    assert %AgentCore.Types.AgentToolResult{} = result
    assert result.details.status == "queued"
    assert is_binary(result.details.task_id)
    assert is_binary(result.details.run_id)

    assert_receive {:router_submit, %RunRequest{} = req, 1}
    assert req.agent_id == "oracle"
    assert req.prompt == "Answer with hello"
    assert req.session_key == result.details.session_key

    completed =
      Event.new(:run_completed, %{
        completed: %{ok: true, answer: "hello from oracle"},
        duration_ms: 12
      })

    :ok = Bus.broadcast(Bus.run_topic(result.details.run_id), completed)

    poll = wait_for_completed(result.details.task_id)
    assert poll.details.status == "completed"
    assert AgentCore.get_text(poll) == "hello from oracle"
  end

  test "delegated session key is stable across runs with continue_session" do
    params = %{
      "agent_id" => "oracle",
      "prompt" => "same session please",
      "async" => true,
      "auto_followup" => false,
      "continue_session" => true
    }

    _ =
      AgentTool.execute(
        "call_1",
        params,
        nil,
        nil,
        "/tmp",
        run_orchestrator: StubRunOrchestrator,
        session_key: "agent:main:main",
        session_id: "sess_main",
        agent_id: "main"
      )

    assert_receive {:router_submit, %RunRequest{session_key: session_key_1}, 1}

    _ =
      AgentTool.execute(
        "call_2",
        params,
        nil,
        nil,
        "/tmp",
        run_orchestrator: StubRunOrchestrator,
        session_key: "agent:main:main",
        session_id: "sess_main",
        agent_id: "main"
      )

    assert_receive {:router_submit, %RunRequest{session_key: session_key_2}, 2}
    assert session_key_1 == session_key_2
  end

  test "auto_followup uses live session when session pid is available" do
    result =
      AgentTool.execute(
        "call_1",
        %{
          "agent_id" => "oracle",
          "prompt" => "provide update",
          "async" => true,
          "auto_followup" => true
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: StubRunOrchestrator,
        session_module: SessionSpy,
        session_pid: self(),
        session_key: "agent:main:main",
        session_id: "sess_main",
        agent_id: "main"
      )

    assert_receive {:router_submit, %RunRequest{}, 1}

    :ok =
      Bus.broadcast(
        Bus.run_topic(result.details.run_id),
        Event.new(:run_completed, %{completed: %{ok: true, answer: "oracle update"}})
      )

    assert_receive {:session_follow_up, text}, 500
    assert text =~ "oracle update"
    refute_receive {:router_submit, %RunRequest{queue_mode: :followup}, _}, 150
  end

  test "auto_followup falls back to router followup when session pid is unavailable" do
    dead_pid = spawn(fn -> :ok end)
    ref = Process.monitor(dead_pid)
    assert_receive {:DOWN, ^ref, :process, ^dead_pid, _}

    result =
      AgentTool.execute(
        "call_1",
        %{
          "agent_id" => "oracle",
          "prompt" => "provide update",
          "async" => true,
          "auto_followup" => true
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: StubRunOrchestrator,
        session_module: SessionSpy,
        session_pid: dead_pid,
        session_key: "agent:main:main",
        session_id: "sess_main",
        agent_id: "main"
      )

    assert_receive {:router_submit, %RunRequest{}, 1}

    :ok =
      Bus.broadcast(
        Bus.run_topic(result.details.run_id),
        Event.new(:run_completed, %{completed: %{ok: true, answer: "oracle update"}})
      )

    assert_receive {:router_submit, %RunRequest{queue_mode: :followup} = followup, 2}, 500
    assert followup.session_key == "agent:main:main"
    assert followup.agent_id == "main"
    assert followup.prompt =~ "oracle update"
  end

  test "poll returns error for unknown task id" do
    assert {:error, "Unknown task_id: missing_task"} =
             AgentTool.execute(
               "call_1",
               %{"action" => "poll", "task_id" => "missing_task"},
               nil,
               nil,
               "/tmp",
               []
             )
  end

  test "run returns explicit unknown agent error from router" do
    assert {:error, "Unknown agent_id: missing-agent"} =
             AgentTool.execute(
               "call_1",
               %{
                 "agent_id" => "missing-agent",
                 "prompt" => "hi",
                 "async" => true
               },
               nil,
               nil,
               "/tmp",
               run_orchestrator: UnknownAgentRunOrchestrator
             )
  end

  defp wait_for_completed(task_id, attempts \\ 25)

  defp wait_for_completed(task_id, attempts) when attempts <= 0 do
    flunk("timed out waiting for delegated task #{task_id} to complete")
  end

  defp wait_for_completed(task_id, attempts) do
    result =
      AgentTool.execute(
        "poll_#{attempts}",
        %{"action" => "poll", "task_id" => task_id},
        nil,
        nil,
        "/tmp",
        []
      )

    case result do
      %AgentCore.Types.AgentToolResult{details: %{status: "completed"}} ->
        result

      _ ->
        Process.sleep(25)
        wait_for_completed(task_id, attempts - 1)
    end
  end
end
