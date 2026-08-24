defmodule LemonGateway.ExecutorTest do
  use ExUnit.Case, async: false

  alias LemonGateway.ExecutionRequest
  alias LemonGateway.Executor

  defmodule ExecutorContractValidExecutor do
    @behaviour LemonGateway.Executor

    @impl true
    def start_run(%LemonGateway.ExecutionRequest{} = request, _opts, sink_pid) do
      run_ref = make_ref()
      send(sink_pid, {:engine_event, run_ref, %{type: :started, request: request}})
      send(sink_pid, {:engine_delta, run_ref, "streamed output"})
      {:ok, run_ref, {:executor_test, self()}}
    end

    @impl true
    def cancel({:executor_test, pid}) do
      send(pid, :cancelled)
      :ok
    end

    @impl true
    def steer(_ctx, _text), do: {:error, :unsupported}

    @impl true
    def redirect(_ctx, _text), do: {:error, :unsupported}
  end

  defmodule MissingCallbacksExecutor do
    def start_run(_request, _opts, _sink_pid), do: {:ok, make_ref(), :context}
    def cancel(_ctx), do: :ok
  end

  setup do
    executor_config = Application.fetch_env(:lemon_gateway, :executor)

    on_exit(fn ->
      case executor_config do
        {:ok, executor} -> Application.put_env(:lemon_gateway, :executor, executor)
        :error -> Application.delete_env(:lemon_gateway, :executor)
      end
    end)

    :ok
  end

  describe "configured executor validation" do
    test "accepts a configured module implementing the complete contract" do
      Application.put_env(:lemon_gateway, :executor, ExecutorContractValidExecutor)

      assert {:ok, ExecutorContractValidExecutor} = Executor.configured_module()
      assert :ok = Executor.validate_configured()
    end

    test "reports a missing executor configuration" do
      Application.delete_env(:lemon_gateway, :executor)

      assert {:error, :executor_not_configured} = Executor.configured_module()
      assert {:error, :executor_not_configured} = Executor.validate_configured()
    end

    test "reports an unloadable configured module" do
      module = LemonGateway.ExecutorTest.UnloadableExecutor
      Application.put_env(:lemon_gateway, :executor, module)

      assert {:error, {:executor_not_loadable, ^module}} = Executor.validate_configured()
    end

    test "reports every missing required callback" do
      assert {:error,
              {:executor_missing_callbacks, MissingCallbacksExecutor, [steer: 2, redirect: 2]}} =
               Executor.validate(MissingCallbacksExecutor)
    end
  end

  describe "executor control contract" do
    test "start_run consumes an ExecutionRequest and preserves sink messages" do
      request = %ExecutionRequest{
        run_id: "run-1",
        session_key: "session-1",
        prompt: "hello",
        conversation_key: {:session, "session-1"}
      }

      assert {:ok, run_ref, context} =
               ExecutorContractValidExecutor.start_run(request, [], self())

      assert_receive {:engine_event, ^run_ref, %{type: :started, request: ^request}}
      assert_receive {:engine_delta, ^run_ref, "streamed output"}
      assert :ok = ExecutorContractValidExecutor.cancel(context)
      assert_receive :cancelled
    end

    test "unsupported controls return the explicit unsupported error" do
      context = {:executor_test, self()}

      assert {:error, :unsupported} =
               ExecutorContractValidExecutor.steer(context, "change course")

      assert {:error, :unsupported} =
               ExecutorContractValidExecutor.redirect(context, "redirect output")
    end
  end
end
