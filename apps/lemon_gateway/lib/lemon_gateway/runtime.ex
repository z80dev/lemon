defmodule LemonGateway.Runtime do
  @moduledoc """
  Runtime API for submitting and cancelling gateway runs.

  Provides the queue-free execution entry point used by the router plus
  cancellation helpers for active runs by progress message ID or run ID.
  """

  @behaviour LemonCore.EngineRuntime

  alias LemonCore.ExecutionCommand
  alias LemonGateway.ExecutionRequest

  @doc "Submits a core execution command to the scheduler."
  @impl true
  @spec submit_execution(ExecutionCommand.t()) :: :ok
  def submit_execution(%ExecutionCommand{} = command) do
    command
    |> ExecutionCommand.ensure_conversation_key()
    |> ExecutionRequest.from_command()
    |> LemonGateway.Scheduler.submit_execution()
  end

  @doc "Cancels a run identified by its progress message ID within a scope."
  @spec cancel_by_progress_msg(term(), integer()) :: :ok
  def cancel_by_progress_msg(scope, progress_msg_id) do
    case LemonCore.ProgressStore.get_run(scope, progress_msg_id) do
      nil -> :ok
      run_id when is_binary(run_id) -> cancel_by_run_id(run_id, :user_requested)
      _other -> :ok
    end
  end

  @doc "Cancels a run identified by its run ID. No-op if the run is not found."
  @impl true
  @spec cancel_by_run_id(binary(), term()) :: :ok
  def cancel_by_run_id(run_id, reason \\ :user_requested) when is_binary(run_id) do
    case run_pid(run_id) do
      run_pid when is_pid(run_pid) ->
        LemonGateway.Scheduler.cancel(run_pid, reason)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @impl true
  @spec run_pid(binary()) :: pid() | nil
  def run_pid(run_id) when is_binary(run_id) do
    case Registry.lookup(LemonGateway.RunRegistry, run_id) do
      [{pid, _meta}] when is_pid(pid) -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def run_pid(_), do: nil

  @impl true
  @spec available?() :: boolean()
  def available? do
    case GenServer.whereis(LemonGateway.Scheduler) do
      pid when is_pid(pid) -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
