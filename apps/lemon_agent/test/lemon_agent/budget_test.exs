defmodule LemonAgent.BudgetTest do
  use ExUnit.Case, async: true

  alias LemonAgent.{Budget, EventStream, Loop}
  alias LemonAgent.Loop.TranscriptValidator
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig}
  alias LemonAi.Types.{Cost, Usage}

  test "projection prices measured input and the requested output in millions of tokens" do
    model = %{Mocks.mock_model() | cost: %LemonAi.Types.ModelCost{input: 2, output: 10}}

    context = %LemonAi.Types.Context{
      messages: [%{usage: %Usage{input: 100, cache_read: 20, cache_write: 30}}]
    }

    projection = Budget.project(model, context, %LemonAi.Types.StreamOptions{max_tokens: 50})
    assert projection.tokens == 200
    assert_in_delta projection.cost_usd, 0.0008, 0.00000001
  end

  test "fallback estimates system, messages and schemas and uses model output default" do
    model = %{Mocks.mock_model() | max_tokens: 10, cost: nil}

    context = %LemonAi.Types.Context{
      system_prompt: "1234",
      messages: [%{content: "5678"}],
      tools: [%{description: "abcd", parameters: %{"description" => "efgh"}}]
    }

    assert Budget.project(model, context, %LemonAi.Types.StreamOptions{}) ==
             %{tokens: 17, cost_usd: nil}
  end

  test "unknown projected pricing fails closed without changing nullable provider telemetry" do
    model = %{Mocks.mock_model() | cost: %LemonAi.Types.ModelCost{input: nil, output: 10}}

    usage = %Usage{
      input: nil,
      output: nil,
      cache_read: nil,
      cache_write: nil,
      total_tokens: nil,
      cost: %Cost{total: nil}
    }

    context = %LemonAi.Types.Context{messages: [%{usage: usage}]}
    projection = Budget.project(model, context, %LemonAi.Types.StreamOptions{max_tokens: 50})
    assert is_integer(projection.tokens)
    assert projection.tokens >= 50
    assert projection.cost_usd == nil

    for key <- [:max_run_cost_usd, :max_session_cost_usd] do
      assert %{metric: :cost_usd, used: +0.0, message: message} =
               Budget.check(Budget.new(%{key => 1}, nil), projection)

      assert message =~ "cannot be verified"
    end

    refute Budget.check(Budget.new(%{max_run_tokens: projection.tokens + 1}, nil), projection)
    refute Budget.check(Budget.new(%{}, nil), projection)
    assert Budget.unpriced_warning(%{max_run_cost_usd: 1}, model) =~ "no known catalog price"
    assert Budget.usage_from_message(%{usage: usage}) == %{tokens: nil, cost_usd: nil}
    assert is_nil(usage.input)
    assert is_nil(usage.cost.total)
  end

  test "projections enforce both scopes without charging estimated usage" do
    projected = %{tokens: 100, cost_usd: 0.5}

    for key <- [:max_run_cost_usd, :max_session_cost_usd] do
      budget = Budget.new(%{key => 1}, %{cost_usd: 0.6})
      budget = %{budget | run_usage: %{tokens: 0, cost_usd: 0.6}}
      assert %{used: 0.6, message: message} = Budget.check(budget, projected)
      assert message =~ "next request is projected to exceed"
      assert budget.run_usage.cost_usd == 0.6
      refute Budget.check(Budget.new(%{key => 1}, nil), projected)
      refute Budget.check(Budget.new(%{key => 0.5}, nil), projected)
    end

    for key <- [:max_run_tokens, :max_session_tokens] do
      assert Budget.check(Budget.new(%{key => 99}, nil), projected)
      refute Budget.check(Budget.new(%{key => 101}, nil), projected)
    end

    refute Budget.check(Budget.new(%{}, nil), projected)
    refute Budget.check(nil, projected)
  end

  test "projected dollar refusal never calls the provider" do
    parent = self()
    stream_fn = fn _, _, _ -> send(parent, :unexpected_model_call) end
    model = %{Mocks.mock_model() | cost: %LemonAi.Types.ModelCost{input: 1, output: 100}}
    events = run(%{max_run_cost_usd: 0.1}, stream_fn, model: model)
    assert {:budget_exceeded, %{used: used, message: message}} = budget_stop(events)
    assert used == 0
    assert message =~ "next request is projected to exceed"
    refute_received :unexpected_model_call
    refute Enum.any?(events, &match?({:provider_retry, _}, &1))
  end

  test "under-budget first requests and explicitly free models still call the provider" do
    for {cost, cap} <- [
          {%LemonAi.Types.ModelCost{input: 1, output: 10}, 1},
          {%LemonAi.Types.ModelCost{}, 0.000001}
        ] do
      model = %{Mocks.mock_model() | cost: cost}
      message = Mocks.assistant_message("answer", usage: %Usage{})
      events = run(%{max_run_cost_usd: cap}, responses([message], self()), model: model)
      assert_received {:model_call, []}
      assert {:agent_end, [_prompt, ^message]} = List.last(events)
    end
  end

  test "unpriced dollar-capped requests are blocked while known free prices need no warning" do
    model = Mocks.mock_model()

    for key <- [:max_run_cost_usd, :max_session_cost_usd],
        cost <- [nil, %LemonAi.Types.ModelCost{input: nil}] do
      events = run(%{key => 1}, responses([], self()), model: %{model | cost: cost})
      assert {:budget_exceeded, %{metric: :cost_usd, message: message}} = budget_stop(events)
      assert message =~ "cannot be verified"
      refute_received {:model_call, _}
    end

    refute Budget.unpriced_warning(%{max_run_cost_usd: 1}, model)

    refute Budget.unpriced_warning(%{max_run_tokens: 10}, model)

    refute Budget.unpriced_warning(%{max_session_cost_usd: 1}, %{
             model
             | cost: %LemonAi.Types.ModelCost{input: 1.0}
           })
  end

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
             %{tokens: nil, cost_usd: nil}

    assert Budget.add_usage(%{tokens: 3, cost_usd: 1}, %{tokens: 5, cost_usd: 0.25}) ==
             %{tokens: 8, cost_usd: 1.25}

    assert Budget.usage_from_message(%{"usage" => %{"input" => 4, "cost" => %{"total" => 2}}}) ==
             %{tokens: nil, cost_usd: 2}
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

    message = Mocks.assistant_message_with_tool_calls(calls, usage: usage(7_000, 0.4))
    tool = %{Mocks.echo_tool() | execute: fn _, _, _, _ -> send(parent, :tool_side_effect) end}
    stream_fn = responses([message], parent)
    events = run(%{max_run_tokens: 7_000}, stream_fn, tools: [tool])

    assert_received {:model_call, []}
    refute_received {:model_call, _}
    refute_received :tool_side_effect
    refute Enum.any?(events, &match?({:tool_execution_start, _, _, _}, &1))

    assert {:error, {:budget_exceeded, details}, %{new_messages: transcript}} = List.last(events)
    assert details.run_usage == %{tokens: 7_000, cost_usd: 0.4}
    assert :ok == TranscriptValidator.validate(transcript)
    rejected = Enum.filter(transcript, &(&1.role == :tool_result))
    assert Enum.map(rejected, & &1.tool_call_id) == Enum.map(calls, & &1.id)
    assert Enum.all?(rejected, &(&1.is_error and &1.details.reason == :budget_exceeded))
    assert Enum.any?(transcript, &(&1 == message))

    usage_index =
      Enum.find_index(
        events,
        &match?({:usage_budget_updated, %{run_usage: %{tokens: 7_000}}}, &1)
      )

    end_index = Enum.find_index(events, &match?({:message_end, %{role: :assistant}}, &1))
    assert usage_index < end_index
  end

  test "estimated dollar exhaustion stops tool side effects even below the token cap" do
    parent = self()
    call = Mocks.tool_call("echo", %{"text" => "write"})
    message = Mocks.assistant_message_with_tool_calls([call], usage: usage(2, 0.75))
    tool = %{Mocks.echo_tool() | execute: fn _, _, _, _ -> send(parent, :tool_side_effect) end}

    events =
      run(%{max_run_tokens: 10_000, max_session_cost_usd: 0.5}, responses([message], parent),
        tools: [tool]
      )

    assert {:budget_exceeded, %{scope: :session, metric: :cost_usd, used: 0.75}} =
             budget_stop(events)

    refute_received :tool_side_effect
  end

  test "partial and final reports from one attempt count only once" do
    parent = self()
    message = Mocks.assistant_message("answer", usage: usage(6, 0.2))
    events = run(%{max_run_tokens: 10_000}, responses([message], parent))

    updates = for {:usage_budget_updated, update} <- events, do: update
    assert Enum.map(updates, & &1.run_usage.tokens) == [0, 6]
    assert List.last(updates).session_usage == %{tokens: 6, cost_usd: 0.2}
    assert for({:provider_usage, observation} <- events, do: observation) == [message]
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
    events = run(%{max_run_tokens: 10_000}, responses([failure, success], parent))

    assert_received {:model_call, []}
    assert_received {:model_call, []}
    refute_received {:model_call, _}
    updates = for {:usage_budget_updated, update} <- events, do: update
    assert Enum.map(updates, & &1.run_usage.tokens) == [0, 3, 7]
    assert_in_delta List.last(updates).session_usage.cost_usd, 0.3, 0.000001
    assert {:agent_end, [_prompt, ^success]} = List.last(events)
    assert for({:provider_usage, observation} <- events, do: observation) == [failure, success]
    refute Enum.any?(events, &match?({:message_end, %{stop_reason: :error}}, &1))
  end

  test "committed output blocks replay while its reported usage stays spent" do
    parent = self()

    failure =
      Mocks.assistant_message("partial",
        usage: usage(3, 0.1),
        stop_reason: :error,
        error_message: "Service temporarily unavailable (HTTP 503)"
      )

    events = run(%{max_run_tokens: 10_000}, responses([failure], parent))

    assert_received {:model_call, []}
    refute_received {:model_call, _}
    refute Enum.any?(events, &match?({:provider_retry, _}, &1))
    updates = for {:usage_budget_updated, update} <- events, do: update
    assert Enum.map(updates, & &1.run_usage.tokens) == [0, 3]
    assert List.last(updates).session_usage == %{tokens: 3, cost_usd: 0.1}

    assert {:error, {:assistant_error, _}, %{new_messages: [_prompt, reported_failure]}} =
             List.last(events)

    assert %{output_committed: true, status: 503} = reported_failure.error_details
    assert %{reported_failure | error_details: nil} == failure
  end

  test "reported error usage crossing the cap blocks retry and pairs requested tools" do
    parent = self()
    call = Mocks.tool_call("echo", %{"text" => "never"})

    failure =
      Mocks.assistant_message_with_tool_calls([call],
        usage: usage(9_000, 0.1),
        stop_reason: :error,
        error_message: "Service temporarily unavailable (HTTP 503)"
      )

    tool = %{Mocks.echo_tool() | execute: fn _, _, _, _ -> send(parent, :tool_side_effect) end}
    events = run(%{max_run_tokens: 9_000}, responses([failure], parent), tools: [tool])

    assert_received {:model_call, []}
    refute_received {:model_call, _}
    refute_received :tool_side_effect
    refute Enum.any?(events, &match?({:provider_retry, _}, &1))

    assert {:error, {:budget_exceeded, %{used: 9_000}}, %{new_messages: transcript}} =
             List.last(events)

    assert :ok == TranscriptValidator.validate(transcript)
    assert List.last(transcript).tool_call_id == call.id
    assert List.last(transcript).is_error
  end

  test "invoked failed requests without usage leave capped spend unknown and stop retries" do
    parent = self()

    stream_fn = fn _, _, _ ->
      send(parent, :model_call)
      {:error, :timeout}
    end

    events = run(%{max_run_tokens: 10_000}, stream_fn)
    updates = for {:usage_budget_updated, update} <- events, do: update

    assert Enum.map(updates, & &1.run_usage) == [
             %{tokens: 0, cost_usd: 0.0},
             %{tokens: nil, cost_usd: nil}
           ]

    assert_received :model_call
    refute_received :model_call

    assert [{:provider_usage, observation}] =
             Enum.filter(events, &match?({:provider_usage, _}, &1))

    assert observation.usage == nil
    assert {:budget_exceeded, %{metric: :tokens, used: nil}} = budget_stop(events)
    refute Enum.any?(events, &match?({:provider_retry, _}, &1))
    assert match?({:error, {:budget_exceeded, _}, _}, List.last(events))
  end

  test "a reported direct assistant failure retains spending and stops retries" do
    parent = self()

    failure =
      Mocks.assistant_message("spent failure",
        usage: usage(5_000, 0.2),
        stop_reason: :error,
        error_message: "Service temporarily unavailable (HTTP 503)"
      )

    stream_fn = fn _, _, _ ->
      send(parent, :direct_call)
      {:error, failure}
    end

    events = run(%{max_run_tokens: 5_000}, stream_fn)

    assert_received :direct_call
    refute_received :direct_call

    assert {:error, {:budget_exceeded, %{used: 5_000}},
            %{new_messages: [_prompt, reported_failure]}} =
             List.last(events)

    assert %{output_committed: true, status: 503} = reported_failure.error_details
    assert %{reported_failure | error_details: nil} == failure

    refute Enum.any?(events, &match?({:provider_retry, _}, &1))
  end

  test "cumulative usage across tool turns rejects later effects and requests" do
    parent = self()
    first_call = Mocks.tool_call("echo", %{"text" => "first"})
    second_call = Mocks.tool_call("echo", %{"text" => "second"})
    first = Mocks.assistant_message_with_tool_calls([first_call], usage: usage(2_000, 0.1))
    second = Mocks.assistant_message_with_tool_calls([second_call], usage: usage(5_000, 0.2))
    original = Mocks.echo_tool()

    tool = %{
      original
      | execute: fn id, args, signal, update ->
          send(parent, {:side_effect, id})
          original.execute.(id, args, signal, update)
        end
    }

    events = run(%{max_run_tokens: 7_000}, responses([first, second], parent), tools: [tool])

    assert_received {:side_effect, id}
    assert id == first_call.id
    refute_received {:side_effect, _}
    assert_received {:model_call, []}
    assert_received {:model_call, [^first]}
    refute_received {:model_call, _}

    assert {:error, {:budget_exceeded, %{used: 7_000}}, %{new_messages: transcript}} =
             List.last(events)

    assert :ok == TranscriptValidator.validate(transcript)
    assert List.last(transcript).tool_call_id == second_call.id
    assert List.last(transcript).is_error
  end

  test "continuing an exhausted prompt does not reset its run budget" do
    parent = self()
    call = Mocks.tool_call("echo", %{"text" => "never"})
    message = Mocks.assistant_message_with_tool_calls([call], usage: usage(5_000, 0.1))

    agent =
      start_supervised!(
        {LemonAgent.Agent,
         initial_state: %{model: Mocks.mock_model(), tools: [Mocks.echo_tool()]},
         budget_limits: %{max_run_tokens: 5_000},
         stream_fn: responses([message], parent)}
      )

    assert :ok = LemonAgent.Agent.prompt(agent, "first")
    assert :ok = LemonAgent.Agent.wait_for_idle(agent, timeout: 5_000)
    assert :ok = LemonAgent.Agent.continue(agent)
    assert :ok = LemonAgent.Agent.wait_for_idle(agent, timeout: 5_000)
    assert LemonAgent.Agent.get_state(agent).run_usage.tokens == 5_000
    assert LemonAgent.Agent.get_state(agent).budget_usage.tokens == 5_000
    assert_received {:model_call, []}
    refute_received {:model_call, _}
  end

  test "all omitted caps leave the ordinary path without usage budget events" do
    parent = self()
    message = Mocks.assistant_message("answer", usage: usage(6, 0.2))
    events = run(%{}, responses([message], parent))
    refute Enum.any?(events, &match?({:usage_budget_updated, _}, &1))
    assert for({:provider_usage, observation} <- events, do: observation) == [message]
    assert {:agent_end, [_prompt, ^message]} = List.last(events)
  end

  test "run counters reset per prompt but initial session spending survives history replacement and reset" do
    parent = self()
    message = Mocks.assistant_message("answer", usage: usage(5_000, 0.1))

    agent =
      start_supervised!(
        {LemonAgent.Agent,
         initial_state: %{model: Mocks.mock_model()},
         budget_limits: %{max_run_tokens: 5_000, max_session_tokens: 11_000},
         budget_usage: %{tokens: 2, cost_usd: 0.2},
         stream_fn: responses([message, message], parent)}
      )

    LemonAgent.Agent.subscribe(agent, self())

    for prompt <- ["first", "second"] do
      assert :ok = LemonAgent.Agent.prompt(agent, prompt)
      assert :ok = LemonAgent.Agent.wait_for_idle(agent, timeout: 5_000)
      assert LemonAgent.Agent.get_state(agent).run_usage.tokens == 5_000
      assert :ok = LemonAgent.Agent.replace_messages(agent, [])
    end

    assert LemonAgent.Agent.get_state(agent).budget_usage.tokens == 10_002
    assert :ok = LemonAgent.Agent.reset(agent)
    assert LemonAgent.Agent.get_state(agent).budget_usage.tokens == 10_002
    assert :ok = LemonAgent.Agent.prompt(agent, "third")
    assert :ok = LemonAgent.Agent.wait_for_idle(agent, timeout: 5_000)
    # The next request's projection exceeds the remaining session budget.
    assert LemonAgent.Agent.get_state(agent).budget_usage.tokens == 10_002
    assert :ok = LemonAgent.Agent.reset(agent)
    assert :ok = LemonAgent.Agent.prompt(agent, "already spent")
    assert :ok = LemonAgent.Agent.wait_for_idle(agent, timeout: 5_000)
    assert LemonAgent.Agent.get_state(agent).budget_usage.tokens == 10_002
    assert_received {:agent_event, {:budget_exceeded, %{scope: :session, used: 10_002}}}
    assert LemonAgent.Agent.get_state(agent).error =~ "Increase budgets.max_session_tokens"
    assert_received {:model_call, []}
    assert_received {:model_call, []}
    refute_received {:model_call, _}
  end

  test "unknown accumulated metrics survive normalization and subsequent known reports" do
    for unknown <- [
          %{tokens: nil, cost_usd: 0.25},
          %{tokens: 130, cost_usd: nil},
          %{tokens: nil, cost_usd: nil}
        ] do
      assert Budget.normalize_usage(unknown) == unknown

      assert Budget.normalize_usage(Map.new(unknown, fn {k, v} -> {Atom.to_string(k), v} end)) ==
               unknown

      summed = Budget.add_usage(unknown, %{tokens: 1, cost_usd: 0.1})

      for {key, metric} <- [
            {:max_run_tokens, :tokens},
            {:max_session_tokens, :tokens},
            {:max_run_cost_usd, :cost_usd},
            {:max_session_cost_usd, :cost_usd}
          ] do
        budget = %{Budget.new(%{key => 10_000}, summed) | run_usage: summed}

        if is_nil(unknown[metric]) do
          assert summed[metric] == nil
          assert %{metric: ^metric, used: nil} = Budget.check(budget)
        else
          refute Budget.check(budget)
        end
      end

      refute Budget.check(%{Budget.new(%{}, summed) | run_usage: summed})
    end
  end

  test "nullable token reports fail closed unless an independent total is known" do
    partial = %Usage{
      input: nil,
      output: 30,
      cache_read: 20,
      cache_write: nil,
      total_tokens: nil,
      cost: %Cost{total: 0.25}
    }

    assert Budget.usage_from_message(%{usage: partial}) == %{tokens: nil, cost_usd: 0.25}

    assert Budget.usage_from_message(%{usage: %{partial | total_tokens: 130}}) ==
             %{tokens: 130, cost_usd: 0.25}

    assert Budget.usage_from_message(%{role: :assistant, usage: nil}) ==
             %{tokens: nil, cost_usd: nil}

    assert Budget.usage_from_message(%{role: "assistant"}) == %{tokens: nil, cost_usd: nil}

    assert Budget.usage_from_message(%{role: "user", content: "not billable"}) ==
             %{tokens: 0, cost_usd: 0.0}
  end

  test "unknown projected output fails closed under token caps without affecting uncapped requests" do
    model = %{priced_model() | max_tokens: nil}
    projection = Budget.project(model, %LemonAi.Types.Context{}, %LemonAi.Types.StreamOptions{})
    assert projection.tokens == nil

    for key <- [:max_run_tokens, :max_session_tokens] do
      assert %{metric: :tokens, used: 0, message: message} =
               Budget.check(Budget.new(%{key => 10_000}, nil), projection)

      assert message =~ "cannot be verified"
      refute message =~ "Increase budgets"
    end

    refute Budget.check(Budget.new(%{}, nil), projection)
  end

  test "repeated faithful ZAI partial reports cannot authorize another dollar-capped request" do
    # Matches the faithful ZAI usage-only provider fixture: the total is reported,
    # but missing cache writes leave input and total dollar cost unknown.
    partial = %Usage{
      input: nil,
      output: 30,
      cache_read: 20,
      cache_write: nil,
      total_tokens: 130,
      cost: %Cost{input: nil, output: 0.00006, cache_read: 0.000002, cache_write: nil, total: nil}
    }

    call = Mocks.tool_call("echo", %{"text" => "must not run"})
    message = Mocks.assistant_message_with_tool_calls([call], usage: partial)

    for {key, scope} <- [{:max_run_cost_usd, :run}, {:max_session_cost_usd, :session}] do
      budget = Budget.new(%{key => 1}, nil)
      once = Budget.record_message(budget, message)
      twice = Budget.record_message(once, message)
      assert once.run_usage == %{tokens: 130, cost_usd: nil}
      assert twice.run_usage == %{tokens: 260, cost_usd: nil}
      assert %{scope: ^scope, metric: :cost_usd, used: nil} = Budget.check(twice)

      events =
        run(%{key => 1}, responses([message, message], self()),
          model: priced_model(),
          tools: [Mocks.echo_tool()]
        )

      assert_received {:model_call, []}
      refute_received {:model_call, _}

      assert {:budget_exceeded, %{scope: ^scope, metric: :cost_usd, used: nil}} =
               budget_stop(events)

      refute Enum.any?(events, &match?({:tool_execution_start, _, _, _}, &1))
      assert for({:provider_usage, observation} <- events, do: observation) == [message]
      assert {:error, {:budget_exceeded, _}, %{new_messages: transcript}} = List.last(events)
      assert :ok == TranscriptValidator.validate(transcript)
    end

    agent =
      start_supervised!(
        {LemonAgent.Agent,
         initial_state: %{model: priced_model()},
         budget_limits: %{max_session_cost_usd: 1},
         stream_fn: responses([Mocks.assistant_message("answer", usage: partial)], self())}
      )

    for prompt <- ["first", "second", "third"] do
      assert :ok = LemonAgent.Agent.prompt(agent, prompt)
      assert :ok = LemonAgent.Agent.wait_for_idle(agent, timeout: 5_000)
      assert :ok = LemonAgent.Agent.replace_messages(agent, [])
    end

    assert LemonAgent.Agent.get_state(agent).budget_usage == %{tokens: 130, cost_usd: nil}
    assert_received {:model_call, []}
    refute_received {:model_call, _}
    assert partial.input == nil
    assert partial.cost.total == nil
  end

  test "unknown dollars do not stop token-only or uncapped repeated provider calls" do
    partial = %Usage{total_tokens: 130, cost: %Cost{total: nil}}

    first =
      Mocks.assistant_message_with_tool_calls(
        [Mocks.tool_call("echo", %{"text" => "continue"})],
        usage: partial
      )

    last = Mocks.assistant_message("answer", usage: partial)

    for limits <- [%{}, %{max_run_tokens: 10_000}] do
      events = run(limits, responses([first, last], self()), tools: [Mocks.echo_tool()])
      assert_received {:model_call, []}
      assert_received {:model_call, [^first]}
      refute_received {:model_call, _}
      refute budget_stop(events)
      assert match?({:agent_end, _}, List.last(events))
    end
  end

  defp priced_model do
    %{Mocks.mock_model() | cost: %LemonAi.Types.ModelCost{input: 1, output: 1}}
  end

  defp usage(tokens, cost), do: %Usage{total_tokens: tokens, cost: %Cost{total: cost}}

  defp run(limits, stream_fn, opts \\ []) do
    config = %AgentLoopConfig{
      model: Keyword.get(opts, :model, Mocks.mock_model()),
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
