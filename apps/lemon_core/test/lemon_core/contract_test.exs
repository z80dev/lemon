defmodule LemonCore.ContractTest do
  use ExUnit.Case, async: true

  alias LemonCore.Contract

  defmodule Greeter do
    @callback hello() :: String.t()
    @callback goodbye() :: String.t()
    @optional_callbacks goodbye: 0
  end

  defmodule GreeterImplementation do
    @behaviour Greeter

    @impl true
    def hello, do: "hello"
  end

  defmodule IncompleteImplementation do
    def unrelated, do: :ok
  end

  defmodule RaisingBehaviourInfo do
    def behaviour_info(_kind), do: raise("broken behaviour metadata")
  end

  defmodule ExitingBehaviourInfo do
    def behaviour_info(_kind), do: exit(:broken_behaviour_metadata)
  end

  test "accepts a loadable module with all required callbacks" do
    assert Contract.validate(GreeterImplementation, Greeter) == :ok
  end

  test "does not require optional callbacks" do
    refute function_exported?(GreeterImplementation, :goodbye, 0)
    assert Contract.validate(GreeterImplementation, Greeter) == :ok
  end

  test "reports every missing required callback" do
    assert Contract.validate(IncompleteImplementation, Greeter) ==
             {:error, {:missing_callbacks, IncompleteImplementation, [hello: 0]}}
  end

  test "rejects unloadable and non-module implementation values" do
    assert Contract.validate(No.Such.Module, Greeter) ==
             {:error, {:not_loadable, No.Such.Module}}

    assert Contract.validate("runtime", Greeter) == {:error, {:not_a_module, "runtime"}}
    assert Contract.validate(nil, Greeter) == {:error, {:not_a_module, nil}}
  end

  test "rejects invalid behaviour inputs without raising" do
    assert Contract.validate(GreeterImplementation, nil) ==
             {:error, {:not_a_behaviour, nil}}

    assert Contract.validate(GreeterImplementation, "greeter") ==
             {:error, {:not_a_behaviour, "greeter"}}

    assert Contract.validate(GreeterImplementation, No.Such.Behaviour) ==
             {:error, {:not_a_behaviour, No.Such.Behaviour}}

    assert Contract.validate(GreeterImplementation, String) ==
             {:error, {:not_a_behaviour, String}}

    assert Contract.validate(GreeterImplementation, RaisingBehaviourInfo) ==
             {:error, {:not_a_behaviour, RaisingBehaviourInfo}}

    assert Contract.validate(GreeterImplementation, ExitingBehaviourInfo) ==
             {:error, {:not_a_behaviour, ExitingBehaviourInfo}}
  end

  test "EngineRuntime.validate/1 reports its complete required surface" do
    assert {:error, {:missing_callbacks, IncompleteImplementation, missing_callbacks}} =
             LemonCore.EngineRuntime.validate(IncompleteImplementation)

    assert Enum.sort(missing_callbacks) == [
             available?: 0,
             cancel_by_run_id: 2,
             run_pid: 1,
             submit_execution: 1
           ]
  end
end
