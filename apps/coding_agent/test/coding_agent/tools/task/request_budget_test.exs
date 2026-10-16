defmodule CodingAgent.Tools.Task.RequestBudgetTest do
  use ExUnit.Case, async: false

  alias CodingAgent.SettingsManager
  alias CodingAgent.Tools.Task.{Execution, Params, Result, Runner}
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.AgentToolResult

  defmodule FakeSession do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok,
       %{
         owner: opts[:owner],
         turns: opts[:turns],
         count: 0,
         messages: [],
         delivery: nil,
         session_id: "budget-fake",
         is_streaming: false
       }}
    end

    @impl true
    def handle_call(:get_stats, _from, state), do: {:reply, state, state}
    def handle_call(:get_state, _from, state), do: {:reply, state, state}
    def handle_call(:get_messages, _from, state), do: {:reply, state.messages, state}

    def handle_call({:subscribe, pid, :direct, opts}, _from, state) do
      if state.delivery, do: LemonCore.Bus.Delivery.close(state.delivery)
      delivery = LemonCore.Bus.Delivery.new(pid, tagged: Keyword.get(opts, :tagged, false))
      unsubscribe = fn -> LemonCore.Bus.Delivery.close(delivery) end
      subscription = if opts[:tagged], do: {unsubscribe, delivery}, else: unsubscribe
      {:reply, subscription, %{state | delivery: delivery}}
    end

    def handle_call({:prompt, _text, _opts}, _from, state) do
      send(self(), :emit)
      {:reply, :ok, %{state | is_streaming: true}}
    end

    @impl true
    def handle_cast({:steer, text}, state) do
      send(state.owner, {:notice, state.count, text})
      {:noreply, state}
    end

    def handle_cast(:abort, state) do
      send(state.owner, {:budget_abort, state.count})

      LemonCore.Bus.Delivery.send(
        state.delivery,
        {:session_event, state.session_id, {:canceled, :aborted}}
      )

      {:noreply, %{state | is_streaming: false}}
    end

    @impl true
    def handle_info(:emit, %{is_streaming: false} = state), do: {:noreply, state}

    def handle_info(:emit, state) do
      count = state.count + 1
      message = Mocks.assistant_message("finding-#{count}")
      messages = state.messages ++ [message]

      LemonCore.Bus.Delivery.send(
        state.delivery,
        {:session_event, state.session_id, {:message_end, message}}
      )

      if count < state.turns do
        Process.send_after(self(), :emit, 15)
      else
        LemonCore.Bus.Delivery.send(
          state.delivery,
          {:session_event, state.session_id, {:agent_end, messages}}
        )
      end

      {:noreply, %{state | count: count, messages: messages, is_streaming: count < state.turns}}
    end
  end

  test "steers once at the soft budget and gracefully returns the hard-limit partial" do
    result = run(20, request_budget: 2)
    assert_receive {:notice, 2, text}
    assert text =~ "Wrap up"
    refute_receive {:notice, _, _}
    assert_receive {:budget_abort, 3}

    assert %AgentToolResult{
             is_error: false,
             details: %{
               budget_exhausted: true,
               partial: true,
               request_count: 3,
               request_budget: 2,
               partial_output: "finding-3"
             }
           } = result

    assert Result.visible_output_text(result) =~ "stopped at request budget 3"
  end

  test "rounds the hard limit up for odd soft budgets" do
    assert %{details: %{request_count: 5}} = run(20, request_budget: 3)
    assert_receive {:notice, 3, _}
    assert_receive {:budget_abort, 5}
  end

  test "zero disables notices and stops" do
    result = run(5, request_budget: 0)
    refute result.details[:budget_exhausted]
    assert Result.visible_output_text(result) == "finding-5"
    refute_receive {:notice, _, _}
    refute_receive {:budget_abort, _}
  end

  test "notice can be disabled without disabling the hard stop" do
    assert %{details: %{budget_exhausted: true}} =
             run(20, request_budget: 2, request_budget_notice: false)

    refute_receive {:notice, _, _}
    assert_receive {:budget_abort, 3}
  end

  @tag :tmp_dir
  test "per-item overrides beat the global default, including zero", %{tmp_dir: cwd} do
    settings = %SettingsManager{
      task:
        Map.merge(
          %SettingsManager{}.task,
          %{request_budget: 8, request_budget_notice: false}
        )
    }

    assert {:ok, default} =
             Params.validate_run_params(%{"prompt" => "Work"}, cwd, settings_manager: settings)

    assert default.request_budget == 8
    refute default.request_budget_notice

    for override <- [0, 2] do
      assert {:ok, item} =
               Params.validate_run_params(
                 %{"prompt" => "Work", "request_budget" => override},
                 cwd,
                 settings_manager: settings
               )

      assert item.request_budget == override
    end

    for invalid <- [-1, 1.5, "2", nil] do
      assert {:error, "request_budget must be a nonnegative integer"} =
               Params.validate_run_params(%{"prompt" => "Work", "request_budget" => invalid}, cwd,
                 settings_manager: settings
               )
    end
  end

  test "structured output exhaustion preserves partial text and skips correction retries" do
    result = run(20, request_budget: 2, validate_output: fn _ -> {:error, "expected JSON"} end)
    assert result.details.request_count == 3

    for mode <- ["strict", "permissive"] do
      validated =
        Execution.validate_output(result, %{
          output_schema: %{"type" => "object"},
          schema_mode: mode
        })

      assert validated.is_error
      assert validated.details.budget_exhausted
      assert validated.details.structured_output_error
      assert Result.visible_output_text(validated) =~ "finding-3"

      assert Result.visible_output_text(validated) =~
               "Structured output missing at request budget"
    end
  end

  test "a valid structured partial is decoded without the budget annotation" do
    result = %AgentToolResult{
      content: [],
      details: %{budget_exhausted: true, partial_output: ~s({"answer": 1})}
    }

    validated = Execution.validate_output(result, %{output_schema: %{"type" => "object"}})
    assert validated.details.structured_output == %{"answer" => 1}
  end

  test "schema correction requests share the original run budget" do
    result = run(1, request_budget: 2, validate_output: fn _ -> {:error, "invalid"} end)
    assert result.details.budget_exhausted
    assert result.details.request_count == 3
    assert_receive {:notice, 2, _}
    assert_receive {:budget_abort, 3}
  end

  defp run(turns, opts) do
    session = start_supervised!({FakeSession, owner: self(), turns: turns})

    resume = %{
      start_opts: [],
      description: "Budget child",
      role_id: nil,
      opts: Keyword.merge([task_session_timeout_ms: 2_000, task_session_poll_ms: 5], opts)
    }

    Runner.resume_session(session, resume, "Work", nil, nil)
  end
end
