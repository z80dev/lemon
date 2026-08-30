defmodule CodingAgent.Tools.AgentTest do
  alias Elixir.CodingAgent, as: CodingAgent
  use ExUnit.Case, async: false

  alias CodingAgent.Session.Presentation
  alias LemonAgent.Test.Mocks
  alias Elixir.CodingAgent.{RunGraph, Subagents, TaskStore}
  alias Elixir.CodingAgent.Tools.Agent, as: AgentTool
  alias CodingAgent.Messages
  alias CodingAgent.Messages.CustomMessage
  alias LemonCore.{Bus, Event, ResumeToken, RunRequest, Store}
  alias LemonPlatformTest.EventsFixtures

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
      RunGraph.clear()
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
    refute Map.has_key?(tool.parameters["properties"], "engine_id")
    assert tool.parameters["properties"]["agent_id"]["enum"] == ["coder", "default", "oracle"]
  end

  test "resume rejects non-native and unavailable explicit native sessions" do
    state = %{cwd: System.tmp_dir!()}
    session_id = "missing-#{System.unique_integer([:positive])}"

    assert {:error, {:wrong_engine, "echo", "lemon"}} =
             Presentation.start_or_resume_session(
               %ResumeToken{engine: "echo", value: "legacy"},
               [resume_source: :explicit],
               state
             )

    assert {:error, {:resume_session_missing, ^session_id}} =
             Presentation.start_or_resume_session(
               %ResumeToken{engine: "lemon", value: session_id},
               [resume_source: :explicit],
               state
             )

    corrupt_session_id = "corrupt-#{System.unique_integer([:positive])}"
    corrupt_session_file = Presentation.session_file_path(corrupt_session_id, state.cwd)
    :ok = File.mkdir_p(Path.dirname(corrupt_session_file))
    :ok = File.write(corrupt_session_file, "{not-json}\n")

    on_exit(fn -> File.rm(corrupt_session_file) end)

    assert {:error, {:resume_session_corrupt, ^corrupt_session_id, _reason}} =
             Presentation.start_or_resume_session(
               %ResumeToken{engine: "lemon", value: corrupt_session_id},
               [resume_source: :explicit],
               state
             )
  end

  test "stale automatic native resume starts fresh with diagnostic metadata" do
    state = %{cwd: System.tmp_dir!()}
    session_id = "missing-#{System.unique_integer([:positive])}"

    assert {:ok, session, fresh_session_id,
            %{
              resume_diagnostic: %{
                resume: %{
                  source: :auto,
                  session_id: ^session_id,
                  fallback: :fresh,
                  reason: :missing
                }
              }
            }} =
             Presentation.start_or_resume_session(
               %ResumeToken{engine: "lemon", value: session_id},
               [
                 cwd: state.cwd,
                 model: Mocks.mock_model(),
                 stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ack")),
                 resume_source: :auto
               ],
               state
             )

    assert fresh_session_id != session_id
    :ok = GenServer.stop(session)
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

    assert %LemonAgent.Types.AgentToolResult{} = result
    assert result.details.status == "queued"
    assert is_binary(result.details.task_id)
    assert is_binary(result.details.run_id)

    assert {:ok,
            %{
              id: run_id,
              task_id: task_id,
              status: :running,
              type: :agent
            }} = RunGraph.get(result.details.run_id)

    assert run_id == result.details.run_id
    assert task_id == result.details.task_id

    assert_receive {:router_submit, %RunRequest{} = req, 1}
    assert req.agent_id == "oracle"
    assert req.prompt == "Answer with hello"
    assert req.model == "openai:gpt-4.1"
    assert req.session_key == result.details.session_key

    completed =
      Event.new(
        :run_completed,
        EventsFixtures.run_completed(answer: "hello from oracle", duration_ms: 12)
      )

    :ok = Bus.broadcast(Bus.run_topic(result.details.run_id), completed)

    poll = wait_for_completed(result.details.task_id)
    assert poll.details.status == "completed"
    assert LemonAgent.get_text(poll) == "hello from oracle"

    assert {:ok, %{status: :completed}} = RunGraph.get(result.details.run_id)
  end

  test "async run reports a tracking error when its completion watcher cannot start" do
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
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        task_supervisor: :missing_agent_tool_task_supervisor,
        session_key: "agent:main:main"
      )

    assert result.details.status == "tracking_error"
    assert_receive {:router_submit, %RunRequest{}, 1}
    assert {:ok, %{status: :error}} = TaskStore.get(result.details.task_id) |> strip_events()
    assert {:ok, %{status: :error}} = RunGraph.get(result.details.run_id)
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
        Event.new(:run_completed, EventsFixtures.run_completed(answer: "oracle update"))
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
    assert %LemonAi.Types.UserMessage{} = llm_message
    assert llm_message.content =~ "[SYSTEM-DELIVERED ASYNC COMPLETION - NOT A USER MESSAGE]"
    assert llm_message.content =~ message.content
    assert llm_message.content =~ "task_id: #{result.details.task_id}"
    assert llm_message.content =~ "run_id: #{result.details.run_id}"
    assert llm_message.content =~ "agent_id: oracle"
    assert llm_message.content =~ "delivery: followup"

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
        Event.new(:run_completed, EventsFixtures.run_completed(answer: "oracle update"))
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
        Event.new(:run_completed, EventsFixtures.run_completed(answer: "oracle update"))
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
        Event.new(:run_completed, EventsFixtures.run_completed(answer: "oracle update"))
      )

    refute_receive {:session_async_followup, _message}, 150
    assert_receive {:router_submit, %RunRequest{queue_mode: :followup} = followup, 2}, 500
    assert followup.prompt =~ "oracle update"
    assert followup.cwd == "/tmp"

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
        Event.new(:run_completed, EventsFixtures.run_completed(answer: "oracle update"))
      )

    assert_receive {:router_submit, %RunRequest{queue_mode: :followup} = followup, 2}, 500
    assert followup.session_key == "agent:main:main"
    assert followup.agent_id == "main"
    assert followup.prompt =~ "oracle update"
    assert followup.cwd == "/tmp"

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

  test "followup_queue_mode steer_backlog uses live steer delivery when the parent is streaming" do
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
        Event.new(:run_completed, EventsFixtures.run_completed(answer: "oracle update"))
      )

    assert_receive {:session_async_followup, %CustomMessage{} = message}, 500
    assert message.details.delivery == :steer
    assert message.content =~ "oracle update"
    refute_receive {:router_submit, %RunRequest{}, 2}, 150
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
        Event.new(:run_completed, EventsFixtures.run_completed(answer: "oracle update"))
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
        Event.new(:run_completed, EventsFixtures.run_completed(answer: "oracle update"))
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
        Event.new(:run_completed, EventsFixtures.run_completed(answer: "oracle update"))
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
        Event.new(:run_completed, EventsFixtures.run_completed(answer: "oracle update"))
      )

    assert_receive {:session_async_followup, %CustomMessage{} = message}, 500
    assert message.details.delivery == :steer
    assert message.content =~ "oracle update"
    refute_receive {:router_submit, %RunRequest{}, 2}, 150
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
    assert LemonAgent.get_text(poll) == "hello from store"
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

  test "join waits for all production-path delegated task run_ids" do
    task_a = queue_delegated_run("join-a")
    task_b = queue_delegated_run("join-b")

    joiner =
      Task.async(fn ->
        AgentTool.execute(
          "call_join",
          %{
            "action" => "join",
            "task_ids" => [task_a.details.task_id, task_b.details.task_id],
            "mode" => "wait_all"
          },
          nil,
          nil,
          "/tmp",
          []
        )
      end)

    assert Task.yield(joiner, 50) == nil

    complete_delegated_run(task_a.details.run_id, "a")
    assert Task.yield(joiner, 50) == nil

    complete_delegated_run(task_b.details.run_id, "b")
    result = Task.await(joiner, 500)

    assert %LemonAgent.Types.AgentToolResult{} = result
    assert result.details.status == "completed"
    assert result.details.mode == "wait_all"

    assert Enum.sort(result.details.task_ids) ==
             Enum.sort([task_a.details.task_id, task_b.details.task_id])
  end

  test "join suppresses an async agent completion followup" do
    task =
      AgentTool.execute(
        "call_run",
        %{
          "agent_id" => "oracle",
          "prompt" => "joined result",
          "async" => true,
          "auto_followup" => true
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_module: __MODULE__.AgentTestSessionSpy,
        session_pid: self(),
        session_key: "agent:main:main"
      )

    assert_receive {:router_submit, %RunRequest{}, 1}

    joiner =
      Task.async(fn ->
        AgentTool.execute(
          "call_join",
          %{"action" => "join", "task_id" => task.details.task_id},
          nil,
          nil,
          "/tmp",
          []
        )
      end)

    wait_for_followup_suppression(task.details.task_id)
    complete_delegated_run(task.details.run_id, "joined")

    assert %LemonAgent.Types.AgentToolResult{} = Task.await(joiner, 500)
    refute_receive {:session_async_followup, %CustomMessage{}}, 100
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
      %LemonAgent.Types.AgentToolResult{details: %{status: "completed"}} ->
        result

      _ ->
        Process.sleep(25)
        wait_for_completed(task_id, attempts - 1)
    end
  end

  defp queue_delegated_run(description) do
    result =
      AgentTool.execute(
        "call_#{description}",
        %{
          "agent_id" => "oracle",
          "prompt" => description,
          "description" => description,
          "async" => true,
          "auto_followup" => false
        },
        nil,
        nil,
        "/tmp",
        run_orchestrator: __MODULE__.AgentTestStubRunOrchestrator,
        session_key: "agent:main:main"
      )

    assert_receive {:router_submit, %RunRequest{}, _}
    result
  end

  defp complete_delegated_run(run_id, answer) do
    Bus.broadcast(
      Bus.run_topic(run_id),
      Event.new(:run_completed, EventsFixtures.run_completed(answer: answer))
    )
  end

  defp wait_for_followup_suppression(task_id, attempts \\ 25)

  defp wait_for_followup_suppression(task_id, attempts) when attempts <= 0 do
    flunk("timed out waiting for auto-followup suppression for task #{task_id}")
  end

  defp wait_for_followup_suppression(task_id, attempts) do
    if TaskStore.auto_followup_suppressed?(task_id) do
      :ok
    else
      Process.sleep(10)
      wait_for_followup_suppression(task_id, attempts - 1)
    end
  end

  defp strip_events({:ok, record, _events}), do: {:ok, record}
  defp strip_events(other), do: other
end
