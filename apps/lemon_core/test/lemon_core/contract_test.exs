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

  test "accepts a loadable module with all required callbacks" do
    assert Contract.validate(GreeterImplementation, Greeter) == :ok
    assert Contract.required_callbacks(Greeter) == [hello: 0]
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
