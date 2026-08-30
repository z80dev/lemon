defmodule LemonBrowser.HybridRouter do
  @moduledoc "Exact-session route memory for Lemon's local/public hybrid browser backend."

  use GenServer

  @name __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  def put(scope, backend), do: GenServer.call(@name, {:put, scope, backend})
  def fetch(scope), do: GenServer.call(@name, {:fetch, scope})
  def delete(scope), do: GenServer.call(@name, {:delete, scope})
  def status, do: GenServer.call(@name, :status)

  @impl true
  def init(_opts), do: {:ok, %{routes: %{}}}

  @impl true
  def handle_call({:put, scope, backend}, _from, state) do
    {:reply, :ok, put_in(state, [:routes, scope], backend)}
  end

  def handle_call({:fetch, scope}, _from, state),
    do: {:reply, Map.fetch(state.routes, scope), state}

  def handle_call({:delete, scope}, _from, state),
    do: {:reply, :ok, %{state | routes: Map.delete(state.routes, scope)}}

  def handle_call(:status, _from, state) do
    counts = Enum.frequencies(Map.values(state.routes))
    {:reply, %{session_count: map_size(state.routes), routes: counts}, state}
  end
end
