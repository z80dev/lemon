defmodule AgentCore.Loop.StateMachineTest do
  use ExUnit.Case, async: true

  alias AgentCore.Loop.StateMachine

  test "accepts the core model and tool lifecycle path" do
    assert {:ok, :initializing} = StateMachine.transition(nil, :initializing)
    assert {:ok, :await_model} = StateMachine.transition(:initializing, :await_model)

    assert {:ok, :normalizing_response} =
             StateMachine.transition(:await_model, :normalizing_response)

    assert {:ok, :executing_tools} =
             StateMachine.transition(:normalizing_response, :executing_tools)

    assert {:ok, :awaiting_tool_results} =
             StateMachine.transition(:executing_tools, :awaiting_tool_results)

    assert {:ok, :await_model} =
             StateMachine.transition(:awaiting_tool_results, :await_model)
  end

  test "accepts provider-error recovery into finalization" do
    assert {:ok, :recovering_provider_error} =
             StateMachine.transition(:await_model, :recovering_provider_error)

    assert {:ok, :finalizing} =
             StateMachine.transition(:recovering_provider_error, :finalizing)
  end

  test "rejects invalid terminal transitions" do
    assert {:error, {:invalid_loop_state_transition, :finalizing, :await_model}} =
             StateMachine.transition(:finalizing, :await_model)

    assert_raise ArgumentError, ~r/invalid_loop_state_transition/, fn ->
      StateMachine.transition!(:aborted, :await_model)
    end
  end

  test "rejects unknown states" do
    assert {:error, {:unknown_loop_state, :await_model, :bogus}} =
             StateMachine.transition(:await_model, :bogus)
  end
end
