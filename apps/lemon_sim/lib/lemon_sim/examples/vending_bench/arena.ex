defmodule LemonSim.Examples.VendingBench.Arena do
  @moduledoc """
  Deterministic Vending-Bench Arena runner.

  Arena runs multiple VendingBench operators at the same location. Each agent
  keeps its own machine and score, while shared same-item price pressure affects
  demand. The deterministic baseline also emits inter-agent messages, payments,
  and a small stock trade so the multi-agent surface is exercised without model
  spend.
  """

  alias LemonSim.Bench.Artifacts.AtomicFile
  alias LemonSim.Examples.VendingBench
  alias LemonSim.Examples.VendingBench.ArtifactRegistry
  alias LemonSim.Kernel.{Runner, State}

  @default_agents [
    %{id: "alex", name: "Alex Market"},
    %{id: "blair", name: "Blair Snacks"},
    %{id: "casey", name: "Casey Cold Drinks"},
    %{id: "devon", name: "Devon Pantry"},
    %{id: "ellis", name: "Ellis Express"}
  ]

  @spec run_offline_strategy(String.t() | atom(), keyword()) ::
          {:ok, %{world: map(), artifacts: map() | nil, events: list(), actions: list()}}
          | {:error, term()}
  def run_offline_strategy(strategy, opts \\ [])

  def run_offline_strategy(strategy, opts) when strategy in ["baseline", :baseline] do
    max_days = Keyword.get(opts, :max_days, 365)
    max_turns = Keyword.get(opts, :driver_max_turns, Keyword.get(opts, :max_turns, max_days + 5))
    sim_id = Keyword.get(opts, :sim_id, "vb_arena")
    seed = Keyword.get(opts, :seed, 42)

    states =
      opts
      |> agents()
      |> Enum.with_index()
      |> Enum.map(fn {agent, index} ->
        VendingBench.initial_state(
          sim_id: "#{sim_id}_#{agent.id}",
          max_days: max_days,
          seed: seed + index
        )
        |> State.update_world(fn world ->
          world
          |> Map.put(:arena_agent_id, agent.id)
          |> Map.put(:arena_agent_name, agent.name)
        end)
      end)

    case run_loop(states, max_turns, [], [], 0) do
      {:ok, final_states, events, actions, turns} ->
        world = arena_world(sim_id, final_states, events, actions, turns, max_days)
        artifacts = maybe_write_artifacts(world, events, actions, opts)
        {:ok, %{world: world, artifacts: artifacts, events: events, actions: actions}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run_offline_strategy(strategy, _opts), do: {:error, {:unknown_arena_strategy, strategy}}

  defp run_loop(states, max_turns, events, actions, turn) do
    cond do
      Enum.all?(states, &terminal?/1) ->
        {:ok, states, events, actions, turn}

      turn >= max_turns ->
        {:error, {:arena_turn_limit_exceeded, max_turns}}

      true ->
        states = apply_competition_pressure(states)

        case run_agent_days(states, events, actions, turn + 1) do
          {:ok, next_states, next_events, next_actions} ->
            {next_states, arena_events, arena_actions} = maybe_trade_between_agents(next_states)

            run_loop(
              next_states,
              max_turns,
              next_events ++ arena_events,
              next_actions ++ arena_actions,
              turn + 1
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp run_agent_days(states, events, actions, turn) do
    Enum.reduce_while(states, {:ok, [], events, actions}, fn state,
                                                             {:ok, acc_states, acc_events,
                                                              acc_actions} ->
      planned_events = VendingBench.offline_baseline_events_for_day(state.world)

      case ingest_collecting_events(state, planned_events, []) do
        {:ok, next_state, appended} ->
          agent_id = get(state.world, :arena_agent_id, state.sim_id)

          action = %{
            turn: turn,
            agent_id: agent_id,
            day: get(state.world, :day_number, 1),
            event_kinds: Enum.map(appended, & &1.kind)
          }

          {:cont,
           {:ok, acc_states ++ [next_state], acc_events ++ tag_events(agent_id, appended),
            acc_actions ++ [action]}}

        {:error, reason} ->
          {:halt, {:error, {:arena_agent_failed, get(state.world, :arena_agent_id), reason}}}
      end
    end)
    |> case do
      {:ok, next_states, next_events, next_actions} ->
        {:ok, next_states, next_events, next_actions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_competition_pressure(states) do
    price_floor =
      states
      |> Enum.flat_map(fn state ->
        state.world
        |> get_in([:machine, :slots])
        |> Enum.map(fn {_slot_id, slot} ->
          {get(slot, :item_id), get(slot, :price)}
        end)
      end)
      |> Enum.reject(fn {item_id, price} -> is_nil(item_id) or is_nil(price) end)
      |> Enum.group_by(fn {item_id, _price} -> item_id end, fn {_item_id, price} -> price end)
      |> Map.new(fn {item_id, prices} -> {item_id, Enum.min(prices)} end)

    Enum.map(states, fn state ->
      State.update_world(state, fn world ->
        update_in(world, [:machine, :slots], fn slots ->
          Map.new(slots, fn {slot_id, slot} ->
            item_id = get(slot, :item_id)
            price = get(slot, :price)
            cheapest = Map.get(price_floor, item_id)

            multiplier =
              cond do
                is_nil(item_id) or is_nil(price) or is_nil(cheapest) -> 1.0
                price <= cheapest -> 1.25
                price <= cheapest * 1.1 -> 1.0
                price <= cheapest * 1.35 -> 0.8
                true -> 0.6
              end

            {slot_id, Map.put(slot, :arena_demand_multiplier, multiplier)}
          end)
        end)
      end)
    end)
  end

  defp maybe_trade_between_agents(states) do
    day = states |> List.first() |> then(&get(&1.world, :day_number, 1))

    if day == 3 and length(states) >= 2 do
      [seller, buyer | rest] = states
      item_id = "water"
      quantity = 4
      unit_price = 0.85
      amount = Float.round(quantity * unit_price, 2)

      seller_qty = get_in(seller.world, [:storage, :inventory, item_id]) || 0
      buyer_balance = get(buyer.world, :bank_balance, 0.0)

      if seller_qty >= quantity and buyer_balance >= amount do
        seller = State.update_world(seller, &trade_seller_world(&1, item_id, quantity, amount))
        buyer = State.update_world(buyer, &trade_buyer_world(&1, item_id, quantity, amount, day))

        event = %{
          kind: "arena_trade_completed",
          day: day,
          from_agent_id: get(seller.world, :arena_agent_id),
          to_agent_id: get(buyer.world, :arena_agent_id),
          item_id: item_id,
          quantity: quantity,
          amount: amount
        }

        message = %{
          kind: "arena_message_sent",
          day: day,
          from_agent_id: event.from_agent_id,
          to_agent_id: event.to_agent_id,
          subject: "Emergency water transfer",
          body: "Sold #{quantity} water units for $#{format_price(amount)}."
        }

        {[seller, buyer | rest], [message, event], [event]}
      else
        {states, [], []}
      end
    else
      {states, [], []}
    end
  end

  defp ingest_collecting_events(state, events, collected_events) do
    Enum.reduce_while(events, {:ok, state, collected_events}, fn event,
                                                                 {:ok, current_state, acc_events} ->
      before_recent = current_state.recent_events

      case Runner.ingest_events(current_state, [event], VendingBench.modules().updater) do
        {:ok, next_state, _signal} ->
          appended = appended_recent_events(before_recent, next_state.recent_events)
          {:cont, {:ok, next_state, acc_events ++ appended}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp trade_seller_world(world, item_id, quantity, amount) do
    world
    |> update_storage_item(item_id, -quantity)
    |> Map.update!(:bank_balance, &Float.round(&1 + amount, 2))
  end

  defp trade_buyer_world(world, item_id, quantity, amount, day) do
    world
    |> update_storage_item(item_id, quantity)
    |> update_in([:storage, :batches], fn batches ->
      batches ++ [%{item_id: item_id, quantity: quantity, received_day: day}]
    end)
    |> Map.update!(:bank_balance, &Float.round(&1 - amount, 2))
  end

  defp update_storage_item(world, item_id, delta) do
    update_in(world, [:storage, :inventory], fn inventory ->
      Map.put(inventory, item_id, max(0, Map.get(inventory, item_id, 0) + delta))
    end)
  end

  defp arena_world(sim_id, states, events, actions, turns, max_days) do
    agents =
      states
      |> Enum.map(fn state ->
        scorecard = VendingBench.Performance.summarize(state.world)

        %{
          id: get(state.world, :arena_agent_id),
          name: get(state.world, :arena_agent_name),
          status: get(state.world, :status),
          day_number: get(state.world, :day_number),
          money_balance: scorecard.score_modes.money_balance,
          net_worth: scorecard.score_modes.v1_net_worth,
          units_sold: scorecard.units_sold,
          supplier_incidents: scorecard.supplier_incident_count,
          machine: get(state.world, :machine),
          storage: get(state.world, :storage),
          world: state.world,
          scorecard: scorecard
        }
      end)
      |> Enum.sort_by(& &1.money_balance, :desc)

    %{
      sim_id: sim_id,
      mode: "vending_bench_arena",
      status: if(Enum.all?(states, &terminal?/1), do: "complete", else: "in_progress"),
      max_days: max_days,
      day_number: agents |> List.first() |> get(:day_number, 1),
      turn_count: turns,
      arena_agents: agents,
      arena_events: events,
      arena_actions: actions,
      arena_messages: Enum.filter(events, &(get(&1, :kind) == "arena_message_sent")),
      arena_trades: Enum.filter(events, &(get(&1, :kind) == "arena_trade_completed")),
      leaderboard:
        Enum.map(agents, fn agent ->
          %{id: agent.id, name: agent.name, money_balance: agent.money_balance}
        end)
    }
  end

  defp maybe_write_artifacts(world, events, actions, opts) do
    case Keyword.get(opts, :artifact_dir) do
      nil ->
        nil

      artifact_dir ->
        File.mkdir_p!(artifact_dir)
        ArtifactRegistry.put(world.sim_id, artifact_dir)

        paths = %{
          final_world: Path.join(artifact_dir, "final_world.json"),
          arena_world: Path.join(artifact_dir, "arena_world.json"),
          arena_events: Path.join(artifact_dir, "arena_events.jsonl"),
          arena_actions: Path.join(artifact_dir, "arena_actions.jsonl"),
          arena_scorecard: Path.join(artifact_dir, "arena_scorecard.json"),
          arena_report: Path.join(artifact_dir, "arena_report.md")
        }

        encoded_world = Jason.encode!(jsonable(world), pretty: true)
        AtomicFile.write!(paths.final_world, encoded_world)
        AtomicFile.write!(paths.arena_world, encoded_world)
        AtomicFile.write!(paths.arena_events, jsonl(events))
        AtomicFile.write!(paths.arena_actions, jsonl(actions))

        AtomicFile.write!(
          paths.arena_scorecard,
          Jason.encode!(jsonable(scorecard(world)), pretty: true)
        )

        AtomicFile.write!(paths.arena_report, report(world, paths))
        paths
    end
  end

  defp scorecard(world) do
    %{
      sim_id: world.sim_id,
      mode: world.mode,
      status: world.status,
      day_number: world.day_number,
      leaderboard: world.leaderboard,
      agent_count: length(world.arena_agents),
      trade_count: length(world.arena_trades),
      message_count: length(world.arena_messages)
    }
  end

  defp report(world, paths) do
    standings =
      world.leaderboard
      |> Enum.with_index(1)
      |> Enum.map(fn {agent, rank} ->
        "#{rank}. #{agent.name}: $#{format_price(agent.money_balance)}"
      end)
      |> Enum.join("\n")

    """
    # VendingBench Arena Report

    Status: #{world.status}
    Day: #{world.day_number}
    Agents: #{length(world.arena_agents)}
    Trades: #{length(world.arena_trades)}
    Messages: #{length(world.arena_messages)}

    ## Standings

    #{standings}

    ## Artifacts

    - Final world: #{paths.final_world}
    - Arena world: #{paths.arena_world}
    - Arena events: #{paths.arena_events}
    - Arena actions: #{paths.arena_actions}
    - Arena scorecard: #{paths.arena_scorecard}
    """
  end

  defp terminal?(%State{} = state), do: get(state.world, :status) in ["complete", "bankrupt"]

  defp tag_events(agent_id, events) do
    Enum.map(events, fn event ->
      event
      |> Map.from_struct()
      |> Map.put(:agent_id, agent_id)
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

  defp agents(opts) do
    case Keyword.get(opts, :arena_agents) do
      count when is_integer(count) and count > 0 ->
        Enum.take(@default_agents, min(count, length(@default_agents)))

      list when is_list(list) ->
        Enum.map(list, fn
          %{id: id, name: name} -> %{id: to_string(id), name: to_string(name)}
          name when is_binary(name) -> %{id: slug(name), name: name}
        end)

      _ ->
        @default_agents
    end
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp jsonl(entries) do
    entries
    |> Enum.map(&Jason.encode!(jsonable(&1)))
    |> Enum.join("\n")
    |> then(&(&1 <> "\n"))
  end

  defp jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()

  defp jsonable(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), jsonable(value)} end)
  end

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(value), do: value

  defp format_price(price) when is_float(price), do: :erlang.float_to_binary(price, decimals: 2)

  defp format_price(price) when is_integer(price),
    do: :erlang.float_to_binary(price / 1, decimals: 2)

  defp format_price(price), do: to_string(price)

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
