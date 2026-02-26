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
  # check_api_call/2 Tests
  # ============================================================================
  
  describe "check_api_call/2" do
    test "returns :ok when no budget exists" do
      run_id = "run_#{System.unique_integer([:positive])}"
      assert :ok = BudgetEnforcer.check_api_call(run_id, estimated_tokens: 1000)
    end
  end
  
  # ============================================================================
  # check_subagent_spawn/2 Tests
  # ============================================================================
  
  describe "check_subagent_spawn/2" do
    test "returns :ok when under child limit" do
      parent_id = "parent_#{System.unique_integer([:positive])}"
      RunGraph.new_run(%{id: parent_id, type: :test})
      BudgetTracker.store_budget(parent_id, BudgetTracker.create_budget(max_children: 3))
      
      assert :ok = BudgetEnforcer.check_subagent_spawn(parent_id, [])
    end
  end
  
  # ============================================================================
  # on_api_response/2 Tests
  # ============================================================================
  
  describe "on_api_response/2" do
    test "returns :ok after recording response" do
      run_id = "run_#{System.unique_integer([:positive])}"
      RunGraph.new_run(%{id: run_id, type: :test})
      BudgetTracker.store_budget(run_id, BudgetTracker.create_budget([]))
      
      response = %{usage: %{total_tokens: 50, cost: 0.25}}
      
      assert :ok = BudgetEnforcer.on_api_response(run_id, response)
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
      
      assert {:cancel, message} = BudgetEnforcer.handle_budget_exceeded(run_id, details, action: :cancel)
      assert is_binary(message)
    end
    
    test "returns compact tuple when action is :compact" do
      run_id = "run_#{System.unique_integer([:positive])}"
      details = %{type: :token_limit_exceeded, used: 100, limit: 50}
      
      assert {:compact, message} = BudgetEnforcer.handle_budget_exceeded(run_id, details, action: :compact)
      assert is_binary(message)
    end
  end
  
  # ============================================================================
  # budget_summary/1 Tests
  # ============================================================================
  
  describe "budget_summary/1" do
    test "returns no_budget when budget doesn't exist" do
      run_id = "run_#{System.unique_integer([:positive])}"
      
      summary = BudgetEnforcer.budget_summary(run_id)
      
      assert summary.status == :no_budget
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
