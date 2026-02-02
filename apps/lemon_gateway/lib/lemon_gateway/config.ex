defmodule LemonGateway.Config do
  @moduledoc false
  use GenServer

  @default %{
    max_concurrent_runs: 2,
    default_engine: "lemon"
  }

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec get() :: map()
  def get, do: GenServer.call(__MODULE__, :get)

  @spec get(atom()) :: term()
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @impl true
  def init(_opts) do
    cfg = Application.get_env(:lemon_gateway, __MODULE__, %{})
    {:ok, Map.merge(@default, cfg)}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  def handle_call({:get, key}, _from, state), do: {:reply, Map.get(state, key), state}
end
