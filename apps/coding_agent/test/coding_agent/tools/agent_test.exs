defmodule CodingAgent.Tools.AgentTest do
  alias Elixir.CodingAgent, as: CodingAgent
  use ExUnit.Case, async: false

  alias Elixir.CodingAgent.{RunGraph, Subagents, TaskStore}
  alias Elixir.CodingAgent.Tools.Agent, as: AgentTool
  alias CodingAgent.Messages
  alias CodingAgent.Messages.CustomMessage
  alias LemonCore.{Bus, Event, RunRequest, Store}

  defmodule AgentTestStubRunOrchestrator do
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
        run_id = "run_stub_#{next}_#{System.unique_integer([:positive])}"

        if is_pid(owner) do
          send(owner, {:router_submit, request, next})
        end

        {{:ok, run_id}, %{state | count: next}}
      end)
    end
  end

  defmodule AgentTestSessionSpy do
    def handle_async_followup(pid, message) do
      send(
        pid,
        {:session_async_followup, CodingAgent.Session.State.build_async_followup_message(message)}
      )

      :ok
    end

    def get_state(_pid) do
      %{is_streaming: true}
    end
  end

  defmodule AgentTestIdleSessionSpy do
    def handle_async_followup(pid, message) do
      send(
        pid,
        {:session_async_followup, CodingAgent.Session.State.build_async_followup_message(message)}
      )

      :ok
    end

    def get_state(_pid) do
      %{is_streaming: false}
    end
  end

  defmodule AgentTestHealthCheckSessionSpy do
    def handle_async_followup(pid, message) do
      send(
        pid,
        {:session_async_followup, CodingAgent.Session.State.build_async_followup_message(message)}
      )

      :ok
    end

    def health_check(_pid) do
      %{is_streaming: true}
    end
  end

  defmodule UnknownAgentRunOrchestrator do
    def submit(%RunRequest{}), do: {:error, {:unknown_agent_id, "missing-agent"}}
  end

  setup do
    previous_async_followups = Application.get_env(:coding_agent, :async_followups)

    on_exit(fn ->
      Application.put_env(:coding_agent, :async_followups, previous_async_followups)
    end)

    start_supervised!(__MODULE__.AgentTestStubRunOrchestrator)
    __MODULE__.AgentTestStubRunOrchestrator.configure(self())

    try do
      TaskStore.clear()
    catch
      _, _ -> :ok
    end

    :ok
  end

  test "tool/2 returns definition with run, poll, and join actions" do
    tool = AgentTool.tool("/tmp", available_agent_ids: ["oracle", "coder"])
    assert tool.name == "agent"
    assert tool.label == "Delegate To Agent"
    assert is_function(tool.execute, 4)
    assert tool.parameters["properties"]["action"]["enum"] == ["run", "poll", "join"]
    assert Map.has_key?(tool.parameters["properties"], "model")
    assert Map.has_key?(tool.parameters["properties"], "role")
    assert Map.has_key?(tool.parameters["properties"], "task_ids")
    assert Map.has_key?(tool.parameters["properties"], "mode")
    assert Map.has_key?(tool.parameters["properties"], "followup_queue_mode")
    assert tool.parameters["properties"]["agent_id"]["enum"] == ["coder", "default", "oracle"]
  end

  test "execute run async queues delegated run and poll returns completion" do
    result =
      AgentTool.execute(
        "call_1",
        %{
          "agent_id" => "oracle",
          "prompt" => "Answer with hello",
          "model" => "openai:gpt-4.1",
          "async" => true,
          "auto_followup" => false
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
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
    assert req.model == "openai:gpt-4.1"
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

  test "run with role prepends subagent prompt to delegated request prompt" do
    role_prompt = Subagents.get("/tmp", "research").prompt

    _result =
      AgentTool.execute(
        "call_1",
        %{
          "agent_id" => "oracle",
          "prompt" => "find open auth issues",
          "role" => "research",
          "async" => true,
          "auto_followup" => false
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_key: "agent:main:main",
        session_id: "sess_main",
        agent_id: "main"
      )

    assert_receive {:router_submit, %RunRequest{} = req, 1}
    assert req.prompt == role_prompt <> "\n\n" <> "find open auth issues"
    assert req.meta[:delegated][:role] == "research"
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
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
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
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_key: "agent:main:main",
        session_id: "sess_main",
        agent_id: "main"
      )

    assert_receive {:router_submit, %RunRequest{session_key: session_key_2}, 2}
    assert session_key_1 == session_key_2
  end

  test "followup_queue_mode followup uses the live session when session pid is available" do
    result =
      AgentTool.execute(
        "call_1",
        %{
          "agent_id" => "oracle",
          "prompt" => "provide update",
          "async" => true,
          "auto_followup" => true,
          "followup_queue_mode" => "followup"
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_module: __MODULE__.AgentTestSessionSpy,
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

    assert_receive {:session_async_followup, %CustomMessage{} = message}, 500
    assert message.custom_type == "async_followup"
    assert message.content =~ "oracle update"
    assert message.details.source == :agent
    assert message.details.task_id == result.details.task_id
    assert message.details.run_id == result.details.run_id
    assert message.details.agent_id == "oracle"
    assert message.details.session_key == result.details.session_key
    assert message.details.delivery == :followup

    [llm_message] = Messages.to_llm([message])
    assert %Ai.Types.UserMessage{} = llm_message
    assert llm_message.content =~ "[SYSTEM-DELIVERED ASYNC COMPLETION - NOT A USER MESSAGE]"
    assert llm_message.content =~ "Source: agent (ID: #{result.details.task_id})"
    assert llm_message.content =~ "Run: #{result.details.run_id}"
    assert llm_message.content =~ "Delivery: followup"
    assert llm_message.content =~ message.content

    refute_receive {:router_submit, %RunRequest{queue_mode: :followup}, _}, 150
  end

  test "followup_queue_mode followup uses the live session even when the parent is idle" do
    result =
      AgentTool.execute(
        "call_1",
        %{
          "agent_id" => "oracle",
          "prompt" => "provide update",
          "async" => true,
          "auto_followup" => true,
          "followup_queue_mode" => "followup"
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_module: __MODULE__.AgentTestIdleSessionSpy,
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

    assert_receive {:session_async_followup, %CustomMessage{} = message}, 500
    assert message.details.delivery == :followup
    assert message.content =~ "oracle update"
    refute_receive {:router_submit, %RunRequest{queue_mode: :followup}, _}, 150
  end

  test "followup_queue_mode steer uses health_check streaming checks for live delivery" do
    result =
      AgentTool.execute(
        "call_1",
        %{
          "agent_id" => "oracle",
          "prompt" => "provide update",
          "async" => true,
          "auto_followup" => true,
          "followup_queue_mode" => "steer"
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_module: __MODULE__.AgentTestHealthCheckSessionSpy,
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

    assert_receive {:session_async_followup, %CustomMessage{} = message}, 500
    assert message.content =~ "oracle update"
    assert message.details.source == :agent
    assert message.details.delivery == :steer
    refute_receive {:router_submit, %RunRequest{queue_mode: :followup}, _}, 150
  end

  test "followup_queue_mode steer falls back to router followup when the parent is idle" do
    result =
      AgentTool.execute(
        "call_1",
        %{
          "agent_id" => "oracle",
          "prompt" => "provide update",
          "async" => true,
          "auto_followup" => true,
          "followup_queue_mode" => "steer"
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_module: __MODULE__.AgentTestIdleSessionSpy,
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

    refute_receive {:session_async_followup, _message}, 150
    assert_receive {:router_submit, %RunRequest{queue_mode: :followup} = followup, 2}, 500
    assert followup.prompt =~ "oracle update"

    assert followup.meta["async_followups"] == [
             %{
               source: :agent,
               task_id: result.details.task_id,
               run_id: result.details.run_id,
               agent_id: "oracle",
               session_key: result.details.session_key,
               delivery: :followup
             }
           ]
  end

  test "followup_queue_mode followup falls back to router when session pid is unavailable" do
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
          "auto_followup" => true,
          "followup_queue_mode" => "followup"
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_module: __MODULE__.AgentTestSessionSpy,
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

    assert followup.meta["async_followups"] == [
             %{
               source: :agent,
               task_id: result.details.task_id,
               run_id: result.details.run_id,
               agent_id: "oracle",
               session_key: result.details.session_key,
               delivery: :followup
             }
           ]
  end

  test "followup_queue_mode steer_backlog still routes through router when the parent is streaming" do
    result =
      AgentTool.execute(
        "call_1",
        %{
          "agent_id" => "oracle",
          "prompt" => "provide update",
          "async" => true,
          "auto_followup" => true,
          "followup_queue_mode" => "steer_backlog"
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_module: __MODULE__.AgentTestSessionSpy,
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

    refute_receive {:session_async_followup, _message}, 150
    assert_receive {:router_submit, %RunRequest{queue_mode: :steer_backlog} = followup, 2}, 500
    assert followup.prompt =~ "oracle update"
  end

  test "followup_queue_mode interrupt routes through router" do
    result =
      AgentTool.execute(
        "call_1",
        %{
          "agent_id" => "oracle",
          "prompt" => "provide update",
          "async" => true,
          "auto_followup" => true,
          "followup_queue_mode" => "interrupt"
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_module: __MODULE__.AgentTestSessionSpy,
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

    refute_receive {:session_async_followup, _message}, 150
    assert_receive {:router_submit, %RunRequest{queue_mode: :interrupt} = followup, 2}, 500
    assert followup.prompt =~ "oracle update"
  end

  test "followup_queue_mode collect routes through router" do
    result =
      AgentTool.execute(
        "call_1",
        %{
          "agent_id" => "oracle",
          "prompt" => "provide update",
          "async" => true,
          "auto_followup" => true,
          "followup_queue_mode" => "collect"
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_module: __MODULE__.AgentTestSessionSpy,
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

    refute_receive {:session_async_followup, _message}, 150
    assert_receive {:router_submit, %RunRequest{queue_mode: :collect} = followup, 2}, 500
    assert followup.prompt =~ "oracle update"
  end

  test "followup_queue_mode is independent from delegated run queue_mode" do
    result =
      AgentTool.execute(
        "call_1",
        %{
          "agent_id" => "oracle",
          "prompt" => "provide update",
          "async" => true,
          "auto_followup" => true,
          "queue_mode" => "interrupt",
          "followup_queue_mode" => "followup"
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_module: __MODULE__.AgentTestSessionSpy,
        session_pid: self(),
        session_key: "agent:main:main",
        session_id: "sess_main",
        agent_id: "main"
      )

    assert_receive {:router_submit, %RunRequest{queue_mode: :interrupt}, 1}

    :ok =
      Bus.broadcast(
        Bus.run_topic(result.details.run_id),
        Event.new(:run_completed, %{completed: %{ok: true, answer: "oracle update"}})
      )

    assert_receive {:session_async_followup, %CustomMessage{} = message}, 500
    assert message.details.delivery == :followup
    refute_receive {:router_submit, %RunRequest{queue_mode: :followup}, _}, 150
  end

  test "omitted followup_queue_mode uses the configured async followup default" do
    Application.put_env(:coding_agent, :async_followups, default_queue_mode: :steer_backlog)

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
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_module: __MODULE__.AgentTestSessionSpy,
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

    refute_receive {:session_async_followup, _}, 150
    assert_receive {:router_submit, %RunRequest{queue_mode: :steer_backlog} = followup, 2}, 500

    assert followup.meta["async_followups"] == [
             %{
               source: :agent,
               task_id: result.details.task_id,
               run_id: result.details.run_id,
               agent_id: "oracle",
               session_key: result.details.session_key,
               delivery: :steer_backlog
             }
           ]
  end

  test "async completion can recover from missed bus events via run summary store polling" do
    result =
      AgentTool.execute(
        "call_1",
        %{
          "agent_id" => "oracle",
          "prompt" => "Answer from store",
          "async" => true,
          "auto_followup" => false
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_key: "agent:main:main",
        session_id: "sess_main",
        agent_id: "main"
      )

    assert_receive {:router_submit, %RunRequest{}, 1}

    :ok =
      Store.finalize_run(result.details.run_id, %{
        completed: %{ok: true, answer: "hello from store"}
      })

    poll = wait_for_completed(result.details.task_id)
    assert poll.details.status == "completed"
    assert AgentCore.get_text(poll) == "hello from store"
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

  test "join waits for all delegated task run_ids" do
    run_a = RunGraph.new_run(%{type: :agent, description: "join-a"})
    run_b = RunGraph.new_run(%{type: :agent, description: "join-b"})
    :ok = RunGraph.finish(run_a, %{ok: true, answer: "a"})
    :ok = RunGraph.finish(run_b, %{ok: true, answer: "b"})

    task_a = TaskStore.new_task(%{run_id: run_a, status: :completed})
    task_b = TaskStore.new_task(%{run_id: run_b, status: :completed})

    result =
      AgentTool.execute(
        "call_join",
        %{"action" => "join", "task_ids" => [task_a, task_b], "mode" => "wait_all"},
        nil,
        nil,
        "/tmp",
        []
      )

    assert %AgentCore.Types.AgentToolResult{} = result
    assert result.details.status == "completed"
    assert result.details.mode == "wait_all"
    assert Enum.sort(result.details.task_ids) == Enum.sort([task_a, task_b])
  end

  test "join returns error for unknown task id" do
    assert {:error, "Unknown task_id: missing_task"} =
             AgentTool.execute(
               "call_join",
               %{"action" => "join", "task_ids" => ["missing_task"]},
               nil,
               nil,
               "/tmp",
               []
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
