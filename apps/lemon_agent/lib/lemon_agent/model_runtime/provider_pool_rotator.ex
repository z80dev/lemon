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
  """

  use GenServer

  @name __MODULE__

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
  def init(_), do: {:ok, %{offsets: %{}, assignments: %{}}}

  @impl true
  def handle_call({:ordered_providers, key, :global, providers}, _from, state) do
    {offset, state} = next_offset(state, key, length(providers))
    {:reply, rotate(providers, offset), state}
  end

  def handle_call({:ordered_providers, key, session_scope, providers}, _from, state) do
    case Map.fetch(state.assignments, {key, session_scope}) do
      {:ok, offset} ->
        {:reply, rotate(providers, rem(offset, length(providers))), state}

      :error ->
        {offset, state} = next_offset(state, key, length(providers))
        state = %{state | assignments: Map.put(state.assignments, {key, session_scope}, offset)}
        {:reply, rotate(providers, offset), state}
    end
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
