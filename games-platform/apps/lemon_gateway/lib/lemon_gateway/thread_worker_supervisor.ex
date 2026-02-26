defmodule LemonGateway.ThreadWorkerSupervisor do
  @moduledoc """
  DynamicSupervisor that manages `LemonGateway.ThreadWorker` processes.

  Provides dynamic child management for thread workers using a one-for-one strategy.
  """
  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
