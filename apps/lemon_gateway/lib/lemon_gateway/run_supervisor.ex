defmodule LemonGateway.RunSupervisor do
  @moduledoc """
  DynamicSupervisor that manages `LemonGateway.Run` processes.

  Internal gateway callers provide `%{execution_request: %ExecutionRequest{}}`
  after the public runtime boundary converts a core execution command. Each run
  is started as a temporary child so it is not restarted on failure.
  """
  use DynamicSupervisor

  alias LemonGateway.ExecutionRequest

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
  @spec start_run(map()) ::
          DynamicSupervisor.on_start_child() | {:error, :invalid_execution_request}
  def start_run(%{execution_request: %ExecutionRequest{}} = args) do
    spec = Supervisor.child_spec({LemonGateway.Run, args}, restart: :temporary)
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def start_run(_args), do: {:error, :invalid_execution_request}
end
