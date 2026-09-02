defmodule LemonRouter.EngineRuntimeConfigurationTest do
  use ExUnit.Case, async: false

  alias LemonRouter.EngineRuntimeConfiguration

  import ExUnit.CaptureLog

  defmodule Runtime do
    @behaviour LemonCore.EngineRuntime

    @impl true
    def submit_execution(_command), do: :ok

    @impl true
    def cancel_by_run_id(_run_id, _reason), do: :ok

    @impl true
    def run_pid(_run_id), do: nil

    @impl true
    def available?, do: true
  end

  defmodule IncompleteRuntime do
    def available?, do: true
  end

  setup do
    original_runtime = Application.get_env(:lemon_router, :engine_runtime)

    on_exit(fn ->
      if original_runtime do
        Application.put_env(:lemon_router, :engine_runtime, original_runtime)
      else
        Application.delete_env(:lemon_router, :engine_runtime)
      end
    end)
  end

  test "accepts an absent runtime for router-only startup" do
    assert EngineRuntimeConfiguration.validate(nil) == :ok
  end

  test "accepts a runtime implementing the complete configured contract" do
    assert EngineRuntimeConfiguration.validate(Runtime) == :ok
  end

  test "rejects an invalid configured runtime with structured details" do
    assert {:error, {:missing_callbacks, IncompleteRuntime, missing_callbacks}} =
             EngineRuntimeConfiguration.validate(IncompleteRuntime)

    assert Enum.sort(missing_callbacks) == [
             cancel_by_run_id: 2,
             run_pid: 1,
             submit_execution: 1
           ]

    assert EngineRuntimeConfiguration.validate("runtime") ==
             {:error, {:not_a_module, "runtime"}}
  end

  test "the startup boundary reports invalid configured wiring once" do
    Application.put_env(:lemon_router, :engine_runtime, IncompleteRuntime)

    log =
      capture_log(fn ->
        assert {:error, {:missing_callbacks, IncompleteRuntime, _missing_callbacks}} =
                 EngineRuntimeConfiguration.validate_configured()
      end)

    assert log =~ "configured :engine_runtime #{inspect(IncompleteRuntime)}"
    assert log =~ "does not implement LemonCore.EngineRuntime"
    assert log =~ "runtime operations will remain unavailable"
  end
end
