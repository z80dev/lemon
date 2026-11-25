defmodule LemonAgent.NodeRegistry.Generations do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def generation_floor(id) do
    case :ets.lookup(__MODULE__, id) do
      [{^id, floor}] -> floor
      [] -> 0
    end
  end

  def known?(id), do: :ets.member(__MODULE__, id)
  def advance(id, generation), do: GenServer.call(__MODULE__, {:advance, id, generation})

  @impl true
  def init(_) do
    _ = :ets.new(__MODULE__, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:advance, id, generation}, _from, state) do
    floor = max(generation_floor(id), generation)
    :ets.insert(__MODULE__, {id, floor})
    {:reply, floor, state}
  end
end
