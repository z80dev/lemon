defmodule LemonSim.Examples.VendingBench.Runtime do
  @moduledoc false

  def appended_recent_events(before_recent, after_recent) do
    max_overlap = min(length(before_recent), length(after_recent))

    overlap =
      max_overlap..0//-1
      |> Enum.find(0, fn count ->
        Enum.take(before_recent, -count) == Enum.take(after_recent, count)
      end)

    Enum.drop(after_recent, overlap)
  end

  def get(map, key, default \\ nil)

  def get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  def get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  def get(_map, _key, default), do: default
end
