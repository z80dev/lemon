defmodule CodingAgent.Tools.AskParentTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Types.AgentToolResult
  alias LemonAgent.Test.Mocks
  alias Elixir.CodingAgent.ParentQuestions
  alias Elixir.CodingAgent.{RunGraph, Session, TaskStore}
  alias Elixir.CodingAgent.Tools.{AskParent, ParentQuestion}
  alias Elixir.CodingAgent.Tools.Task, as: TaskTool
  alias Elixir.CodingAgent.Tools.Task.Params

  defmodule SessionSpy do
    def deliver_parent_question(pid, text) do
      send(pid, {:session_follow_up, text})
      :ok
    end
  end

  defmodule SessionStateSpy do
    def get_state(_pid) do
      %{model: "openai:gpt-5.4-pro"}
    end
  end

  setup do
    try do
      ParentQuestions.clear()
    catch
      _, _ -> :ok
    end

    :ok
  end

  test "ask_parent sends a follow_up to the parent and returns the parent's answer" do
    parent_pid = self()

    task =
      Task.async(fn ->
        AskParent.execute(
          "call_ask_parent",
          %{
            "question" => "Should I keep the existing auth boundary?",
            "why_blocked" => "Both approaches touch different modules."
          },
          nil,
          nil,
          "/tmp",
          parent_session_module: __MODULE__.SessionSpy,
          parent_session_pid: parent_pid,
          parent_session_key: "agent:main:main",
          parent_agent_id: "main",
          parent_run_id: "run_parent_1",
          child_run_id: "run_child_1",
          child_scope_id: "child_scope_1",
          task_id: "task_1",
          task_description: "Auth refactor"
        )
      end)

    assert_receive {:session_follow_up, text}, 1_000
    assert text =~ "[subagent question"
    assert text =~ "Auth refactor"
    assert text =~ "parent_question"

    [pending] =
      ParentQuestions.list(status: :waiting, parent_session_key: "agent:main:main")

    {request_id, _record} = pending

    answer_result =
      ParentQuestion.execute(
        "call_answer_parent",
        %{
          "action" => "answer",
          "request_id" => request_id,
          "answer" => "Keep the existing auth boundary for this change."
        },
        nil,
        nil,
        session_key: "agent:main:main",
        agent_id: "main"
      )

    assert %AgentToolResult{} = answer_result
    assert answer_result.details.request_id == request_id

    child_result = Task.await(task, 1_000)
    assert %AgentToolResult{} = child_result
    assert child_result.details.status == "answered"
    assert LemonAgent.get_text(child_result) =~ "Keep the existing auth boundary"
  end

  test "ask_parent times out with fallback when continuation is allowed" do
    result =
      AskParent.execute(
        "call_ask_parent_timeout",
        %{
          "question" => "Should I rename the module now?",
          "why_blocked" => "This changes public API shape.",
          "can_continue_without_answer" => true,
          "fallback" => "Keep the current module name and note the deferred rename.",
          "timeout_ms" => 0
        },
        nil,
        nil,
        "/tmp",
        parent_session_module: __MODULE__.SessionSpy,
        parent_session_pid: self(),
        parent_session_key: "agent:main:main",
        parent_agent_id: "main",
        parent_run_id: "run_parent_2",
        child_run_id: "run_child_2",
        child_scope_id: "child_scope_2",
        task_id: "task_2",
        task_description: "Rename pass"
      )

    assert %AgentToolResult{} = result
    assert result.details.status == "timed_out"
    assert LemonAgent.get_text(result) =~ "fallback"
    assert LemonAgent.get_text(result) =~ "deferred rename"
  end

  test "ask_parent errors when parent context is unavailable" do
    assert {:error, message} =
             AskParent.execute(
               "call_ask_parent_unavailable",
               %{
                 "question" => "Can I proceed?",
                 "why_blocked" => "Need product input."
               },
               nil,
               nil,
               "/tmp",
               child_scope_id: "child_scope_3",
               parent_run_id: "run_parent_3"
             )

    assert message =~ "Parent session is unavailable"
  end

  test "parent_question lists open requests for the current session" do
    {:ok, request} =
      ParentQuestions.request(%{
        description: "Config cleanup",
        parent_run_id: "run_parent_4",
        child_run_id: "run_child_4",
        child_scope_id: "child_scope_4",
        task_id: "task_4",
        parent_session_key: "agent:main:main",
        parent_agent_id: "main",
        question: "Should I remove the deprecated config?",
        why_blocked: "I need to know whether backward compatibility matters here.",
        options: ["Keep it", "Remove it"],
        recommended_option: "Keep it",
        can_continue_without_answer: false,
        fallback: nil,
        timeout_ms: 1000,
        meta: %{}
      })

    result =
      ParentQuestion.execute(
        "call_list_parent_questions",
        %{"action" => "list"},
        nil,
        nil,
        session_key: "agent:main:main",
        agent_id: "main"
      )

    assert %AgentToolResult{} = result
    assert LemonAgent.get_text(result) =~ request.id
    assert LemonAgent.get_text(result) =~ "Should I remove the deprecated config?"
  end

  test "parent_question requires the exact non-nil parent session and agent" do
    {:ok, request} = create_request("auth_scope")

    assert {:error, message} =
             ParentQuestion.execute(
               "missing_auth",
               %{"action" => "answer", "request_id" => request.id, "answer" => "No"},
               nil,
               nil,
               session_key: nil,
               agent_id: nil
             )

    assert message =~ "session and agent"

    assert {:error, message} =
             ParentQuestion.execute(
               "wrong_agent",
               %{"action" => "answer", "request_id" => request.id, "answer" => "No"},
               nil,
               nil,
               session_key: "agent:main:main",
               agent_id: "other"
             )

    assert message =~ "session and agent"
    assert {:ok, %{status: :waiting}, _events} = ParentQuestions.get(request.id)
  end

  test "one-open-per-scope creation is serialized under a barrier" do
    parent = self()

    tasks =
      for index <- 1..12 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> ParentQuestions.request(request_attrs("shared_scope", index)))
        end)
      end

    pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await(&1, 2_000))

    assert 1 == Enum.count(results, &match?({:ok, _}, &1))
    assert 11 == Enum.count(results, &(&1 == {:error, :already_waiting}))

    {:ok, winner} = Enum.find(results, &match?({:ok, _}, &1))
    assert {:ok, _record, [%{type: :parent_question_requested}]} = ParentQuestions.get(winner.id)
  end

  test "answer timeout and cancel race emits exactly one terminal event" do
    {:ok, request} = create_request("terminal_race")
    parent = self()

    contenders = [
      fn ->
        ParentQuestions.answer(request.id, "Proceed",
          session_key: "agent:main:main",
          agent_id: "main"
        )
      end,
      fn -> ParentQuestions.timeout(request.id) end,
      fn -> ParentQuestions.cancel(request.id, :aborted) end
    ]

    tasks =
      Enum.map(contenders, fn contender ->
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> contender.())
        end)
      end)

    pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))
    results = Enum.map(tasks, &Task.await(&1, 2_000))

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert {:ok, record, events} = ParentQuestions.get(request.id)
    assert record.status in [:answered, :timed_out, :cancelled]

    terminal_events =
      Enum.filter(
        events,
        &(&1.type in [
            :parent_question_answered,
            :parent_question_timed_out,
            :parent_question_cancelled
          ])
      )

    assert length(terminal_events) == 1
  end

  test "idle real Session actively processes a delivered child question" do
    {:ok, parent_session} =
      Session.start_link(
        cwd: "/tmp",
        model: Mocks.mock_model(),
        session_key: "agent:main:main",
        agent_id: "main",
        stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("I see the question."))
      )

    child =
      Task.async(fn ->
        AskParent.execute(
          "real_idle_question",
          %{"question" => "Keep compatibility?", "why_blocked" => "It changes the API."},
          nil,
          nil,
          "/tmp",
          parent_session_pid: parent_session,
          parent_session_key: "agent:main:main",
          parent_agent_id: "main",
          parent_run_id: "idle_parent_run",
          child_run_id: "idle_child_run",
          child_scope_id: "idle_child_scope",
          task_id: "idle_task"
        )
      end)

    wait_until(fn ->
      Session.get_messages(parent_session)
      |> Enum.any?(&(message_text(&1) =~ "Keep compatibility?"))
    end)

    [{request_id, _record}] = ParentQuestions.list_for_parent("agent:main:main", "main")

    assert :ok =
             ParentQuestions.answer(request_id, "Yes",
               session_key: "agent:main:main",
               agent_id: "main"
             )

    assert %AgentToolResult{details: %{status: "answered"}} = Task.await(child, 2_000)
  end

  test "real Session task join yields to a child question instead of deadlocking" do
    run_id = RunGraph.new_run(%{status: :running})

    task_id =
      TaskStore.new_task(%{run_id: run_id, status: :running, description: "blocked child"})

    join_call = Mocks.tool_call("task", %{"action" => "join", "task_ids" => [task_id]})

    stream_fn =
      Mocks.mock_stream_fn([
        Mocks.assistant_message_with_tool_calls([join_call]),
        Mocks.assistant_message("The join yielded for clarification."),
        Mocks.assistant_message("I can now address the child's question.")
      ])

    {:ok, parent_session} =
      Session.start_link(
        cwd: "/tmp",
        model: Mocks.mock_model(),
        session_key: "agent:main:main",
        agent_id: "main",
        tools: [TaskTool.tool("/tmp")],
        stream_fn: stream_fn
      )

    :ok = Session.prompt(parent_session, "Wait for the child")
    wait_until(fn -> Session.get_state(parent_session).is_streaming end)

    child =
      Task.async(fn ->
        AskParent.execute(
          "real_join_question",
          %{"question" => "Which boundary?", "why_blocked" => "The join needs your decision."},
          nil,
          nil,
          "/tmp",
          parent_session_pid: parent_session,
          parent_session_key: "agent:main:main",
          parent_agent_id: "main",
          parent_run_id: "join_parent_run",
          child_run_id: run_id,
          child_scope_id: "join_child_scope",
          task_id: task_id
        )
      end)

    wait_until(fn ->
      not Session.get_state(parent_session).is_streaming and
        Enum.any?(
          Session.get_messages(parent_session),
          &(message_text(&1) =~ "address the child's question")
        )
    end)

    [{request_id, _record}] = ParentQuestions.list_for_parent("agent:main:main", "main")

    assert :ok =
             ParentQuestions.answer(request_id, "Keep the existing boundary",
               session_key: "agent:main:main",
               agent_id: "main"
             )

    assert %AgentToolResult{details: %{status: "answered"}} = Task.await(child, 2_000)
    refute TaskStore.auto_followup_suppressed?(task_id)
  end

  test "build_session_opts injects ask_parent for eligible child sessions" do
    opts =
      Params.build_session_opts(
        "/tmp",
        [
          session_pid: self(),
          session_module: __MODULE__.SessionSpy,
          session_key: "agent:main:main",
          agent_id: "main",
          parent_run_id: "run_parent_5",
          child_run_id: "run_child_5",
          child_scope_id: "child_scope_5",
          task_id: "task_5",
          task_description: "Injection test"
        ],
        %{
          model: nil,
          thinking_level: nil,
          tool_policy: nil,
          session_key: nil,
          agent_id: nil
        }
      )

    extra_tools = Keyword.get(opts, :extra_tools, [])
    assert Enum.any?(extra_tools, &(&1.name == "ask_parent"))
  end

  test "build_session_opts inherits model from the live parent session when task model is omitted" do
    opts =
      Params.build_session_opts(
        "/tmp",
        [
          session_pid: self(),
          session_module: __MODULE__.SessionStateSpy
        ],
        %{
          model: nil,
          thinking_level: nil,
          tool_policy: nil,
          session_key: nil,
          agent_id: nil
        }
      )

    assert Keyword.get(opts, :model) == "openai:gpt-5.4-pro"
  end

  defp create_request(scope), do: ParentQuestions.request(request_attrs(scope, 0))

  defp request_attrs(scope, index) do
    %{
      description: "Question #{index}",
      parent_run_id: "run_parent_#{index}",
      child_run_id: "run_child_#{index}",
      child_scope_id: scope,
      task_id: "task_#{index}",
      parent_session_key: "agent:main:main",
      parent_agent_id: "main",
      question: "Question #{index}?",
      why_blocked: "Need a decision",
      timeout_ms: 1_000
    }
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition did not become true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp message_text(%LemonAi.Types.AssistantMessage{} = message), do: LemonAi.get_text(message)
  defp message_text(%{content: content}) when is_binary(content), do: content
  defp message_text(_message), do: ""
end
