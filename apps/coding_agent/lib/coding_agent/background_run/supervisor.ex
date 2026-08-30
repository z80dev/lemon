defmodule CodingAgent.BackgroundRun.Supervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_run(keyword()) :: DynamicSupervisor.on_start_child()
  def start_run(opts) do
    child_spec = %{
      id: {CodingAgent.BackgroundRun.Worker, Keyword.fetch!(opts, :id)},
      start: {CodingAgent.BackgroundRun.Worker, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end
