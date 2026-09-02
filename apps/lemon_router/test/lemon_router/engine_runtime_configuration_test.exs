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
    original_runtime = Application.fetch_env(:lemon_router, :engine_runtime)

    on_exit(fn ->
      case original_runtime do
        {:ok, runtime} -> Application.put_env(:lemon_router, :engine_runtime, runtime)
        :error -> Application.delete_env(:lemon_router, :engine_runtime)
      end
    end)
  end

  test "accepts an absent runtime for router-only startup" do
    assert EngineRuntimeConfiguration.validate(nil) == :ok
  end

  test "accepts a runtime implementing the complete configured contract" do
    assert EngineRuntimeConfiguration.validate(Runtime) == :ok
  end

  test "the startup boundary preserves a valid configured runtime" do
    Application.put_env(:lemon_router, :engine_runtime, Runtime)

    assert EngineRuntimeConfiguration.validate_configured() == :ok
    assert Application.fetch_env(:lemon_router, :engine_runtime) == {:ok, Runtime}
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
    assert log =~ "disabling the invalid binding"
    assert Application.fetch_env(:lemon_router, :engine_runtime) == :error
  end

  test "the router application startup validates and removes an invalid runtime binding" do
    on_exit(fn ->
      {:ok, _started} = Application.ensure_all_started(:lemon_router)
    end)

    assert :ok = Application.stop(:lemon_router)
    Application.put_env(:lemon_router, :engine_runtime, IncompleteRuntime)

    log =
      capture_log(fn ->
        assert {:ok, started} = Application.ensure_all_started(:lemon_router)
        assert :lemon_router in started
      end)

    assert log =~ "configured :engine_runtime #{inspect(IncompleteRuntime)}"
    assert log =~ "disabling the invalid binding"
    assert Application.fetch_env(:lemon_router, :engine_runtime) == :error
  end
end
