defmodule LemonAgent.ModelRuntime.ProviderPoolRotator do
  @moduledoc """
  Round-robin ordering state for provider credential pools.

  Keeps a per-key rotation offset so successive resolutions spread load across
  a pool's providers. Callers with a stable session identity pass it as
  `:session_scope`: the first resolution for a `{key, session_scope}` pair
  claims the next rotation slot and every later resolution for that pair reuses
  the same slot, so a session keeps hitting the same provider (provider prompt
  caches are keyed per provider, and per-request rotation destroys hit rates).
  The default `:global` scope advances the rotation on every call.

  If the rotator process is unavailable, ordering degrades to the verbatim
  provider list.

  Session assignments have no explicit release (sessions do not report their
  end to the rotator), so entries idle for more than 7 days are pruned by an
  hourly sweep — otherwise a long-running daemon churning through short-lived
  sessions grows the assignments map without bound. An active session's entry
  refreshes its last-used timestamp on every resolution.
  """

  use GenServer

  @name __MODULE__
  @sweep_interval_ms 60 * 60 * 1000
  @assignment_ttl_ms 7 * 24 * 60 * 60 * 1000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  @spec ordered_providers(term(), [String.t()], String.t() | nil, keyword()) :: [String.t()]
  def ordered_providers(key, providers, strategy, opts \\ [])

  def ordered_providers(key, providers, strategy, opts) when is_list(providers) do
    providers = providers |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if strategy == "round_robin" and length(providers) > 1 do
      session_scope = Keyword.get(opts, :session_scope, :global)
      GenServer.call(@name, {:ordered_providers, key, session_scope, providers})
    else
      providers
    end
  catch
    :exit, _ -> providers
  end

  def ordered_providers(_key, _providers, _strategy, _opts), do: []

  @impl true
  def init(_) do
    schedule_sweep()
    {:ok, %{offsets: %{}, assignments: %{}}}
  end

  @impl true
  def handle_call({:ordered_providers, key, :global, providers}, _from, state) do
    {offset, state} = next_offset(state, key, length(providers))
    {:reply, rotate(providers, offset), state}
  end

  def handle_call({:ordered_providers, key, session_scope, providers}, _from, state) do
    now = System.system_time(:millisecond)

    case Map.fetch(state.assignments, {key, session_scope}) do
      {:ok, {offset, _last_used_ms}} ->
        state = put_assignment(state, {key, session_scope}, offset, now)
        {:reply, rotate(providers, rem(offset, length(providers))), state}

      :error ->
        {offset, state} = next_offset(state, key, length(providers))
        state = put_assignment(state, {key, session_scope}, offset, now)
        {:reply, rotate(providers, offset), state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.system_time(:millisecond) - @assignment_ttl_ms

    assignments =
      state.assignments
      |> Enum.reject(fn {_key, {_offset, last_used_ms}} -> last_used_ms < cutoff end)
      |> Map.new()

    schedule_sweep()
    {:noreply, %{state | assignments: assignments}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp put_assignment(state, key, offset, now) do
    %{state | assignments: Map.put(state.assignments, key, {offset, now})}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp next_offset(state, key, count) do
    offset = state.offsets |> Map.get(key, 0) |> rem(count)
    {offset, %{state | offsets: Map.put(state.offsets, key, rem(offset + 1, count))}}
  end

  defp rotate(providers, 0), do: providers

  defp rotate(providers, offset) do
    {head, tail} = Enum.split(providers, offset)
    tail ++ head
  end
end
