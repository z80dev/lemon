defmodule LemonControlPlane.A2A.RateLimiter do
  @moduledoc false
  use GenServer

  alias LemonControlPlane.A2A.Config

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))

  @spec allow?(binary()) :: boolean()
  def allow?(peer_id), do: GenServer.call(__MODULE__, {:allow, peer_id})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:allow, peer_id}, _from, state) do
    now = System.monotonic_time(:millisecond)
    window = now - 60_000
    recent = state |> Map.get(peer_id, []) |> Enum.filter(&(&1 >= window))
    limit = Config.current().rate_limit_per_minute

    if length(recent) < limit do
      {:reply, true, Map.put(state, peer_id, [now | recent])}
    else
      {:reply, false, Map.put(state, peer_id, recent)}
    end
  end
end
