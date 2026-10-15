defmodule CodingAgent.Session.RunTranslatorTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.RunTranslator
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  test "session termination and tuple request failures use plain actionable copy" do
    translator()
    |> RunTranslator.handle_event({:agent_start})
    |> RunTranslator.handle_session_down({:shutdown, %{private: :detail}})

    assert_receive {:completed, %{ok: false, error: error}}
    assert error =~ "Send your message again"
    refute error =~ "{"
    refute error =~ ":shutdown"

    for reason <- [
          {:provider_failed, %{private: :detail}},
          {:assistant_error, {:provider_failed, :detail}}
        ] do
      error = CodingAgent.Session.Presentation.format_error(reason, %{})
      assert error =~ "lemon doctor"
      refute error =~ "{"
      refute error =~ ":detail"
    end
  end

  defmodule TestEmitter do
    @behaviour CodingAgent.Session.RunTranslator.Emitter

    @impl true
    def emit_started(pid, _fields), do: pid

    @impl true
    def emit_action_event(%{sink: pid} = state, fields) do
      send(pid, {:action_event, fields})
      state
    end

    @impl true
    def emit_delta(pid, _text, _meta), do: pid

    @impl true
    def emit_completed(%{sink: pid} = state, fields) do
      send(pid, {:completed, fields})
      state
    end
  end

  defp translator do
    RunTranslator.new(
      emitter: TestEmitter,
      emitter_state: %{sink: self()},
      engine: "lemon",
      label: "test",
      session_id: "translator-cancel-regression",
      cwd: "/tmp"
    )
  end

  defp completed_detail(name, args, result) do
    translator()
    |> RunTranslator.handle_event({:tool_execution_start, "c1", name, args})
    |> RunTranslator.handle_event({:tool_execution_end, "c1", name, result, false})

    assert_receive {:action_event, %{phase: :started}}
    assert_receive {:action_event, %{phase: :completed, detail: detail}}
    detail
  end

  test "completion counts actual assistant turns and failed tools" do
    result = %AgentToolResult{content: [%TextContent{text: "failed"}], details: %{exit_code: 1}}

    translator()
    |> RunTranslator.handle_event({:turn_start})
    |> RunTranslator.handle_event({:tool_execution_end, "failed", "bash", result, true})
    |> RunTranslator.handle_event({:turn_end, nil, []})
    |> RunTranslator.handle_event({:turn_end, nil, []})
    |> RunTranslator.handle_event({:agent_end, []})

    assert_receive {:completed, %{usage: %{turns: 2, tool_errors: 1}}}
  end

  test "budget failures preserve structured limits and reported run spend in JSON-safe completion" do
    details = %{
      reason: :budget_exceeded,
      scope: :session,
      metric: :tokens,
      limit: 100,
      used: 120,
      run_usage: %{tokens: 30, cost_usd: 0.25},
      session_usage: %{tokens: 120, cost_usd: 1.0},
      message: "Session token budget exhausted. Increase max_session_tokens to continue."
    }

    translator()
    |> RunTranslator.handle_event(
      {:usage_budget_updated, Map.take(details, [:run_usage, :session_usage])}
    )
    |> RunTranslator.handle_event({:budget_exceeded, details})
    |> RunTranslator.handle_event({:error, {:budget_exceeded, details}, %{new_messages: []}})

    assert_receive {:completed,
                    %{ok: false, error: error, usage: usage, meta: %{budget: ^details}} =
                      completed}

    assert error == details.message
    assert usage.total_tokens == 30
    assert usage.cost.total == 0.25
    json = completed |> Jason.encode!() |> Jason.decode!()
    assert json["meta"]["budget"]["reason"] == "budget_exceeded"
    assert json["meta"]["budget"]["used"] == 120
  end

  test "cancel intent drains terminal tool actions before one failed completion" do
    result = %AgentToolResult{
      content: [%TextContent{text: "observed partial output"}],
      details: %{cancelled: true, outcome: "unknown"}
    }

    t =
      translator()
      |> RunTranslator.handle_event({:agent_start})
      |> RunTranslator.handle_event({:tool_execution_start, "cancel-tool", "bash", %{}})
      |> RunTranslator.mark_cancelled(:interrupted)
      |> RunTranslator.mark_cancelled(:user_requested)

    assert_receive {:action_event, %{phase: :started}}
    refute_receive {:completed, _}, 10
    assert t.cancel_reason == :interrupted

    t =
      t
      |> RunTranslator.handle_event({:tool_execution_end, "cancel-tool", "bash", result, true})
      |> RunTranslator.handle_event({:message_end, nil})
      |> RunTranslator.handle_event(
        {:turn_end, %LemonAi.Types.AssistantMessage{stop_reason: :aborted}, []}
      )

    assert_receive {:action_event, %{phase: :completed, ok: false}}

    assert_receive {:completed,
                    %{ok: false, meta: %{cancelled: true}, usage: %{turns: 1, tool_errors: 1}}}

    assert t.pending_actions == %{}
    assert t.completed_emitted
    RunTranslator.handle_event(t, {:canceled, :assistant_aborted})
    RunTranslator.handle_event(t, {:agent_end, []})
    refute_receive {:completed, _}, 10
  end

  describe "completed tool actions" do
    test "keep the 500-char preview for channels and add a bounded full result and structured details for operators" do
      body = Enum.map_join(1..400, "\n", &"line #{&1}")
      diff = " 119\told\n-120\tbefore\n+120\tafter\n 121\tnext"

      result = %AgentToolResult{
        content: [%TextContent{text: body}],
        details: %{
          diff: diff,
          first_changed_line: 120,
          acp_client: true,
          checkpoint: %{id: "cp_1", files: ["lib/a.ex"]},
          session: self()
        }
      }

      detail = completed_detail("edit", %{"path" => "lib/a.ex"}, result)

      assert String.length(detail.result) <= 503
      assert detail.result_full == body
      assert detail.details.diff == diff
      assert detail.details.first_changed_line == 120
      assert detail.details.checkpoint == %{id: "cp_1", files: ["lib/a.ex"]}
      refute Map.has_key?(detail.details, :acp_client)
      refute Map.has_key?(detail.details, :session)
      assert Jason.encode!(detail.details)
    end

    test "bound the operator copy of very large results" do
      body = String.duplicate("x", 100_000)
      result = %AgentToolResult{content: [%TextContent{text: body}], details: %{exit_code: 0}}

      detail = completed_detail("bash", %{"command" => "yes x"}, result)

      assert byte_size(detail.result_full) <= 32_768
      assert detail.result_full =~ "bytes omitted"
      assert detail.details == %{exit_code: 0}
    end

    test "omit result_full when the preview already is the whole result" do
      result = %AgentToolResult{content: [%TextContent{text: "ok"}], details: nil}

      detail = completed_detail("read", %{"path" => "a"}, result)

      assert detail.result == "ok"
      refute Map.has_key?(detail, :result_full)
      refute Map.has_key?(detail, :details)
    end
  end

  test "async children keep distinct actions and terminal phases after their launcher completes" do
    receipt = %AgentToolResult{
      content: [],
      details: %{status: "queued", task_ids: ["one", "two"]}
    }

    t =
      translator()
      |> RunTranslator.handle_event({:tool_execution_start, "launch", "task", %{}})
      |> RunTranslator.handle_event({:tool_execution_end, "launch", "task", receipt, false})

    assert_receive {:action_event, %{id: "tool_launch", phase: :started}}
    assert_receive {:action_event, %{id: "tool_launch", phase: :completed}}

    one = task_update("one", "running")
    two = task_update("two", "running")
    t = RunTranslator.handle_event(t, {:tool_execution_update, "launch", "task", %{}, one})
    t = RunTranslator.handle_event(t, {:tool_execution_update, "launch", "task", %{}, two})
    assert_receive {:action_event, %{id: "task_one", phase: :started, detail: detail}}
    assert detail.tool_call_id == "task_one"
    assert detail.parent_tool_call_id == "launch"
    assert detail.parent_action_id == "tool_launch"
    assert detail.partial_result == one
    assert_receive {:action_event, %{id: "task_two", phase: :started}}

    done = task_update("one", "completed")
    t = RunTranslator.handle_event(t, {:tool_execution_update, "launch", "task", %{}, done})

    assert_receive {:action_event,
                    %{
                      id: "task_one",
                      phase: :completed,
                      ok: true,
                      detail: %{partial_result: ^done}
                    }}

    t = RunTranslator.handle_event(t, {:tool_execution_update, "launch", "task", %{}, two})
    assert_receive {:action_event, %{id: "task_two", phase: :updated}}
    t = RunTranslator.handle_event(t, {:tool_execution_update, "launch", "task", %{}, one})
    refute_receive {:action_event, _}

    RunTranslator.handle_event(
      t,
      {:tool_execution_update, "launch", "task", %{}, task_update("two", "error")}
    )

    assert_receive {:action_event, %{id: "task_two", phase: :completed, ok: false}}
    refute_receive {:action_event, %{id: "tool_launch"}}
  end

  test "cancelled async children emit failed terminal completion, not another progress update" do
    for status <- ["aborted", "cancelled"] do
      RunTranslator.handle_event(
        translator(),
        {:tool_execution_update, "launch", "task", %{}, task_update(status, status)}
      )

      assert_receive {:action_event, %{phase: :completed, ok: false}}
    end
  end

  defp task_update(id, status) do
    %AgentToolResult{
      content: [%TextContent{text: status}],
      details: %{
        task_id: id,
        run_id: "run-#{id}",
        session_id: "session-#{id}",
        parent_run_id: "parent-run",
        parent_session_id: "parent-session",
        agent: "scout",
        description: "Inspect #{id}",
        status: status,
        current_action: %{title: "Read source", kind: "tool", phase: "updated"}
      }
    }
  end

  describe "reasoning actions" do
    test "carry a bounded full text next to the channel preview" do
      thinking = String.duplicate("think ", 1_000)

      translator()
      |> RunTranslator.handle_event({:message_update, %{}, {:thinking_start, 0, nil}})
      |> RunTranslator.handle_event({:message_update, %{}, {:thinking_end, 0, thinking, nil}})

      assert_receive {:action_event, %{kind: :reasoning, phase: :started}}

      assert_receive {:action_event,
                      %{kind: :reasoning, phase: :completed, detail: %{reasoning: reasoning}}}

      assert String.length(reasoning.text) <= 503
      assert reasoning.full_text == thinking
    end

    test "cap the operator reasoning copy at 16 KB" do
      thinking = String.duplicate("y", 40_000)

      translator()
      |> RunTranslator.handle_event({:message_update, %{}, {:thinking_end, 0, thinking, nil}})

      assert_receive {:action_event,
                      %{kind: :reasoning, phase: :completed, detail: %{reasoning: reasoning}}}

      assert byte_size(reasoning.full_text) < 16_384 + 100
      assert reasoning.full_text =~ "bytes of reasoning omitted"
    end
  end
end
