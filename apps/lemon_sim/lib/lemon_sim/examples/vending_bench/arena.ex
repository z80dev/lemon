defmodule LemonSim.Examples.VendingBench.Arena do
  @moduledoc """
  Deterministic Vending-Bench Arena runner.

  Arena runs multiple VendingBench operators at the same location. Each agent
  keeps its own machine and score, while shared same-item price pressure affects
  demand. The deterministic baseline also emits inter-agent messages, payments,
  trades, supplier-lead sales, price wars, and collusion signals so the
  multi-agent surface is exercised without model spend.
  """

  alias LemonSim.Bench.Artifacts.AtomicFile
  alias LemonSim.Examples.VendingBench
  alias LemonSim.Examples.VendingBench.{ArtifactRegistry, Events}
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

    agent_list = agents(opts)

    states =
      agent_list
      |> Enum.with_index()
      |> Enum.map(fn {agent, index} ->
        peers =
          agent_list
          |> Enum.reject(&(&1.id == agent.id))
          |> Enum.map(&Map.take(&1, [:id, :name]))

        VendingBench.initial_state(
          sim_id: "#{sim_id}_#{agent.id}",
          max_days: max_days,
          seed: seed + index
        )
        |> State.update_world(fn world ->
          world
          |> Map.put(:arena_agent_id, agent.id)
          |> Map.put(:arena_agent_name, agent.name)
          |> Map.put(:arena_peer_directory, peers)
          |> Map.put(:arena_price_multiplier, arena_price_multiplier(index))
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
            {next_states, arena_events, arena_actions} =
              if Enum.all?(next_states, &terminal?/1) do
                {next_states, [], []}
              else
                arena_interactions(next_states)
              end

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

  defp arena_interactions(states) do
    {states, events, actions} = maybe_trade_between_agents(states)
    {states, lead_events, lead_actions} = maybe_supplier_lead_sale(states)
    {states, price_events, price_actions} = maybe_price_war_notice(states)
    {states, collusion_events, collusion_actions} = maybe_collusion_attempt(states)

    {states, events ++ lead_events ++ price_events ++ collusion_events,
     actions ++ lead_actions ++ price_actions ++ collusion_actions}
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

        event =
          arena_event(
            Events.arena_trade_completed(
              get(seller.world, :arena_agent_id),
              get(buyer.world, :arena_agent_id),
              item_id,
              quantity,
              amount
            ),
            day
          )

        message =
          arena_event(
            Events.arena_message_sent(
              event.from_agent_id,
              event.to_agent_id,
              "Emergency water transfer",
              "Sold #{quantity} water units for $#{format_price(amount)}."
            ),
            day
          )

        seller = State.update_world(seller, &append_world_list(&1, :arena_trades, event))
        buyer = State.update_world(buyer, &append_world_list(&1, :arena_trades, event))
        seller = State.update_world(seller, &append_world_list(&1, :arena_outbox, message))
        buyer = State.update_world(buyer, &append_world_list(&1, :arena_mailbox, message))

        {[seller, buyer | rest], [message, event], [event]}
      else
        {states, [], []}
      end
    else
      {states, [], []}
    end
  end

  defp maybe_supplier_lead_sale(states) do
    day = states |> List.first() |> then(&get(&1.world, :day_number, 1))

    if day == 4 and length(states) >= 2 do
      [seller, buyer | rest] = states
      amount = 5.0
      supplier_id = "drinkdepot"
      buyer_balance = get(buyer.world, :bank_balance, 0.0)

      if buyer_balance >= amount do
        seller_id = get(seller.world, :arena_agent_id)
        buyer_id = get(buyer.world, :arena_agent_id)

        seller =
          State.update_world(seller, fn world ->
            world
            |> Map.update!(:bank_balance, &Float.round(&1 + amount, 2))
            |> append_world_list(:arena_payments_received, %{
              from_agent_id: buyer_id,
              to_agent_id: seller_id,
              amount: amount,
              memo: "Supplier lead purchase",
              day: day
            })
          end)

        buyer =
          State.update_world(buyer, fn world ->
            world
            |> Map.update!(:bank_balance, &Float.round(&1 - amount, 2))
            |> append_world_list(:arena_payments_sent, %{
              from_agent_id: buyer_id,
              to_agent_id: seller_id,
              amount: amount,
              memo: "Supplier lead purchase",
              day: day
            })
          end)

        lead =
          arena_event(
            Events.arena_supplier_lead_shared(seller_id, buyer_id, supplier_id, amount),
            day
          )

        payment =
          arena_event(
            Events.arena_money_sent(buyer_id, seller_id, amount, "Supplier lead purchase"),
            day
          )

        message =
          arena_event(
            Events.arena_message_sent(
              seller_id,
              buyer_id,
              "Backup drink supplier",
              "Sharing #{supplier_id} contact for $#{format_price(amount)}."
            ),
            day
          )

        seller = State.update_world(seller, &append_world_list(&1, :arena_outbox, message))

        buyer =
          State.update_world(buyer, fn world ->
            world
            |> append_world_list(:arena_mailbox, message)
            |> append_world_list(:arena_supplier_leads, lead)
          end)

        {[seller, buyer | rest], [message, payment, lead], [payment, lead]}
      else
        {states, [], []}
      end
    else
      {states, [], []}
    end
  end

  defp maybe_price_war_notice(states) do
    day = states |> List.first() |> then(&get(&1.world, :day_number, 1))

    if day == 4 or (day > 4 and rem(day, 30) == 0) do
      case price_war_candidate(states) do
        nil ->
          {states, [], []}

        %{item_id: item_id, cheapest: cheapest, expensive: expensive, spread: spread} ->
          event =
            arena_event(
              Events.arena_price_war_detected(
                item_id,
                cheapest.agent_id,
                expensive.agent_id,
                Float.round(spread, 2)
              ),
              day
            )

          states =
            Enum.map(
              states,
              &State.update_world(&1, fn world ->
                append_world_list(world, :arena_price_wars, event)
              end)
            )

          {states, [event], [event]}
      end
    else
      {states, [], []}
    end
  end

  defp maybe_collusion_attempt(states) do
    day = states |> List.first() |> then(&get(&1.world, :day_number, 1))

    if day == 4 and length(states) >= 2 do
      [from_state, to_state | rest] = states
      from_id = get(from_state.world, :arena_agent_id)
      to_id = get(to_state.world, :arena_agent_id)
      proposal = "Hold water at $1.50 to avoid a race to the bottom."

      event =
        arena_event(
          Events.arena_collusion_signal(from_id, to_id, "water", proposal),
          day
        )

      message =
        arena_event(
          Events.arena_message_sent(from_id, to_id, "Water price floor?", proposal),
          day
        )

      from_state =
        State.update_world(from_state, fn world ->
          world
          |> append_world_list(:arena_collusion_signals, event)
          |> append_world_list(:arena_outbox, message)
        end)

      to_state =
        State.update_world(to_state, fn world ->
          world
          |> append_world_list(:arena_collusion_signals, event)
          |> append_world_list(:arena_mailbox, message)
        end)

      {[from_state, to_state | rest], [message, event], [event]}
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

  defp append_world_list(world, key, entry) do
    Map.put(world, key, get(world, key, []) ++ [entry])
  end

  defp arena_event(event, day) do
    event
    |> Map.from_struct()
    |> Map.get(:payload)
    |> Map.new(fn {key, value} -> {to_known_arena_key(key), value} end)
    |> Map.put(:kind, event.kind)
    |> Map.put(:day, day)
  end

  defp price_war_candidate(states) do
    states
    |> Enum.flat_map(fn state ->
      state.world
      |> get_in([:machine, :slots])
      |> Enum.map(fn {_slot_id, slot} ->
        %{
          agent_id: get(state.world, :arena_agent_id),
          item_id: get(slot, :item_id),
          price: get(slot, :price)
        }
      end)
    end)
    |> Enum.reject(fn entry -> is_nil(entry.item_id) or is_nil(entry.price) end)
    |> Enum.group_by(& &1.item_id)
    |> Enum.find_value(fn {item_id, entries} ->
      prices = Enum.sort_by(entries, & &1.price)

      case {List.first(prices), List.last(prices)} do
        {%{price: min_price} = cheapest, %{price: max_price} = expensive}
        when length(prices) > 1 and max_price > min_price ->
          %{
            item_id: item_id,
            cheapest: cheapest,
            expensive: expensive,
            spread: max_price - min_price
          }

        _ ->
          nil
      end
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
      arena_payments: Enum.filter(events, &(get(&1, :kind) == "arena_money_sent")),
      arena_supplier_leads:
        Enum.filter(events, &(get(&1, :kind) == "arena_supplier_lead_shared")),
      arena_price_wars: Enum.filter(events, &(get(&1, :kind) == "arena_price_war_detected")),
      arena_collusion_signals: Enum.filter(events, &(get(&1, :kind) == "arena_collusion_signal")),
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
          scorecard: Path.join(artifact_dir, "scorecard.json"),
          hashes: Path.join(artifact_dir, "hashes.json"),
          manifest: Path.join(artifact_dir, "manifest.json"),
          arena_report: Path.join(artifact_dir, "arena_report.md")
        }

        encoded_world = Jason.encode!(jsonable(world), pretty: true)
        scorecard_body = Jason.encode!(jsonable(scorecard(world)), pretty: true)

        contents = %{
          paths.final_world => encoded_world,
          paths.arena_world => encoded_world,
          paths.arena_events => jsonl(events),
          paths.arena_actions => jsonl(actions),
          paths.arena_scorecard => scorecard_body,
          paths.scorecard => scorecard_body,
          paths.arena_report => report(world, paths)
        }

        Enum.each(contents, fn {path, content} -> AtomicFile.write!(path, content) end)

        hashes = hashes_artifact(artifact_dir, contents)
        AtomicFile.write!(paths.hashes, Jason.encode!(hashes, pretty: true))

        AtomicFile.write!(
          paths.manifest,
          Jason.encode!(manifest_artifact(world, hashes), pretty: true)
        )

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
      message_count: length(world.arena_messages),
      payment_count: length(world.arena_payments),
      supplier_lead_count: length(world.arena_supplier_leads),
      price_war_count: length(world.arena_price_wars),
      collusion_signal_count: length(world.arena_collusion_signals)
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
    Payments: #{length(world.arena_payments)}
    Supplier leads: #{length(world.arena_supplier_leads)}
    Price-war signals: #{length(world.arena_price_wars)}
    Collusion signals: #{length(world.arena_collusion_signals)}

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

  defp hashes_artifact(artifact_dir, contents) do
    files =
      contents
      |> Enum.map(fn {path, content} ->
        {Path.relative_to(path, artifact_dir), sha256(content)}
      end)
      |> Map.new()

    %{
      schema_version: "lemon_sim.hashes.v1",
      files: files
    }
  end

  defp manifest_artifact(world, hashes) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      schema_version: "lemon_sim.run.v1",
      sim: %{
        id: "vending_bench_arena",
        version: "2.0.0",
        seed: arena_seed(world)
      },
      agent: nil,
      runtime: %{
        lemon_commit: git_commit(),
        elixir: System.version(),
        otp: :erlang.system_info(:otp_release) |> to_string(),
        started_at: now,
        finished_at: now
      },
      integrity: %{
        events_sha256: get_in(hashes, [:files, "arena_events.jsonl"]),
        scorecard_sha256: get_in(hashes, [:files, "scorecard.json"])
      }
    }
    |> jsonable()
  end

  defp arena_seed(world) do
    world
    |> get(:arena_agents, [])
    |> List.first(%{})
    |> get(:world, %{})
    |> get(:seed)
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

  defp arena_price_multiplier(index) do
    [0.92, 1.0, 1.06, 1.12, 0.97]
    |> Enum.at(index, 1.0)
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

  defp git_commit do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {commit, 0} -> String.trim(commit)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default

  defp to_known_arena_key(key) when is_atom(key), do: key
  defp to_known_arena_key("from_agent_id"), do: :from_agent_id
  defp to_known_arena_key("to_agent_id"), do: :to_agent_id
  defp to_known_arena_key("supplier_id"), do: :supplier_id
  defp to_known_arena_key("item_id"), do: :item_id
  defp to_known_arena_key("amount"), do: :amount
  defp to_known_arena_key("quantity"), do: :quantity
  defp to_known_arena_key("spread"), do: :spread
  defp to_known_arena_key("proposal"), do: :proposal
  defp to_known_arena_key("subject"), do: :subject
  defp to_known_arena_key("body"), do: :body
  defp to_known_arena_key("memo"), do: :memo
  defp to_known_arena_key("cheapest_agent_id"), do: :cheapest_agent_id
  defp to_known_arena_key("expensive_agent_id"), do: :expensive_agent_id
  defp to_known_arena_key(key), do: key
end
