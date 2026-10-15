defmodule CodingAgent.ConflictStore do
  @moduledoc "Session-scoped conflict references, discarded when their session exits."
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  def register(scope, path, digest, regions, owner) do
    GenServer.call(__MODULE__, {:register, scope, path, digest, regions, owner})
  end

  def fetch(scope, id), do: GenServer.call(__MODULE__, {:fetch, scope, id})
  def invalidate(scope, path), do: GenServer.call(__MODULE__, {:invalidate, scope, path})

  @impl true
  def init(:ok), do: {:ok, %{sessions: %{}, monitors: %{}}}

  @impl true
  def handle_call({:register, scope, path, digest, regions, owner}, _from, state) do
    session = Map.get(state.sessions, scope, %{next: 1, blocks: %{}})
    existing = Enum.filter(session.blocks, fn {_id, block} -> block.path == path end)

    {entries, session} =
      if existing != [] and Enum.all?(existing, fn {_id, block} -> block.digest == digest end) do
        {Enum.sort_by(existing, &elem(&1, 0)), session}
      else
        blocks = Map.reject(session.blocks, fn {_id, block} -> block.path == path end)

        {entries, next} =
          Enum.map_reduce(regions, session.next, fn region, id ->
            {{id, %{path: path, digest: digest, region: region}}, id + 1}
          end)

        {entries, %{session | blocks: Map.merge(blocks, Map.new(entries)), next: next}}
      end

    state = put_in(state.sessions[scope], session)
    state = watch(state, scope, owner)
    {:reply, entries, state}
  end

  def handle_call({:fetch, scope, id}, _from, state) do
    block = get_in(state, [:sessions, scope, :blocks, id])

    {:reply,
     if(block, do: {:ok, block}, else: {:error, "Unknown conflict id; re-read path:conflicts"}),
     state}
  end

  def handle_call({:invalidate, scope, path}, _from, state) do
    state =
      if Map.has_key?(state.sessions, scope) do
        update_in(
          state.sessions[scope].blocks,
          &Map.reject(&1, fn {_id, block} -> block.path == path end)
        )
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {scope, monitors} ->
        {:noreply, %{state | monitors: monitors, sessions: Map.delete(state.sessions, scope)}}
    end
  end

  defp watch(state, scope, owner) when is_pid(owner) do
    if scope in Map.values(state.monitors) do
      state
    else
      %{state | monitors: Map.put(state.monitors, Process.monitor(owner), scope)}
    end
  end

  defp watch(state, _scope, _owner), do: state
end
