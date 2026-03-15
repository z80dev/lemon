defmodule CodingAgent.Tools.AskParentTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias Elixir.CodingAgent.ParentQuestions
  alias Elixir.CodingAgent.Tools.{AskParent, ParentQuestion}
  alias Elixir.CodingAgent.Tools.Task.Params

  defmodule SessionSpy do
    def follow_up(pid, text) do
      send(pid, {:session_follow_up, text})
      :ok
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
    assert AgentCore.get_text(child_result) =~ "Keep the existing auth boundary"
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
    assert AgentCore.get_text(result) =~ "fallback"
    assert AgentCore.get_text(result) =~ "deferred rename"
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
    assert AgentCore.get_text(result) =~ request.id
    assert AgentCore.get_text(result) =~ "Should I remove the deprecated config?"
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
end
