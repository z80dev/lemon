defmodule LemonSim.Examples.TcgShop.Updaters.Support do
  @moduledoc false

  alias LemonCore.MapHelpers
  alias LemonSim.Examples.TcgShop.{Catalog, Events}
  alias LemonSim.Kernel.State

  def reject(%State{} = state, event, reason) do
    rejection = Events.action_rejected("operator", reason, event.kind)

    next =
      state
      |> State.update_world(fn world ->
        world
        |> Map.update(:invalid_action_count, 1, &(&1 + 1))
        |> Map.update(:reputation, -1, &max(0, &1 - 1))
      end)
      |> State.append_event(rejection)

    {:ok, next, {:decide, "action rejected: #{inspect(reason)}"}}
  end

  def ensure_in_progress(world) do
    if get(world, :status, "in_progress") == "in_progress",
      do: :ok,
      else: {:error, :not_in_progress}
  end

  def ensure_line(nil), do: {:error, :unknown_product_line}
  def ensure_line(line), do: {:ok, line}

  def ensure_optional_line(nil), do: :ok

  def ensure_optional_line(line_id),
    do: if(Catalog.line(line_id), do: :ok, else: {:error, :unknown_product_line})

  def ensure_positive(value),
    do: if(value > 0, do: :ok, else: {:error, :quantity_must_be_positive})

  def ensure_minimum(value, minimum),
    do: if(value >= minimum, do: :ok, else: {:error, {:below_minimum, minimum}})

  def ensure_cash(world, cost) do
    if get(world, :bank_balance, 0.0) >= cost, do: :ok, else: {:error, :insufficient_cash}
  end

  def ensure_franchise(franchise) do
    if franchise in (Catalog.franchises() -- ["Accessories"]),
      do: :ok,
      else: {:error, :unknown_franchise}
  end

  def maybe_append(world, _key, nil), do: world
  def maybe_append(world, key, value), do: Map.update(world, key, [value], &(&1 ++ [value]))

  def sealed_cogs(line, quantity) do
    Float.round(get(line, :unit_cost, 0.0) * quantity, 2)
  end

  def clamp_int(value, min, max), do: Kernel.min(Kernel.max(value, min), max)

  def clamp_float(value, min, max), do: Kernel.min(Kernel.max(value, min), max)

  def get(map, key, default \\ nil)
  def get(map, key, default) when is_map(map), do: MapHelpers.get_key(map, key) || default
  def get(_map, _key, default), do: default

  def as_int(value) when is_integer(value), do: value
  def as_int(value) when is_float(value), do: trunc(value)
  def as_int(value) when is_binary(value), do: String.to_integer(value)
  def as_int(_), do: 0

  def as_float(value) when is_float(value), do: value
  def as_float(value) when is_integer(value), do: value + 0.0
  def as_float(value) when is_binary(value), do: String.to_float(value)
  def as_float(_), do: 0.0
end
