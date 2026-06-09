defmodule LemonSim.Examples.VendingBench.OfflineRunner do
  @moduledoc false

  alias LemonSim.Examples.VendingBench
  alias LemonSim.Examples.VendingBench.{Artifacts, Events, Suppliers, Updater}
  alias LemonSim.Kernel.{Event, Runner, State}

  @spec run_strategy(String.t() | atom(), keyword()) ::
          {:ok, %{state: State.t(), artifacts: map(), steps: non_neg_integer()}}
          | {:error, term()}
  def run_strategy(strategy, opts \\ [])

  def run_strategy(strategy, opts) when strategy in ["baseline", :baseline] do
    sim_id =
      Keyword.get(opts, :sim_id, "vb_baseline_#{:erlang.unique_integer([:positive])}")

    state =
      opts
      |> Keyword.put(:sim_id, sim_id)
      |> Keyword.put_new(:max_days, 7)
      |> Keyword.put_new(:seed, 1)
      |> VendingBench.initial_state()

    max_turns = Keyword.get(opts, :driver_max_turns, Keyword.get(opts, :max_turns, 50))

    with {:ok, final_state, events, actions, steps} <-
           run_baseline_loop(state, max_turns, [], [], 0),
         artifact_opts <-
           Keyword.put(opts, :artifact_report_title, "VendingBench Offline Baseline Report"),
         {:ok, artifacts} <-
           Artifacts.write_run_artifacts(final_state, events, actions, artifact_opts) do
      {:ok, %{state: final_state, artifacts: artifacts, steps: steps}}
    end
  end

  def run_strategy(strategy, _opts), do: {:error, {:unknown_offline_strategy, strategy}}

  @spec events_for_day(map()) :: [Event.t()]
  def events_for_day(world), do: baseline_events_for_day(world)

  defp run_baseline_loop(state, max_turns, events, actions, turn) do
    cond do
      terminal?(state) ->
        {:ok, state, events, actions, turn}

      turn >= max_turns ->
        {:error, {:offline_turn_limit_exceeded, max_turns}}

      true ->
        planned_events = baseline_events_for_day(state.world)
        action = baseline_action_summary(state.world, planned_events)

        case ingest_collecting_events(state, planned_events, events) do
          {:ok, next_state, next_events} ->
            run_baseline_loop(
              next_state,
              max_turns,
              next_events,
              actions ++ [action],
              turn + 1
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp baseline_events_for_day(world) do
    baseline_order_events(world) ++ baseline_worker_events(world) ++ [Events.next_day_waited()]
  end

  defp baseline_order_events(world) do
    balance = get(world, :bank_balance, 0.0)
    day = get(world, :day_number, 1)

    reorder_plan = [
      %{supplier_id: "freshco", item_id: "water", quantity: 24, reorder_below: 18},
      %{supplier_id: "freshco", item_id: "cola", quantity: 24, reorder_below: 18},
      %{supplier_id: "snackworld", item_id: "chips", quantity: 16, reorder_below: 16},
      %{supplier_id: "snackworld", item_id: "candy_bar", quantity: 20, reorder_below: 16},
      %{supplier_id: "freshco", item_id: "energy_drink", quantity: 12, reorder_below: 10},
      %{supplier_id: "freshco", item_id: "sparkling_water", quantity: 12, reorder_below: 10}
    ]

    {events, _remaining_balance} =
      Enum.reduce(reorder_plan, {[], balance}, fn plan, {acc_events, remaining_balance} ->
        item_id = plan.item_id
        current_units = total_item_units(world, item_id)

        with true <- current_units < plan.reorder_below,
             {:ok, %{cost: cost, delivery_day: delivery_day}} <-
               Suppliers.process_order(plan.supplier_id, item_id, plan.quantity, day),
             true <- cost <= max(0.0, remaining_balance - 50.0) do
          event =
            Events.supplier_email_sent(
              plan.supplier_id,
              item_id,
              plan.quantity,
              cost,
              delivery_day
            )

          {acc_events ++ [event], Float.round(remaining_balance - cost, 2)}
        else
          _ -> {acc_events, remaining_balance}
        end
      end)

    events
  end

  defp baseline_worker_events(world) do
    stock_plan = [
      %{slot_id: "A1", item_id: "water", target: 12, price: 1.25},
      %{slot_id: "A2", item_id: "cola", target: 12, price: 1.75},
      %{slot_id: "B1", item_id: "chips", target: 10, price: 2.0},
      %{slot_id: "B2", item_id: "candy_bar", target: 10, price: 1.5},
      %{slot_id: "C1", item_id: "energy_drink", target: 8, price: 3.5},
      %{slot_id: "C2", item_id: "sparkling_water", target: 10, price: 2.5}
    ]

    machine = get(world, :machine, %{})
    slots = get(machine, :slots, %{})
    storage = get(world, :storage, %{})
    storage_inventory = get(storage, :inventory, %{})

    {stock_events, price_events, _virtual_storage} =
      Enum.reduce(stock_plan, {[], [], storage_inventory}, fn plan,
                                                              {stock_acc, price_acc,
                                                               virtual_storage} ->
        slot = Map.get(slots, plan.slot_id, %{})
        slot_item = get(slot, :item_id)
        slot_inventory = get(slot, :inventory, 0)
        available = Map.get(virtual_storage, plan.item_id, 0)
        can_stock? = is_nil(slot_item) or slot_item == plan.item_id
        quantity = min(max(plan.target - slot_inventory, 0), available)

        price_event? =
          (slot_item == plan.item_id and get(slot, :price) != plan.price) or quantity > 0

        stock_acc =
          if can_stock? and quantity > 0 do
            stock_acc ++ [Events.machine_stocked(plan.slot_id, plan.item_id, quantity, quantity)]
          else
            stock_acc
          end

        price_acc =
          if can_stock? and price_event? do
            price_acc ++
              [Events.price_set(plan.slot_id, plan.price, get(slot, :price, 0.0) || 0.0)]
          else
            price_acc
          end

        virtual_storage = Map.put(virtual_storage, plan.item_id, available - quantity)

        {stock_acc, price_acc, virtual_storage}
      end)

    cash = get(world, :cash_in_machine, 0.0)

    cash_events =
      if cash > 0 do
        [Events.cash_collected(cash)]
      else
        []
      end

    worker_actions = stock_events ++ price_events ++ cash_events

    if worker_actions == [] do
      []
    else
      summary =
        "Baseline stocked #{length(stock_events)} slot(s), repriced #{length(price_events)} slot(s), collected $#{format_price(cash)}."

      [
        Events.physical_worker_run_requested(
          "Run baseline restock, pricing, and cash collection checklist."
        )
        | worker_actions ++ [Events.physical_worker_finished(summary, [])]
      ]
    end
  end

  defp baseline_action_summary(world, events) do
    %{
      day: get(world, :day_number, 1),
      orders: Enum.count(events, &(&1.kind == "supplier_email_sent")),
      worker_dispatches: Enum.count(events, &(&1.kind == "physical_worker_run_requested")),
      waits: Enum.count(events, &(&1.kind == "next_day_waited"))
    }
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

  defp total_item_units(world, item_id) do
    storage_count =
      world
      |> get(:storage, %{})
      |> get(:inventory, %{})
      |> Map.get(item_id, 0)

    machine_count =
      world
      |> get(:machine, %{})
      |> get(:slots, %{})
      |> Enum.reduce(0, fn {_slot_id, slot}, acc ->
        if get(slot, :item_id) == item_id do
          acc + get(slot, :inventory, 0)
        else
          acc
        end
      end)

    pending_count =
      world
      |> get(:pending_deliveries, [])
      |> Enum.reduce(0, fn delivery, acc ->
        if get(delivery, :item_id) == item_id do
          acc + get(delivery, :quantity, 0)
        else
          acc
        end
      end)

    storage_count + machine_count + pending_count
  end

  defp terminal?(state) do
    status = get(state.world, :status)
    status in ["complete", "bankrupt"]
  end

  defp format_price(price) when is_float(price),
    do: :erlang.float_to_binary(price, decimals: 2)

  defp format_price(price) when is_integer(price),
    do: :erlang.float_to_binary(price / 1, decimals: 2)

  defp format_price(price), do: to_string(price)

  defp get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp get(_map, _key), do: nil

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
