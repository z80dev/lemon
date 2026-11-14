defmodule CodingAgent.BudgetEnforcerTest do
  @moduledoc """
  Tests for the BudgetEnforcer module.

  BudgetEnforcer provides budget enforcement hooks for the agent lifecycle.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.{BudgetEnforcer, BudgetTracker, RunGraph}

  setup do
    RunGraph.clear()
    :ok
  end

  # ============================================================================
  # check_subagent_spawn/2 Tests
  # ============================================================================

  describe "on_run_complete/2" do
    test "completion records string-key nested costs" do
      run_id = RunGraph.new_run(%{type: :test})
      BudgetTracker.store_budget(run_id, BudgetTracker.create_budget([]))

      assert :ok =
               BudgetEnforcer.on_run_complete(run_id, %{
                 "usage" => %{"total_tokens" => 5, "cost" => %{"total" => 0.25}}
               })

      assert BudgetTracker.get_usage(run_id) == %{tokens: 5, cost: 0.25}
    end
  end

  describe "check_subagent_spawn/2" do
    test "returns :ok when under child limit" do
      parent_id = "parent_#{System.unique_integer([:positive])}"
      RunGraph.new_run(%{id: parent_id, type: :test})
      BudgetTracker.store_budget(parent_id, BudgetTracker.create_budget(max_children: 3))

      assert :ok = BudgetEnforcer.check_subagent_spawn(parent_id, [])
    end
  end

  # ============================================================================
  # handle_budget_exceeded/3 Tests
  # ============================================================================

  describe "handle_budget_exceeded/3" do
    test "returns error tuple by default" do
      run_id = "run_#{System.unique_integer([:positive])}"
      details = %{type: :token_limit_exceeded, used: 100, limit: 50}

      assert {:error, message} = BudgetEnforcer.handle_budget_exceeded(run_id, details, [])
      assert is_binary(message)
    end

    test "returns cancel tuple when action is :cancel" do
      run_id = "run_#{System.unique_integer([:positive])}"
      details = %{type: :token_limit_exceeded, used: 100, limit: 50}

      assert {:cancel, message} =
               BudgetEnforcer.handle_budget_exceeded(run_id, details, action: :cancel)

      assert is_binary(message)
    end

    test "returns compact tuple when action is :compact" do
      run_id = "run_#{System.unique_integer([:positive])}"
      details = %{type: :token_limit_exceeded, used: 100, limit: 50}

      assert {:compact, message} =
               BudgetEnforcer.handle_budget_exceeded(run_id, details, action: :compact)

      assert is_binary(message)
    end
  end

  # ============================================================================
  # Error Message Formatting Tests
  # ============================================================================

  describe "error message formatting" do
    test "formats token limit exceeded message" do
      run_id = "run_#{System.unique_integer([:positive])}"
      details = %{type: :token_limit_exceeded, used: 1000, limit: 500}

      assert {:error, message} = BudgetEnforcer.handle_budget_exceeded(run_id, details, [])
      assert message =~ "Token budget exceeded"
    end

    test "formats cost limit exceeded message" do
      run_id = "run_#{System.unique_integer([:positive])}"
      details = %{type: :cost_limit_exceeded, used: 10.0, limit: 5.0}

      assert {:error, message} = BudgetEnforcer.handle_budget_exceeded(run_id, details, [])
      assert message =~ "Cost budget exceeded"
    end

    test "formats max children exceeded message" do
      run_id = "run_#{System.unique_integer([:positive])}"
      details = %{type: :max_children_exceeded, active: 5, limit: 3}

      assert {:error, message} = BudgetEnforcer.handle_budget_exceeded(run_id, details, [])
      assert message =~ "Maximum concurrent subagents reached"
    end
  end
end
