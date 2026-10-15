defmodule LemonAgent.BudgetTest do
  use ExUnit.Case, async: true

  alias LemonAgent.{Budget, EventStream, Loop}
  alias LemonAgent.Loop.TranscriptValidator
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig}
  alias LemonAi.Types.{Cost, Usage}

  test "cache-write-long is a subset, and a populated provider total takes precedence" do
    usage = %Usage{
      input: 11,
      output: 7,
      cache_read: 13,
      cache_write: 17,
      cache_write_long: 9,
      cost: %Cost{input: 0.1, output: 0.2, total: 0.3}
    }

    assert Budget.usage_from_message(%{usage: usage}) == %{tokens: 48, cost_usd: 0.3}

    assert Budget.usage_from_message(%{usage: %{usage | total_tokens: 29}}) ==
             %{tokens: 29, cost_usd: 0.3}
  end

  test "ledger normalization accepts serialized totals and excludes invalid negative values" do
    assert Budget.normalize_usage(%{"tokens" => 8, "cost_usd" => 2}) ==
             %{tokens: 8, cost_usd: 2}

    assert Budget.normalize_usage(%{tokens: -1, cost_usd: -0.5}) ==
             %{tokens: 0, cost_usd: 0.0}

    assert Budget.add_usage(%{tokens: 3, cost_usd: 1}, %{tokens: 5, cost_usd: 0.25}) ==
             %{tokens: 8, cost_usd: 1.25}

    assert Budget.usage_from_message(%{"usage" => %{"input" => 4, "cost" => %{"total" => 2}}}) ==
             %{tokens: 4, cost_usd: 2}
  end

  test "all four zero caps forbid any provider request" do
    parent = self()

    for key <- [:max_run_tokens, :max_run_cost_usd, :max_session_tokens, :max_session_cost_usd] do
      stream_fn = fn _, _, _ ->
        send(parent, :unexpected_model_call)
        {:error, :unexpected_model_call}
      end

      events = run(%{key => 0}, stream_fn)

      assert {:budget_exceeded, %{limit: 0, used: used, reason: :budget_exceeded}} =
               budget_stop(events)

      assert used == 0

      assert {:error, {:budget_exceeded, details}, %{new_messages: [prompt]}} = List.last(events)
      assert prompt.role == :user
      assert details.message =~ "Increase budgets.#{key}"
      refute Enum.any?(events, &match?({:provider_retry, _}, &1))
    end

    refute_received :unexpected_model_call
  end

  test "already-spent session totals forbid a request even with an empty transcript" do
    parent = self()
    stream_fn = fn _, _, _ -> send(parent, :unexpected_model_call) end
    initial = %{tokens: 12, cost_usd: 0.5}
    events = run(%{max_session_tokens: 10}, stream_fn, budget_usage: initial)

    assert {:budget_exceeded, %{scope: :session, used: 12, session_usage: ^initial}} =
             budget_stop(events)

    refute_received :unexpected_model_call
  end

  test "completed usage rejects every tool without effects or follow-up model calls" do
    parent = self()

    calls = [
      Mocks.tool_call("echo", %{"text" => "one"}),
      Mocks.tool_call("echo", %{"text" => "two"})
    ]

    message = Mocks.assistant_message_with_tool_calls(calls, usage: usage(7, 0.4))
    tool = %{Mocks.echo_tool() | execute: fn _, _, _, _ -> send(parent, :tool_side_effect) end}
    stream_fn = responses([message], parent)
    events = run(%{max_run_tokens: 7}, stream_fn, tools: [tool])

    assert_received {:model_call, []}
    refute_received {:model_call, _}
    refute_received :tool_side_effect
    refute Enum.any?(events, &match?({:tool_execution_start, _, _, _}, &1))

    assert {:error, {:budget_exceeded, details}, %{new_messages: transcript}} = List.last(events)
    assert details.run_usage == %{tokens: 7, cost_usd: 0.4}
    assert :ok == TranscriptValidator.validate(transcript)
    rejected = Enum.filter(transcript, &(&1.role == :tool_result))
    assert Enum.map(rejected, & &1.tool_call_id) == Enum.map(calls, & &1.id)
    assert Enum.all?(rejected, &(&1.is_error and &1.details.reason == :budget_exceeded))
    assert Enum.any?(transcript, &(&1 == message))

    usage_index =
      Enum.find_index(events, &match?({:usage_budget_updated, %{run_usage: %{tokens: 7}}}, &1))

    end_index = Enum.find_index(events, &match?({:message_end, %{role: :assistant}}, &1))
    assert usage_index < end_index
  end

  test "estimated dollar exhaustion stops tool side effects even below the token cap" do
    parent = self()
    call = Mocks.tool_call("echo", %{"text" => "write"})
    message = Mocks.assistant_message_with_tool_calls([call], usage: usage(2, 0.75))
    tool = %{Mocks.echo_tool() | execute: fn _, _, _, _ -> send(parent, :tool_side_effect) end}

    events =
      run(%{max_run_tokens: 100, max_session_cost_usd: 0.5}, responses([message], parent),
        tools: [tool]
      )

    assert {:budget_exceeded, %{scope: :session, metric: :cost_usd, used: 0.75}} =
             budget_stop(events)

    refute_received :tool_side_effect
  end

  test "partial and final reports from one attempt count only once" do
    parent = self()
    message = Mocks.assistant_message("answer", usage: usage(6, 0.2))
    events = run(%{max_run_tokens: 100}, responses([message], parent))

    updates = for {:usage_budget_updated, update} <- events, do: update
    assert Enum.map(updates, & &1.run_usage.tokens) == [0, 6]
    assert List.last(updates).session_usage == %{tokens: 6, cost_usd: 0.2}
    assert match?({:agent_end, _}, List.last(events))
  end

  test "reported failed retry usage stays spent without committing the failed attempt" do
    parent = self()

    failure =
      Mocks.assistant_message("",
        usage: usage(3, 0.1),
        stop_reason: :error,
        error_message: "Service temporarily unavailable (HTTP 503)"
      )

    success = Mocks.assistant_message("recovered", usage: usage(4, 0.2))
    events = run(%{max_run_tokens: 100}, responses([failure, success], parent))

    assert_received {:model_call, []}
    assert_received {:model_call, []}
    refute_received {:model_call, _}
    updates = for {:usage_budget_updated, update} <- events, do: update
    assert Enum.map(updates, & &1.run_usage.tokens) == [0, 3, 7]
    assert_in_delta List.last(updates).session_usage.cost_usd, 0.3, 0.000001
    assert {:agent_end, [_prompt, ^success]} = List.last(events)
  end

  test "committed output blocks replay while its reported usage stays spent" do
    parent = self()

    failure =
      Mocks.assistant_message("partial",
        usage: usage(3, 0.1),
        stop_reason: :error,
        error_message: "Service temporarily unavailable (HTTP 503)"
      )

    events = run(%{max_run_tokens: 100}, responses([failure], parent))

    assert_received {:model_call, []}
    refute_received {:model_call, _}
    refute Enum.any?(events, &match?({:provider_retry, _}, &1))
    updates = for {:usage_budget_updated, update} <- events, do: update
    assert Enum.map(updates, & &1.run_usage.tokens) == [0, 3]
    assert List.last(updates).session_usage == %{tokens: 3, cost_usd: 0.1}

    assert {:error, {:assistant_error, _}, %{new_messages: [_prompt, ^failure]}} =
             List.last(events)
  end

  test "reported error usage crossing the cap blocks retry and pairs requested tools" do
    parent = self()
    call = Mocks.tool_call("echo", %{"text" => "never"})

    failure =
      Mocks.assistant_message_with_tool_calls([call],
        usage: usage(9, 0.1),
        stop_reason: :error,
        error_message: "Service temporarily unavailable (HTTP 503)"
      )

    tool = %{Mocks.echo_tool() | execute: fn _, _, _, _ -> send(parent, :tool_side_effect) end}
    events = run(%{max_run_tokens: 9}, responses([failure], parent), tools: [tool])

    assert_received {:model_call, []}
    refute_received {:model_call, _}
    refute_received :tool_side_effect
    refute Enum.any?(events, &match?({:provider_retry, _}, &1))

    assert {:error, {:budget_exceeded, %{used: 9}}, %{new_messages: transcript}} =
             List.last(events)

    assert :ok == TranscriptValidator.validate(transcript)
    assert List.last(transcript).tool_call_id == call.id
    assert List.last(transcript).is_error
  end

  test "failed requests without usage do not invent spending" do
    parent = self()

    stream_fn = fn _, _, _ ->
      send(parent, :model_call)
      {:error, :timeout}
    end

    events = run(%{max_run_tokens: 10}, stream_fn, max_retries: 0)
    updates = for {:usage_budget_updated, update} <- events, do: update
    assert Enum.all?(updates, &(&1.run_usage == %{tokens: 0, cost_usd: 0.0}))
    refute budget_stop(events)
    assert match?({:error, :timeout, _}, List.last(events))
  end

  test "a reported direct assistant failure retains spending and stops retries" do
    parent = self()

    failure =
      Mocks.assistant_message("spent failure",
        usage: usage(5, 0.2),
        stop_reason: :error,
        error_message: "Service temporarily unavailable (HTTP 503)"
      )

    stream_fn = fn _, _, _ ->
      send(parent, :direct_call)
      {:error, failure}
    end

    events = run(%{max_run_tokens: 5}, stream_fn)

    assert_received :direct_call
    refute_received :direct_call

    assert {:error, {:budget_exceeded, %{used: 5}}, %{new_messages: [_prompt, ^failure]}} =
             List.last(events)

    refute Enum.any?(events, &match?({:provider_retry, _}, &1))
  end

  test "cumulative usage across tool turns rejects later effects and requests" do
    parent = self()
    first_call = Mocks.tool_call("echo", %{"text" => "first"})
    second_call = Mocks.tool_call("echo", %{"text" => "second"})
    first = Mocks.assistant_message_with_tool_calls([first_call], usage: usage(2, 0.1))
    second = Mocks.assistant_message_with_tool_calls([second_call], usage: usage(3, 0.2))
    original = Mocks.echo_tool()

    tool = %{
      original
      | execute: fn id, args, signal, update ->
          send(parent, {:side_effect, id})
          original.execute.(id, args, signal, update)
        end
    }

    events = run(%{max_run_tokens: 5}, responses([first, second], parent), tools: [tool])

    assert_received {:side_effect, id}
    assert id == first_call.id
    refute_received {:side_effect, _}
    assert_received {:model_call, []}
    assert_received {:model_call, [^first]}
    refute_received {:model_call, _}

    assert {:error, {:budget_exceeded, %{used: 5}}, %{new_messages: transcript}} =
             List.last(events)

    assert :ok == TranscriptValidator.validate(transcript)
    assert List.last(transcript).tool_call_id == second_call.id
    assert List.last(transcript).is_error
  end

  test "continuing an exhausted prompt does not reset its run budget" do
    parent = self()
    call = Mocks.tool_call("echo", %{"text" => "never"})
    message = Mocks.assistant_message_with_tool_calls([call], usage: usage(4, 0.1))

    agent =
      start_supervised!(
        {LemonAgent.Agent,
         initial_state: %{model: Mocks.mock_model(), tools: [Mocks.echo_tool()]},
         budget_limits: %{max_run_tokens: 4},
         stream_fn: responses([message], parent)}
      )

    assert :ok = LemonAgent.Agent.prompt(agent, "first")
    assert :ok = LemonAgent.Agent.wait_for_idle(agent, timeout: 5_000)
    assert :ok = LemonAgent.Agent.continue(agent)
    assert :ok = LemonAgent.Agent.wait_for_idle(agent, timeout: 5_000)
    assert LemonAgent.Agent.get_state(agent).run_usage.tokens == 4
    assert LemonAgent.Agent.get_state(agent).budget_usage.tokens == 4
    assert_received {:model_call, []}
    refute_received {:model_call, _}
  end

  test "all omitted caps leave the ordinary path without usage budget events" do
    parent = self()
    message = Mocks.assistant_message("answer", usage: usage(6, 0.2))
    events = run(%{}, responses([message], parent))
    refute Enum.any?(events, &match?({:usage_budget_updated, _}, &1))
    assert {:agent_end, [_prompt, ^message]} = List.last(events)
  end

  test "run counters reset per prompt but initial session spending survives history replacement and reset" do
    parent = self()
    message = Mocks.assistant_message("answer", usage: usage(4, 0.1))

    agent =
      start_supervised!(
        {LemonAgent.Agent,
         initial_state: %{model: Mocks.mock_model()},
         budget_limits: %{max_run_tokens: 4, max_session_tokens: 11},
         budget_usage: %{tokens: 2, cost_usd: 0.2},
         stream_fn: responses([message, message], parent)}
      )

    LemonAgent.Agent.subscribe(agent, self())

    for prompt <- ["first", "second"] do
      assert :ok = LemonAgent.Agent.prompt(agent, prompt)
      assert :ok = LemonAgent.Agent.wait_for_idle(agent, timeout: 5_000)
      assert LemonAgent.Agent.get_state(agent).run_usage.tokens == 4
      assert :ok = LemonAgent.Agent.replace_messages(agent, [])
    end

    assert LemonAgent.Agent.get_state(agent).budget_usage.tokens == 10
    assert :ok = LemonAgent.Agent.reset(agent)
    assert LemonAgent.Agent.get_state(agent).budget_usage.tokens == 10
    assert :ok = LemonAgent.Agent.prompt(agent, "third")
    assert :ok = LemonAgent.Agent.wait_for_idle(agent, timeout: 5_000)
    # One in-flight request may cross a positive cap; this one reports 4 more.
    assert LemonAgent.Agent.get_state(agent).budget_usage.tokens == 14
    assert :ok = LemonAgent.Agent.reset(agent)
    assert :ok = LemonAgent.Agent.prompt(agent, "already spent")
    assert :ok = LemonAgent.Agent.wait_for_idle(agent, timeout: 5_000)
    assert LemonAgent.Agent.get_state(agent).budget_usage.tokens == 14
    assert_received {:agent_event, {:budget_exceeded, %{scope: :session, used: 14}}}
    assert LemonAgent.Agent.get_state(agent).error =~ "Increase budgets.max_session_tokens"
    assert_received {:model_call, []}
    assert_received {:model_call, []}
    assert_received {:model_call, []}
    refute_received {:model_call, _}
  end

  defp usage(tokens, cost), do: %Usage{total_tokens: tokens, cost: %Cost{total: cost}}

  defp run(limits, stream_fn, opts \\ []) do
    config = %AgentLoopConfig{
      model: Mocks.mock_model(),
      convert_to_llm: Mocks.simple_convert_to_llm(),
      budget_limits: limits,
      budget_usage: Keyword.get(opts, :budget_usage),
      max_retries: Keyword.get(opts, :max_retries, 3),
      retry_base_delay_ms: 0,
      retry_max_delay_ms: 0
    }

    context = AgentContext.new(tools: Keyword.get(opts, :tools, []))

    Loop.agent_loop([Mocks.user_message("run")], context, config, nil, stream_fn)
    |> EventStream.events()
    |> Enum.to_list()
  end

  defp budget_stop(events), do: Enum.find(events, &match?({:budget_exceeded, _}, &1))

  defp responses(messages, parent) do
    {:ok, queue} = Agent.start_link(fn -> messages end)

    fn _, context, _ ->
      assistant_messages = Enum.filter(context.messages, &(&1.role == :assistant))
      send(parent, {:model_call, assistant_messages})

      message =
        Agent.get_and_update(queue, fn
          [message] -> {message, [message]}
          [message | rest] -> {message, rest}
        end)

      {:ok, stream} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.push(stream, {:start, message})
      terminal = if message.stop_reason == :error, do: :error, else: :done
      LemonAi.EventStream.push(stream, {terminal, message.stop_reason, message})
      LemonAi.EventStream.complete(stream, message)
      {:ok, stream}
    end
  end
end
