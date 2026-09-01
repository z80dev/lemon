defmodule LemonCore.RouterBridge.RunOrchestrator do
  @moduledoc """
  The submission half of `LemonCore.RouterBridge`: what a run orchestrator
  must implement to be registered under the `:run_orchestrator` key.

  `use LemonCore.RouterBridge.RunOrchestrator` injects an overridable
  `submit/1` that raises `LemonCore.RouterBridge.NotImplementedError`; see
  `LemonCore.RouterBridge.Router` for why.
  """

  alias LemonCore.RunRequest

  @doc """
  Accept a run request. `{:ok, run_id}` means the run was accepted, not that
  it finished; progress arrives as `LemonCore.Bus` events under that id.
  """
  @callback submit(RunRequest.t()) :: {:ok, run_id :: binary()} | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour LemonCore.RouterBridge.RunOrchestrator

      def submit(_request) do
        raise LemonCore.RouterBridge.NotImplementedError,
          module: __MODULE__,
          function: :submit,
          arity: 1
      end

      defoverridable LemonCore.RouterBridge.RunOrchestrator
    end
  end
end
