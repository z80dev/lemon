defmodule LemonCore.ContractTest do
  use ExUnit.Case, async: true

  alias LemonCore.Contract

  defmodule Greeter do
    @callback hello() :: String.t()
    @callback bye() :: String.t()
    @optional_callbacks bye: 0
  end

  defmodule FullGreeter do
    @behaviour Greeter
    @impl true
    def hello, do: "hi"
  end

  defmodule PartialGreeter do
    def unrelated, do: :ok
  end

  defmodule DefaultRouter do
    use LemonCore.RouterBridge.Router

    @impl true
    def abort_run(_run_id, _reason), do: :ok
  end

  defmodule DefaultOrchestrator do
    use LemonCore.RouterBridge.RunOrchestrator
  end

  test "a module exporting every required callback validates" do
    assert Contract.validate(FullGreeter, Greeter) == :ok
    assert Contract.required_callbacks(Greeter) == [hello: 0]
  end

  test "missing required callbacks are listed" do
    assert Contract.validate(PartialGreeter, Greeter) ==
             {:error, {:missing_callbacks, PartialGreeter, [hello: 0]}}
  end

  test "an unloadable or non-module value is rejected with a reason" do
    assert Contract.validate(No.Such.Module, Greeter) ==
             {:error, {:not_loadable, No.Such.Module}}

    assert Contract.validate("router", Greeter) == {:error, {:not_a_module, "router"}}
    assert Contract.validate(nil, Greeter) == {:error, {:not_a_module, nil}}
  end

  test "use RouterBridge.Router satisfies the contract and fails visibly elsewhere" do
    assert Contract.validate(DefaultRouter, LemonCore.RouterBridge.Router) == :ok
    assert DefaultRouter.abort_run("run", :user_requested) == :ok

    assert_raise LemonCore.RouterBridge.NotImplementedError,
                 ~r/DefaultRouter does not implement keep_run_alive\/2/,
                 fn -> DefaultRouter.keep_run_alive("run", :continue) end
  end

  test "use RouterBridge.RunOrchestrator satisfies the contract" do
    assert Contract.validate(DefaultOrchestrator, LemonCore.RouterBridge.RunOrchestrator) ==
             :ok

    assert_raise LemonCore.RouterBridge.NotImplementedError, fn ->
      DefaultOrchestrator.submit(%LemonCore.RunRequest{})
    end
  end

  test "EngineRuntime.validate/1 requires all four callbacks" do
    assert {:error, {:missing_callbacks, PartialGreeter, missing}} =
             LemonCore.EngineRuntime.validate(PartialGreeter)

    assert Enum.sort(missing) == [
             available?: 0,
             cancel_by_run_id: 2,
             run_pid: 1,
             submit_execution: 1
           ]
  end
end
