defmodule LemonSim.Examples.VendingBench.Support do
  @moduledoc false

  alias LemonSim.Kernel.State

  def apply_skip(state, event) do
    state = State.append_event(state, event)
    {:ok, state, :skip}
  end

  def apply_action_rejected(state, event) do
    state =
      state
      |> State.append_event(event)
      |> State.update_world(fn world ->
        failures = get(world, :coordination_failures, 0)
        Map.put(world, :coordination_failures, failures + 1)
      end)

    {:ok, state, :skip}
  end

  def format_price(price) when is_float(price),
    do: :erlang.float_to_binary(price, decimals: 2)

  def format_price(price) when is_integer(price),
    do: :erlang.float_to_binary(price / 1, decimals: 2)

  def format_price(price), do: to_string(price)

  def format_time(minutes) when is_integer(minutes) do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)
    "#{hours}:#{String.pad_leading(to_string(mins), 2, "0")}"
  end

  def get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  def get(_map, _key), do: nil

  def get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  def get(_map, _key, default), do: default
end
