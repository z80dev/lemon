defmodule LemonGateway.RunSupervisor do
  @moduledoc """
  DynamicSupervisor that manages `LemonGateway.Run` processes.

  Each run is started as a temporary child so it is not restarted on failure.
  """
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new `LemonGateway.Run` process as a temporary child of this supervisor.
  """
  def start_run(args) do
    args = normalize_run_args(args)

    spec =
      Supervisor.child_spec({LemonGateway.Run, args},
        restart: :temporary
      )

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  defp normalize_run_args(%{execution_request: %LemonGateway.ExecutionRequest{}} = args), do: args

  defp normalize_run_args(%{job: %LemonGateway.Types.Job{} = job} = args) do
    args
    |> Map.put(:execution_request, LemonGateway.ExecutionRequest.from_job(job))
    |> Map.delete(:job)
  end

  defp normalize_run_args(args), do: args
end
