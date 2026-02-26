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
    spec =
      Supervisor.child_spec({LemonGateway.Run, args},
        restart: :temporary
      )

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
