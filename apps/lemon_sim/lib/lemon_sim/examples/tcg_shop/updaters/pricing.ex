defmodule LemonSim.Examples.TcgShop.Updaters.Pricing do
  @moduledoc false

  alias LemonSim.Kernel.State
  alias LemonSim.Examples.TcgShop.Updaters.Staffing

  import LemonSim.Examples.TcgShop.Updaters.Support

  def apply_set_prices(%State{} = state, event) do
    markup_pct = as_float(get(event.payload, "markup_pct", 0.0))
    line_id = get(event.payload, "line_id", nil)

    with :ok <- ensure_in_progress(state.world),
         :ok <- ensure_markup(markup_pct),
         :ok <- ensure_optional_line(line_id) do
      day = get(state.world, :day_number, 1)

      next =
        state
        |> State.update_world(fn world ->
          catalog = get(world, :catalog, %{})
          inventory = get(world, :inventory, %{})

          updated =
            Enum.into(inventory, %{}, fn {id, item} ->
              if line_id in [nil, id] do
                line = Map.get(catalog, id, %{})
                price = Float.round(get(line, :market_price, 0.0) * (1.0 + markup_pct / 100.0), 2)
                {id, Map.put(item, :price, price)}
              else
                {id, item}
              end
            end)

          entry = %{day: day, line_id: line_id || "all", markup_pct: markup_pct}

          world
          |> Map.put(:inventory, updated)
          |> Map.update(:price_history, [entry], &(&1 ++ [entry]))
          |> Staffing.consume_staff_hours(0.75, "price_update")
        end)
        |> State.append_event(event)

      {:ok, next, {:decide, "updated shelf prices"}}
    else
      {:error, reason} -> reject(state, event, reason)
    end
  end

  defp ensure_markup(markup),
    do: if(markup >= -20 and markup <= 80, do: :ok, else: {:error, :invalid_markup})
end
