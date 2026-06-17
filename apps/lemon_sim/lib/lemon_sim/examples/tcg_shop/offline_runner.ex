defmodule LemonSim.Examples.TcgShop.OfflineRunner do
  @moduledoc false

  alias LemonSim.Examples.TcgShop
  alias LemonSim.Examples.TcgShop.{Artifacts, Events, Updater}
  alias LemonSim.Kernel.{Event, Runner, State}

  @spec run_strategy(String.t() | atom(), keyword()) ::
          {:ok, %{state: State.t(), artifacts: map(), steps: non_neg_integer()}}
          | {:error, term()}
  def run_strategy(strategy, opts \\ [])

  def run_strategy(strategy, opts) when strategy in ["baseline", :baseline] do
    run_deterministic_strategy("baseline", opts, &baseline_events_for_day/1)
  end

  def run_strategy(strategy, opts) when strategy in ["pressure", :pressure] do
    run_deterministic_strategy("pressure", opts, &pressure_events_for_day/1)
  end

  def run_strategy(strategy, _opts), do: {:error, {:unknown_tcg_shop_offline_strategy, strategy}}

  @spec events_for_day(map()) :: [Event.t()]
  def events_for_day(world), do: baseline_events_for_day(world)

  defp run_deterministic_strategy(strategy, opts, event_fun) do
    sim_id = Keyword.get(opts, :sim_id, "tcg_#{strategy}_#{:erlang.unique_integer([:positive])}")

    state =
      opts
      |> Keyword.put(:sim_id, sim_id)
      |> Keyword.put_new(:max_days, 14)
      |> Keyword.put_new(:seed, 1)
      |> TcgShop.initial_state()

    max_turns = Keyword.get(opts, :driver_max_turns, Keyword.get(opts, :max_turns, 80))

    with {:ok, final_state, events, actions, steps} <-
           run_deterministic_loop(state, max_turns, [], [], 0, event_fun),
         artifact_opts <-
           opts
           |> Keyword.put(:offline_strategy, strategy)
           |> Keyword.put(
             :artifact_report_title,
             "TCG Shop Offline #{String.capitalize(strategy)} Report"
           ),
         {:ok, artifacts} <-
           Artifacts.write_run_artifacts(final_state, events, actions, artifact_opts) do
      {:ok, %{state: final_state, artifacts: artifacts, steps: steps}}
    end
  end

  defp run_deterministic_loop(state, max_turns, events, actions, turn, event_fun) do
    cond do
      terminal?(state) ->
        {:ok, state, events, actions, turn}

      turn >= max_turns ->
        {:error, {:tcg_shop_offline_turn_limit_exceeded, max_turns}}

      true ->
        planned_events = event_fun.(state.world)
        action = action_summary(state.world, planned_events)

        case ingest_collecting_events(state, planned_events, events) do
          {:ok, next_state, next_events} ->
            run_deterministic_loop(
              next_state,
              max_turns,
              next_events,
              actions ++ [action],
              turn + 1,
              event_fun
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp baseline_events_for_day(world) do
    day = get(world, :day_number, 1)

    support_events(world) ++
      baseline_restock_events(world) ++
      baseline_event_events(day) ++
      [Events.process_online_orders("standard"), Events.wait_next_day("balanced daily close")]
  end

  defp pressure_events_for_day(world) do
    day = get(world, :day_number, 1)

    support_events(world) ++
      pressure_market_events(day) ++
      pressure_buylist_events(day) ++
      pressure_restock_events(world) ++
      pressure_grading_events(world, day) ++
      pressure_event_events(day) ++
      [Events.process_online_orders(if(rem(day, 3) == 0, do: "premium", else: "standard"))] ++
      [Events.wait_next_day("pressure strategy daily close")]
  end

  defp support_events(world) do
    [
      Events.checked_dashboard(get(world, :day_number, 1), get(world, :bank_balance, 0.0)),
      Events.inspected_inventory(map_size(get(world, :inventory, %{}))),
      Events.reviewed_customers(length(get(world, :customer_queue, [])))
    ]
  end

  defp baseline_restock_events(world) do
    [
      restock_if_below(world, "pokemon_booster_box", 6, 2),
      restock_if_below(world, "pokemon_elite_trainer_box", 8, 4),
      restock_if_below(world, "yugioh_core_box", 5, 2),
      restock_if_below(world, "one_piece_booster_box", 5, 2),
      restock_if_below(world, "card_sleeves", 18, 24),
      restock_if_below(world, "toploaders", 14, 18)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp pressure_restock_events(world) do
    [
      restock_if_below(world, "one_piece_booster_box", 8, 4),
      restock_if_below(world, "pokemon_booster_box", 8, 3),
      restock_if_below(world, "dragon_ball_fusion_box", 6, 3),
      restock_if_below(world, "card_sleeves", 24, 30),
      restock_if_below(world, "toploaders", 20, 24)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp restock_if_below(world, line_id, threshold, quantity) do
    on_hand =
      world
      |> get(:inventory, %{})
      |> get(line_id, %{})
      |> get(:on_hand, 0)

    pending =
      world
      |> get(:pending_deliveries, [])
      |> Enum.reduce(0, fn delivery, acc ->
        if get(delivery, :line_id) == line_id, do: acc + get(delivery, :quantity, 0), else: acc
      end)

    if on_hand + pending < threshold do
      Events.order_product_line(line_id, quantity)
    end
  end

  defp baseline_event_events(day) when day in [3, 7, 11] do
    [Events.host_event("Pokemon", 120.0, 12.0)]
  end

  defp baseline_event_events(_day), do: []

  defp pressure_market_events(day) when day in [1, 4, 8] do
    [Events.researched_market("allocation spikes and singles demand day #{day}", 4)]
  end

  defp pressure_market_events(_day), do: []

  defp pressure_buylist_events(day) when day in [2, 6, 10] do
    franchise = if day == 6, do: "One Piece", else: "Pokemon"
    [Events.buy_collection(franchise, 650.0, "mixed")]
  end

  defp pressure_buylist_events(_day), do: []

  defp pressure_grading_events(world, day) when day in [3, 9] do
    singles = get(world, :singles_case, %{})

    if get(singles, :cards_on_hand, 0) >= 12 do
      [Events.submit_grading(12, if(day == 3, do: "standard", else: "express"))]
    else
      []
    end
  end

  defp pressure_grading_events(_world, _day), do: []

  defp pressure_event_events(day) when day in [3, 5, 8, 12] do
    game =
      case day do
        5 -> "One Piece"
        8 -> "Yu-Gi-Oh!"
        12 -> "Dragon Ball Super"
        _ -> "Pokemon"
      end

    [Events.host_event(game, 220.0, 15.0)]
  end

  defp pressure_event_events(_day), do: []

  defp action_summary(world, events) do
    %{
      day: get(world, :day_number, 1),
      support_calls: Enum.count(events, &support_event?/1),
      orders: Enum.count(events, &(event_kind(&1) == "tcg_order_product_line")),
      collections: Enum.count(events, &(event_kind(&1) == "tcg_buy_collection")),
      events_hosted: Enum.count(events, &(event_kind(&1) == "tcg_host_event")),
      grading_submissions: Enum.count(events, &(event_kind(&1) == "tcg_submit_grading")),
      online_order_batches: Enum.count(events, &(event_kind(&1) == "tcg_process_online_orders")),
      closes: Enum.count(events, &(event_kind(&1) == "tcg_wait_next_day"))
    }
  end

  defp support_event?(event) do
    event_kind(event) in [
      "tcg_checked_dashboard",
      "tcg_inspected_inventory",
      "tcg_researched_market",
      "tcg_reviewed_customers"
    ]
  end

  defp ingest_collecting_events(state, events, collected_events) do
    Enum.reduce_while(events, {:ok, state, collected_events}, fn event,
                                                                 {:ok, current_state, acc_events} ->
      before_recent = current_state.recent_events

      case Runner.ingest_events(current_state, [event], Updater) do
        {:ok, next_state, _signal} ->
          appended = appended_recent_events(before_recent, next_state.recent_events)
          {:cont, {:ok, next_state, acc_events ++ appended}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp appended_recent_events(before_recent, after_recent) do
    max_overlap = min(length(before_recent), length(after_recent))

    overlap =
      max_overlap..0//-1
      |> Enum.find(0, fn count ->
        Enum.take(before_recent, -count) == Enum.take(after_recent, count)
      end)

    Enum.drop(after_recent, overlap)
  end

  defp terminal?(state) do
    get(state.world, :status) in ["complete", "bankrupt"]
  end

  defp event_kind(%{kind: kind}), do: kind
  defp event_kind(%{"kind" => kind}), do: kind
  defp event_kind(_event), do: nil

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp get(_map, _key, default), do: default
end
