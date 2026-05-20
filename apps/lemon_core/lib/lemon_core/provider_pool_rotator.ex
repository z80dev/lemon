defmodule LemonCore.ProviderPoolRotator do
  @moduledoc false

  use GenServer

  @name __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  def ordered_providers(key, providers, strategy) when is_list(providers) do
    providers = providers |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if strategy == "round_robin" and length(providers) > 1 do
      GenServer.call(@name, {:ordered_providers, key, providers})
    else
      providers
    end
  catch
    :exit, _ -> providers
  end

  def ordered_providers(_key, _providers, _strategy), do: []

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:ordered_providers, key, providers}, _from, state) do
    offset = Map.get(state, key, 0)
    rotated = rotate(providers, rem(offset, length(providers)))
    {:reply, rotated, Map.put(state, key, rem(offset + 1, length(providers)))}
  end

  defp rotate(providers, 0), do: providers

  defp rotate(providers, offset) do
    {head, tail} = Enum.split(providers, offset)
    tail ++ head
  end
end
