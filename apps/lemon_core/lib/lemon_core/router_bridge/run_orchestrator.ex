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

  An `{:error, reason}` other than `{:error, :outcome_unknown}` is a definite
  rejection: implementations must return it only when they can guarantee the
  request did not take effect. If acceptance may have happened but cannot be
  acknowledged, return `{:error, :outcome_unknown}` instead.
  """
  @callback submit(RunRequest.t()) :: {:ok, run_id :: binary()} | {:error, term()}

  @doc "Submit once and acknowledge the owning queue's actual disposition."
  @callback submit_with_receipt(RunRequest.t()) :: {:ok, map()} | {:error, term()}

  @doc "Read a fixed-ID receipt without dispatch."
  @callback run_receipt(binary()) :: {:ok, map()} | {:error, term()}

  @doc "Admit a fresh fixed-ID native execution from private owner provenance."
  @callback submit_native_followup(map(), RunRequest.t()) :: {:ok, binary()} | {:error, term()}

  @doc "Seal actual executing-host native startup policy from private owner provenance."
  @callback register_native_source_floor(map(), map()) :: :ok | {:error, term()}

  @optional_callbacks submit_with_receipt: 1, run_receipt: 1, submit_native_followup: 2,
                      register_native_source_floor: 2

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
