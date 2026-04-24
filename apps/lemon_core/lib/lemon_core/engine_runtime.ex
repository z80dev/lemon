defmodule LemonCore.EngineRuntime do
  @moduledoc """
  Behaviour for execution runtimes used by router run processes.

  Implementations accept core execution commands and hide runtime-private
  scheduler, registry, and cancellation details from `lemon_router`.
  """

  alias LemonCore.ExecutionCommand

  @callback submit_execution(ExecutionCommand.t()) :: :ok | {:error, term()}
  @callback cancel_by_run_id(binary(), term()) :: :ok
  @callback run_pid(binary()) :: pid() | nil
  @callback available?() :: boolean()
end
