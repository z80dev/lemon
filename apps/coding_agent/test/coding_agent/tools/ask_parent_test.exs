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

  defmodule DeliveryBarrier do
    def deliver_parent_question(observer, text) do
      ref = make_ref()
      send(observer, {:question_delivery, self(), ref, text})

      receive do
        {^ref, result} -> result
      end
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

    unsubscribe = Session.subscribe(parent_session)
    on_exit(unsubscribe)
    join_call_id = join_call.id

    :ok = Session.prompt(parent_session, "Wait for the child")

    assert_receive {:session_event, _session_id,
                    {:tool_execution_start, ^join_call_id, "task", _args}},
                   2_000

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

    assert_receive {:session_event, _session_id, {:agent_end, messages}}, 2_000
    assert Enum.any?(messages, &(message_text(&1) =~ "address the child's question"))
    refute Session.get_state(parent_session).is_streaming
    refute_received {:session_event, _session_id, {:agent_end, _messages}}

    [{request_id, _record}] = ParentQuestions.list_for_parent("agent:main:main", "main")

    assert :ok =
             ParentQuestions.answer(request_id, "Keep the existing boundary",
               session_key: "agent:main:main",
               agent_id: "main"
             )

    assert %AgentToolResult{details: %{status: "answered"}} = Task.await(child, 2_000)
    refute TaskStore.auto_followup_suppressed?(task_id)
  end

  test "a child question cannot release the parent join before delivery is acknowledged" do
    observer = self()
    run_id = RunGraph.new_run(%{status: :running})
    task_id = TaskStore.new_task(%{run_id: run_id, status: :running})
    join_call = Mocks.tool_call("task", %{"action" => "join", "task_ids" => [task_id]})
    task_tool = TaskTool.tool("/tmp")

    gated_tool = %{
      task_tool
      | execute: fn id, args, signal, update ->
          send(observer, {:join_started, self()})
          receive do: (:join -> :ok)
          send(observer, {:join_question, ParentQuestions.waiting_for_task_ids([task_id])})
          task_tool.execute.(id, args, signal, update)
        end
    }

    stream_fn = fn model, context, options ->
      send(observer, {:model_request, self(), context})

      receive do
        {:respond, response} ->
          Mocks.mock_stream_fn_single(response).(model, context, options)
      end
    end

    parent_session =
      start_supervised!(
        {Session,
         cwd: "/tmp",
         model: Mocks.mock_model(),
         session_key: "agent:main:main",
         agent_id: "main",
         tools: [gated_tool],
         stream_fn: stream_fn}
      )

    unsubscribe = Session.subscribe(parent_session)
    on_exit(unsubscribe)
    :ok = Session.prompt(parent_session, "Wait for the child")
    assert_receive {:model_request, first_model, _context}, 2_000
    send(first_model, {:respond, Mocks.assistant_message_with_tool_calls([join_call])})
    assert_receive {:join_started, joiner}, 2_000
    agent = Session.get_state(parent_session).agent

    # Reproduce the original ordering: notification is queued in a suspended
    # Session while the Agent can still execute. The matching join must remain
    # active, so an old terminal event cannot overtake accepted delivery.
    :ok = :sys.suspend(parent_session)

    {child, sender, ref, delivery} =
      try do
        child =
          Task.async(fn ->
            AskParent.execute(
              "late_join_question",
              %{"question" => "Which boundary?", "why_blocked" => "Need a decision."},
              nil,
              nil,
              "/tmp",
              parent_session_module: DeliveryBarrier,
              parent_session_pid: observer,
              parent_session_key: "agent:main:main",
              parent_agent_id: "main",
              parent_run_id: "late_parent_run",
              child_run_id: run_id,
              child_scope_id: "late_child_scope",
              task_id: task_id
            )
          end)

        assert_receive {:question_delivery, sender, ref, text}, 2_000
        delivery = :gen_server.send_request(parent_session, {:deliver_parent_question, text})
        send(joiner, :join)
        assert_receive {:join_question, {:error, :not_found}}, 2_000
        assert {:error, :not_found} = ParentQuestions.waiting_for_task_ids([task_id])
        assert LemonAgent.Agent.get_state(agent).is_streaming
        refute_received {:model_request, _model, _context}
        {child, sender, ref, delivery}
      after
        :ok = :sys.resume(parent_session)
      end

    assert {:reply, :ok} = :gen_server.receive_response(delivery, 2_000)
    assert [%{message: %{content: queued_text}}] = :sys.get_state(agent).follow_up_queue
    assert queued_text =~ "Which boundary?"
    send(sender, {ref, :ok})

    assert_receive {:model_request, second_model, _context}, 2_000
    send(second_model, {:respond, Mocks.assistant_message("The join yielded for clarification.")})

    assert_receive {:session_event, _session_id,
                    {:tool_execution_end, _call_id, "task",
                     %AgentToolResult{
                       details: %{status: "needs_parent_answer", request_id: request_id}
                     }, false}},
                   2_000

    assert_receive {:model_request, question_model, context}, 2_000
    assert Enum.any?(context.messages, &(message_text(&1) =~ "Which boundary?"))
    assert_receive {:session_event, _session_id, {:agent_start}}, 2_000
    refute_received {:session_event, _session_id, {:agent_end, _messages}}
    assert Session.get_state(parent_session).is_streaming

    send(
      question_model,
      {:respond, Mocks.assistant_message("I can now address the child's question.")}
    )

    assert_receive {:session_event, _session_id, {:agent_end, messages}}, 2_000
    assert Enum.any?(messages, &(message_text(&1) =~ "address the child's question"))
    assert Enum.any?(messages, &(message_text(&1) =~ "join yielded for clarification"))
    refute_received {:session_event, _session_id, {:agent_end, _messages}}
    refute Session.get_state(parent_session).is_streaming

    assert :ok =
             ParentQuestions.answer(request_id, "Keep the existing boundary",
               session_key: "agent:main:main",
               agent_id: "main"
             )

    assert %AgentToolResult{details: %{status: "answered"}} = Task.await(child, 2_000)
    refute TaskStore.auto_followup_suppressed?(task_id)
  end

  test "failed question delivery does not release a join as an accepted notification" do
    observer = self()
    task_id = "failed_delivery_task"

    child =
      Task.async(fn ->
        AskParent.execute(
          "failed_delivery",
          %{"question" => "Which boundary?", "why_blocked" => "Need a decision."},
          nil,
          nil,
          "/tmp",
          parent_session_module: DeliveryBarrier,
          parent_session_pid: observer,
          parent_session_key: "agent:main:main",
          parent_agent_id: "main",
          child_scope_id: "failed_delivery_scope",
          task_id: task_id
        )
      end)

    assert_receive {:question_delivery, sender, ref, _text}, 2_000

    [{request_id, %{delivery_pending: true}}] =
      ParentQuestions.list_for_parent("agent:main:main", "main")

    assert {:error, :not_found} = ParentQuestions.waiting_for_task_ids([task_id])
    send(sender, {ref, {:error, :session_unavailable}})

    assert {:error, message} = Task.await(child, 2_000)
    assert message =~ "Failed to send question to parent"
    assert {:ok, %{status: :error}, _events} = ParentQuestions.get(request_id)
    assert :ok = ParentQuestions.mark_delivered(request_id)
    assert {:ok, %{status: :error}, _events} = ParentQuestions.get(request_id)
    assert {:error, :not_found} = ParentQuestions.waiting_for_task_ids([task_id])
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

  defp wait_until(fun, attempts \\ 1000)
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
