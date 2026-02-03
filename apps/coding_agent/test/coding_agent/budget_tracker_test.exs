defmodule CodingAgent.BudgetTrackerTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{BudgetTracker, RunGraph}

  setup do
    # Clear RunGraph before each test
    RunGraph.clear()
    :ok
  end

  describe "create_budget/1" do
    test "creates budget with specified limits" do
      budget = BudgetTracker.create_budget(max_tokens: 1000, max_cost: 5.0, max_children: 3)

      assert budget.max_tokens == 1000
      assert budget.max_cost == 5.0
      assert budget.max_children == 3
      assert budget.used_tokens == 0
      assert budget.used_cost == 0.0
      assert budget.active_children == 0
    end

    test "creates budget with nil limits when not specified" do
      budget = BudgetTracker.create_budget([])

      assert budget.max_tokens == nil
      assert budget.max_cost == nil
      assert budget.max_children == nil
    end
  end

  describe "create_subagent_budget/2" do
    test "inherits limits from parent" do
      parent_id = RunGraph.new_run(%{type: :parent})
      parent_budget = BudgetTracker.create_budget(max_tokens: 1000, max_cost: 5.0)
      BudgetTracker.store_budget(parent_id, parent_budget)

      child_budget = BudgetTracker.create_subagent_budget(parent_id, [])

      assert child_budget.max_tokens == 1000
      assert child_budget.max_cost == 5.0
    end

    test "applies stricter child limits" do
      parent_id = RunGraph.new_run(%{type: :parent})
      parent_budget = BudgetTracker.create_budget(max_tokens: 1000, max_cost: 5.0)
      BudgetTracker.store_budget(parent_id, parent_budget)

      child_budget = BudgetTracker.create_subagent_budget(parent_id, max_tokens: 500)

      assert child_budget.max_tokens == 500
      assert child_budget.max_cost == 5.0
    end
  end

  describe "record_usage/2" do
    test "records token and cost usage" do
      run_id = RunGraph.new_run(%{type: :test})
      budget = BudgetTracker.create_budget(max_tokens: 1000)
      BudgetTracker.store_budget(run_id, budget)

      :ok = BudgetTracker.record_usage(run_id, tokens: 100, cost: 0.5)

      usage = BudgetTracker.get_usage(run_id)
      assert usage.tokens == 100
      assert usage.cost == 0.5
    end

    test "accumulates usage across multiple calls" do
      run_id = RunGraph.new_run(%{type: :test})
      budget = BudgetTracker.create_budget(max_tokens: 1000)
      BudgetTracker.store_budget(run_id, budget)

      :ok = BudgetTracker.record_usage(run_id, tokens: 100, cost: 0.5)
      :ok = BudgetTracker.record_usage(run_id, tokens: 50, cost: 0.25)

      usage = BudgetTracker.get_usage(run_id)
      assert usage.tokens == 150
      assert usage.cost == 0.75
    end
  end

  describe "check_budget/1" do
    test "returns ok when within budget" do
      run_id = RunGraph.new_run(%{type: :test})
      budget = BudgetTracker.create_budget(max_tokens: 1000, max_cost: 5.0)
      BudgetTracker.store_budget(run_id, budget)

      BudgetTracker.record_usage(run_id, tokens: 100, cost: 0.5)

      assert {:ok, remaining} = BudgetTracker.check_budget(run_id)
      assert remaining.tokens_remaining == 900
      assert remaining.cost_remaining == 4.5
    end

    test "returns error when token limit exceeded" do
      run_id = RunGraph.new_run(%{type: :test})
      budget = BudgetTracker.create_budget(max_tokens: 100)
      BudgetTracker.store_budget(run_id, budget)

      BudgetTracker.record_usage(run_id, tokens: 150)

      assert {:error, :budget_exceeded, details} = BudgetTracker.check_budget(run_id)
      assert details.type == :token_limit_exceeded
      assert details.limit == 100
      assert details.used == 150
    end

    test "returns error when cost limit exceeded" do
      run_id = RunGraph.new_run(%{type: :test})
      budget = BudgetTracker.create_budget(max_cost: 1.0)
      BudgetTracker.store_budget(run_id, budget)

      BudgetTracker.record_usage(run_id, cost: 1.5)

      assert {:error, :budget_exceeded, details} = BudgetTracker.check_budget(run_id)
      assert details.type == :cost_limit_exceeded
    end

    test "returns ok with nil limits" do
      run_id = RunGraph.new_run(%{type: :test})
      budget = BudgetTracker.create_budget([])
      BudgetTracker.store_budget(run_id, budget)

      BudgetTracker.record_usage(run_id, tokens: 999_999_999)

      assert {:ok, _} = BudgetTracker.check_budget(run_id)
    end
  end

  describe "can_spawn_child?/1" do
    test "returns true when under limit" do
      run_id = RunGraph.new_run(%{type: :test})
      budget = BudgetTracker.create_budget(max_children: 3)
      BudgetTracker.store_budget(run_id, budget)

      assert BudgetTracker.can_spawn_child?(run_id) == true
    end

    test "returns false when at limit" do
      run_id = RunGraph.new_run(%{type: :test})
      budget = BudgetTracker.create_budget(max_children: 2)
      BudgetTracker.store_budget(run_id, budget)

      BudgetTracker.child_started(run_id, "child1")
      BudgetTracker.child_started(run_id, "child2")

      assert BudgetTracker.can_spawn_child?(run_id) == false
    end

    test "returns true when no limit set" do
      run_id = RunGraph.new_run(%{type: :test})
      budget = BudgetTracker.create_budget([])
      BudgetTracker.store_budget(run_id, budget)

      assert BudgetTracker.can_spawn_child?(run_id) == true
    end
  end

  describe "child_started/2 and child_completed/2" do
    test "tracks active children count" do
      parent_id = RunGraph.new_run(%{type: :parent})
      child_id = RunGraph.new_run(%{type: :child})

      budget = BudgetTracker.create_budget(max_children: 3)
      BudgetTracker.store_budget(parent_id, budget)

      BudgetTracker.child_started(parent_id, child_id)

      parent_budget = BudgetTracker.get_budget(parent_id)
      assert parent_budget.active_children == 1

      BudgetTracker.child_completed(parent_id, child_id)

      parent_budget = BudgetTracker.get_budget(parent_id)
      assert parent_budget.active_children == 0
    end

    test "aggregates child usage into parent" do
      parent_id = RunGraph.new_run(%{type: :parent})
      child_id = RunGraph.new_run(%{type: :child})

      parent_budget = BudgetTracker.create_budget(max_tokens: 1000)
      BudgetTracker.store_budget(parent_id, parent_budget)

      child_budget = BudgetTracker.create_budget([])
      BudgetTracker.store_budget(child_id, child_budget)

      BudgetTracker.child_started(parent_id, child_id)
      BudgetTracker.record_usage(child_id, tokens: 100, cost: 0.5)
      BudgetTracker.child_completed(parent_id, child_id)

      parent_usage = BudgetTracker.get_usage(parent_id)
      assert parent_usage.tokens == 100
      assert parent_usage.cost == 0.5
    end
  end

  describe "record_response_usage/2" do
    test "extracts usage from response map" do
      run_id = RunGraph.new_run(%{type: :test})
      budget = BudgetTracker.create_budget([])
      BudgetTracker.store_budget(run_id, budget)

      response = %{usage: %{total_tokens: 100, cost: 0.5}}
      BudgetTracker.record_response_usage(run_id, response)

      usage = BudgetTracker.get_usage(run_id)
      assert usage.tokens == 100
      assert usage.cost == 0.5
    end

    test "handles string keys" do
      run_id = RunGraph.new_run(%{type: :test})
      budget = BudgetTracker.create_budget([])
      BudgetTracker.store_budget(run_id, budget)

      response = %{"usage" => %{"total_tokens" => 100, "cost" => 0.5}}
      BudgetTracker.record_response_usage(run_id, response)

      usage = BudgetTracker.get_usage(run_id)
      assert usage.tokens == 100
      assert usage.cost == 0.5
    end
  end
end
