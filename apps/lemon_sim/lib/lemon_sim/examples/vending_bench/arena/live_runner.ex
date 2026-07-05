defmodule LemonSim.Examples.VendingBench.Arena.LiveRunner do
  @moduledoc false

  require Logger

  alias LemonSim.Examples.VendingBench
  alias LemonSim.Examples.VendingBench.{Arena, Artifacts, Events, Runtime}
  alias LemonSim.Kernel.{Runner, State}
  alias LemonSim.LLM.Deciders.ExternalDecider
  alias LemonSim.LLM.Usage

  @default_day_budget_ms 300_000
  @interaction_kinds ~w(arena_message_sent arena_money_sent arena_trade_completed arena_supplier_lead_shared arena_collusion_signal)

  def run(opts \\ []) when is_list(opts) do
    sim_id = Keyword.get(opts, :sim_id, "vb_arena_live")
    max_days = Keyword.get(opts, :max_days, 30)
    day_budget_ms = Keyword.get(opts, :arena_day_budget_ms, @default_day_budget_ms)

    with {:ok, slots} <- build_slots(sim_id, max_days, opts) do
      try do
        slots = apply_pressure(slots)

        case run_days(slots, [], 0, day_budget_ms, max_days) do
          {:ok, final_slots, arena_events, turn_count} ->
            states = Enum.map(final_slots, & &1.state)
            actions = arena_actions(final_slots)
            world = Arena.arena_world(sim_id, states, arena_events, actions, turn_count, max_days)

            write_agent_artifacts(final_slots, opts)

            usage = aggregate_usage(sim_id, final_slots)

            artifacts =
              Arena.maybe_write_artifacts(
                world,
                arena_events,
                actions,
                Keyword.put(opts, :usage_body, stable_json(usage))
              )

            {:ok,
             %{
               world: world,
               artifacts: artifacts,
               events: arena_events,
               actions: actions,
               usage: usage,
               slots: final_slots
             }}

          {:error, reason} ->
            {:error, reason}
        end
      after
        stop_slots(slots)
      end
    end
  end

  defp build_slots(sim_id, max_days, opts) do
    seed = Keyword.get(opts, :seed, 42)
    models = Keyword.get(opts, :arena_models, [])
    external_cmds = Keyword.get(opts, :arena_external_cmds, [])
    agent_opts = Keyword.get(opts, :arena_agent_opts, [])

    count =
      cond do
        models != [] and external_cmds != [] -> {:error, :mixed_arena_deciders_unsupported}
        models != [] -> length(models)
        external_cmds != [] -> length(external_cmds)
        true -> Keyword.get(opts, :arena_agents, 5)
      end

    if match?({:error, _reason}, count) do
      count
    else
      agents = Arena.agents(Keyword.put(opts, :arena_agents, count))

      if length(agents) != count do
        {:error, {:invalid_arena_agent_count, count}}
      else
        agents
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {agent, index}, {:ok, acc} ->
          case build_slot(
                 agent,
                 index,
                 agents,
                 sim_id,
                 max_days,
                 seed,
                 models,
                 external_cmds,
                 agent_opts,
                 opts
               ) do
            {:ok, slot} -> {:cont, {:ok, acc ++ [slot]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end
    end
  end

  defp build_slot(
         agent,
         index,
         agents,
         sim_id,
         max_days,
         seed,
         models,
         external_cmds,
         agent_opts,
         opts
       ) do
    overrides =
      agent_opts
      |> Enum.at(index, [])
      |> Kernel.||([])

    with {:ok, model_opts} <- arena_model_opts(models, index) do
      external_opts =
        case Enum.at(external_cmds, index) do
          cmd when is_binary(cmd) and cmd != "" -> [external_cmd: cmd]
          _ -> []
        end

      peers =
        agents
        |> Enum.reject(&(&1.id == agent.id))
        |> Enum.map(&Map.take(&1, [:id, :name]))

      state =
        VendingBench.initial_state(
          sim_id: "#{sim_id}_#{agent.id}",
          max_days: max_days,
          seed: seed + index,
          model: Keyword.get(model_opts, :model)
        )
        |> State.update_world(fn world ->
          world
          |> Map.put(:arena_agent_id, agent.id)
          |> Map.put(:arena_agent_name, agent.name)
          |> Map.put(:arena_peer_directory, peers)
          |> Map.put(:arena_price_multiplier, Arena.arena_price_multiplier(index))
        end)
        |> maybe_setup_state(agent, index, opts)

      run_opts =
        overrides
        |> Keyword.merge(model_opts)
        |> Keyword.merge(external_opts)
        |> then(&VendingBench.default_opts/1)
        |> Keyword.merge(opts)
        |> Keyword.merge(overrides)
        |> Keyword.merge(model_opts)
        |> Keyword.merge(external_opts)
        |> Keyword.put(:persist?, Keyword.get(opts, :persist?, false))
        |> Keyword.put(:on_before_step, Keyword.get(opts, :on_before_step))
        |> Keyword.put(:on_after_step, Keyword.get(opts, :on_after_step))
        |> Keyword.put(
          :live_artifact_checkpoints?,
          Keyword.get(opts, :live_artifact_checkpoints?, true)
        )
        |> maybe_put_agent_artifact_dir(opts, agent.id)

      state = VendingBench.stamp_runtime_models(state, run_opts)
      {:ok, usage_collector} = Usage.start_link(state.sim_id)

      run_opts =
        run_opts
        |> Keyword.put(:usage_collector, usage_collector)
        |> Keyword.put_new(:usage_actor_id, "operator")

      with {:ok, run_opts, external_decider} <- maybe_start_external_decider(state, run_opts) do
        {:ok,
         %{
           id: agent.id,
           name: agent.name,
           state: state,
           run_opts: run_opts,
           events: [],
           actions: [],
           turn: 0,
           usage_collector: usage_collector,
           external_decider: external_decider
         }}
      end
    end
  end

  defp arena_model_opts(models, index) do
    case Enum.at(models, index) do
      {model, api_key} ->
        {:ok, [model: model, stream_options: %{api_key: api_key}]}

      %{model: model, api_key: api_key} ->
        {:ok, [model: model, stream_options: %{api_key: api_key}]}

      nil ->
        {:ok, []}

      other ->
        {:error, {:invalid_arena_model_spec, index, other}}
    end
  end

  defp maybe_setup_state(state, agent, index, opts) do
    case Keyword.get(opts, :arena_state_setup) do
      setup when is_function(setup, 3) -> setup.(state, agent, index)
      _ -> state
    end
  end

  defp maybe_put_agent_artifact_dir(run_opts, opts, agent_id) do
    case Keyword.get(opts, :artifact_dir) do
      nil ->
        run_opts

      artifact_dir ->
        Keyword.put(run_opts, :artifact_dir, Path.join([artifact_dir, "agents", agent_id]))
    end
  end

  defp maybe_start_external_decider(state, run_opts) do
    case Keyword.get(run_opts, :external_cmd) do
      cmd when is_binary(cmd) and cmd != "" ->
        session_opts =
          run_opts
          |> Keyword.put(:cmd, cmd)
          |> Keyword.put(:sim_id, state.sim_id)
          |> Keyword.put(:max_days, get(state.world, :max_days, 30))
          |> Keyword.put_new(:max_turns, Keyword.get(run_opts, :driver_max_turns))

        case ExternalDecider.start_link(session_opts) do
          {:ok, pid} -> {:ok, Keyword.put(run_opts, :external_decider, pid), pid}
          {:error, reason} -> {:error, {:external_decider_start_failed, state.sim_id, reason}}
        end

      _ ->
        {:ok, run_opts, nil}
    end
  end

  defp run_days(slots, arena_events, turn_count, day_budget_ms, max_days) do
    cond do
      Enum.all?(slots, &Arena.terminal?(&1.state)) ->
        {:ok, slots, arena_events, turn_count}

      true ->
        current_day =
          slots
          |> Enum.reject(&Arena.terminal?(&1.state))
          |> Enum.map(&get(&1.state.world, :day_number, 1))
          |> Enum.min(fn -> max_days end)

        case run_slot_days(slots, current_day, day_budget_ms) do
          {:ok, next_slots, day_events} ->
            {:ok, delivered_slots, next_arena_events} =
              deliver_interactions(next_slots, day_events, arena_events)

            run_days(
              apply_pressure(delivered_slots),
              next_arena_events,
              turn_count + 1,
              day_budget_ms,
              max_days
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp run_slot_days(slots, current_day, day_budget_ms) do
    active_ids =
      slots
      |> Enum.filter(fn slot ->
        not Arena.terminal?(slot.state) and get(slot.state.world, :day_number, 1) == current_day
      end)
      |> Map.new(&{&1.id, &1})

    tasks =
      Map.new(active_ids, fn {id, slot} ->
        {id, Task.async(fn -> drive_slot_day(slot) end)}
      end)

    task_slots =
      Map.new(tasks, fn {id, task} ->
        {task.ref, {id, Map.fetch!(active_ids, id)}}
      end)

    hard_timeout_ms = max(day_budget_ms * 2, 100)

    task_results =
      tasks
      |> Map.values()
      |> Task.yield_many(hard_timeout_ms)
      |> Map.new(fn {task, result} ->
        {id, slot} = Map.fetch!(task_slots, task.ref)

        case result || Task.shutdown(task, :brutal_kill) do
          {:ok, {:ok, next_slot, day_events}} ->
            {id, {:ok, next_slot, day_events}}

          {:ok, {:error, reason}} ->
            {id, {:error, reason}}

          {:exit, reason} ->
            {id, {:error, {:arena_agent_failed, id, reason}}}

          nil ->
            # Hard-kill fallback uses the pre-day snapshot; soft day deadlines preserve partial progress.
            {id, recover_slot_timeout(slot, day_budget_ms)}
        end
      end)

    {next_slots, day_events, errors} =
      Enum.reduce(slots, {[], [], []}, fn slot, {acc_slots, acc_events, acc_errors} ->
        case Map.get(task_results, slot.id) do
          {:ok, next_slot, slot_day_events} ->
            {acc_slots ++ [next_slot], acc_events ++ slot_day_events, acc_errors}

          {:error, reason} ->
            {acc_slots ++ [slot], acc_events, acc_errors ++ [reason]}

          nil ->
            {acc_slots ++ [slot], acc_events, acc_errors}
        end
      end)

    case errors do
      [] -> {:ok, next_slots, day_events}
      [reason | _] -> {:error, reason}
    end
  end

  defp drive_slot_day(slot) do
    event_count = length(slot.events)

    deadline_ms =
      System.monotonic_time(:millisecond) + Keyword.fetch!(slot.run_opts, :arena_day_budget_ms)

    case VendingBench.run_live_until_next_day(
           slot.state,
           slot.run_opts,
           slot.events,
           slot.actions,
           slot.turn,
           deadline_ms: deadline_ms
         ) do
      {:ok, state, events, actions, turn, _appended} ->
        day_events =
          events
          |> Enum.drop(event_count)
          |> Enum.map(&{slot.id, &1})

        {:ok, %{slot | state: state, events: events, actions: actions, turn: turn}, day_events}

      {:day_timeout, state, events, actions, turn} ->
        partial_day_events =
          events
          |> Enum.drop(event_count)
          |> Enum.map(&{slot.id, &1})

        case recover_slot_timeout(
               %{slot | state: state, events: events, actions: actions, turn: turn},
               Keyword.fetch!(slot.run_opts, :arena_day_budget_ms)
             ) do
          {:ok, next_slot, recovery_day_events} ->
            {:ok, next_slot, partial_day_events ++ recovery_day_events}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:arena_agent_failed, slot.id, reason}}
    end
  end

  defp recover_slot_timeout(slot, day_budget_ms) do
    event_count = length(slot.events)

    case VendingBench.recover_live_day_timeout(
           slot.state,
           slot.run_opts,
           slot.events,
           slot.actions,
           slot.turn,
           day_budget_ms
         ) do
      {:ok, state, events, actions, turn, _appended} ->
        day_events =
          events
          |> Enum.drop(event_count)
          |> Enum.map(&{slot.id, &1})

        {:ok, %{slot | state: state, events: events, actions: actions, turn: turn}, day_events}

      {:error, reason} ->
        {:error, {:arena_agent_failed, slot.id, reason}}
    end
  end

  defp deliver_interactions(slots, day_events, arena_events) do
    interactions =
      day_events
      |> Enum.filter(fn {_agent_id, event} -> event.kind in @interaction_kinds end)
      |> Enum.with_index(length(arena_events) + 1)
      |> Enum.map(fn {{agent_id, event}, seq} -> arena_event(agent_id, event, seq) end)

    {next_slots, next_arena_events} =
      Enum.reduce(interactions, {slots, arena_events}, fn arena_event, {acc_slots, acc_events} ->
        case deliver_interaction(acc_slots, arena_event) do
          {:ok, delivered_slots, delivery_events} ->
            base_events = acc_events ++ [arena_event]

            delivery_events =
              delivery_events
              |> Enum.with_index(length(base_events) + 1)
              |> Enum.map(fn {event, seq} -> Map.put(event, :arena_seq, seq) end)

            {delivered_slots, base_events ++ delivery_events}

          {:error, reason} ->
            Logger.warning(
              "Arena delivery failed recipient=#{inspect(get(arena_event, :to_agent_id))} kind=#{inspect(get(arena_event, :kind))} reason=#{inspect(reason)}"
            )

            failure =
              arena_delivery_failed_event(arena_event, reason, length(acc_events) + 2)

            {acc_slots, acc_events ++ [arena_event, failure]}
        end
      end)

    {:ok, next_slots, next_arena_events}
  end

  defp deliver_interaction(slots, arena_event) do
    to_agent_id = get(arena_event, :to_agent_id)
    event = event_from_arena_event(arena_event)
    recipient_found? = Enum.any?(slots, &(&1.id == to_agent_id))

    if recipient_found? do
      Enum.map_reduce(slots, :ok, fn slot, status ->
        if slot.id == to_agent_id do
          before_recent = slot.state.recent_events

          case Runner.ingest_events(
                 slot.state,
                 [event],
                 VendingBench.modules(slot.run_opts).updater
               ) do
            {:ok, next_state, _signal} ->
              appended = appended_recent_events(before_recent, next_state.recent_events)

              {%{slot | state: next_state, events: slot.events ++ appended},
               trade_delivery_status(status, arena_event, appended)}

            {:error, reason} ->
              {slot,
               {:error, {:arena_delivery_failed, arena_event.arena_seq, to_agent_id, reason}}}
          end
        else
          {slot, status}
        end
      end)
      |> case do
        {updated_slots, :ok} ->
          {:ok, updated_slots, []}

        {updated_slots, {:trade_rejected, reason}} ->
          reverse_trade_for_seller(updated_slots, arena_event, reason)

        {_updated_slots, {:error, reason}} ->
          {:error, reason}
      end
    else
      {:error, {:arena_delivery_failed, arena_event.arena_seq, to_agent_id, :recipient_not_found}}
    end
  end

  defp trade_delivery_status(:ok, %{kind: "arena_trade_completed"}, appended) do
    case Enum.find(appended, &(&1.kind == "action_rejected")) do
      nil ->
        :ok

      rejected ->
        {:trade_rejected, get(rejected.payload, :reason, "Arena trade delivery rejected")}
    end
  end

  defp trade_delivery_status(status, _arena_event, _appended), do: status

  defp reverse_trade_for_seller(slots, arena_event, reason) do
    seller_id = get(arena_event, :from_agent_id)
    reversal = trade_reversal_event(arena_event, reason)

    Enum.map_reduce(slots, :ok, fn slot, status ->
      if slot.id == seller_id do
        before_recent = slot.state.recent_events

        case Runner.ingest_events(
               slot.state,
               [event_from_arena_event(reversal)],
               VendingBench.modules(slot.run_opts).updater
             ) do
          {:ok, next_state, _signal} ->
            appended = appended_recent_events(before_recent, next_state.recent_events)
            {%{slot | state: next_state, events: slot.events ++ appended}, status}

          {:error, reason} ->
            {slot, {:error, {:arena_delivery_failed, reversal.arena_seq, seller_id, reason}}}
        end
      else
        {slot, status}
      end
    end)
    |> case do
      {updated_slots, :ok} ->
        {:ok, updated_slots, [arena_delivery_failed_event(arena_event, reason, nil), reversal]}

      {_updated_slots, {:error, reason}} ->
        {:error, reason}
    end
  end

  defp arena_delivery_failed_event(arena_event, reason, seq) do
    %{
      kind: "arena_delivery_failed",
      agent_id: get(arena_event, :agent_id),
      from_agent_id: get(arena_event, :from_agent_id),
      to_agent_id: get(arena_event, :to_agent_id),
      original_kind: get(arena_event, :kind),
      original_arena_seq: get(arena_event, :arena_seq),
      reason: inspect(reason),
      arena_seq: seq,
      day: get(arena_event, :day),
      ts_ms: get(arena_event, :ts_ms)
    }
  end

  defp trade_reversal_event(arena_event, reason) do
    event =
      Events.arena_trade_reversed(
        get(arena_event, :from_agent_id),
        get(arena_event, :to_agent_id),
        get(arena_event, :item_id),
        get(arena_event, :quantity),
        get(arena_event, :amount),
        reason
      )

    arena_event(get(arena_event, :to_agent_id), event, nil)
  end

  defp event_from_arena_event(arena_event) do
    payload =
      arena_event
      |> Map.drop([:kind, :agent_id, :arena_seq, :day, :ts_ms])
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    LemonSim.Kernel.Event.new(arena_event.kind, payload)
  end

  defp arena_event(agent_id, event, seq) do
    payload =
      event.payload
      |> Map.new(fn {key, value} -> {to_known_arena_key(key), value} end)

    payload
    |> Map.put(:kind, event.kind)
    |> Map.put(:agent_id, agent_id)
    |> Map.put(:arena_seq, seq)
    |> Map.put(:day, get(payload, :day, nil))
    |> Map.put(:ts_ms, event.ts_ms)
  end

  defp apply_pressure(slots) do
    states = slots |> Enum.map(& &1.state) |> Arena.apply_competition_pressure()

    slots
    |> Enum.zip(states)
    |> Enum.map(fn {slot, state} -> %{slot | state: state} end)
  end

  defp arena_actions(slots) do
    Enum.flat_map(slots, fn slot ->
      Enum.map(slot.actions, &Map.merge(%{agent_id: slot.id}, Map.new(&1)))
    end)
  end

  defp write_agent_artifacts(slots, opts) do
    if Keyword.get(opts, :artifact_dir) do
      Enum.each(slots, fn slot ->
        artifact_opts =
          slot.run_opts
          |> Keyword.put(:artifact_report_title, "VendingBench Live Arena Agent Report")
          |> Keyword.put(:usage_collector, slot.usage_collector)

        {:ok, _artifacts} =
          Artifacts.write_run_artifacts(slot.state, slot.events, slot.actions, artifact_opts)
      end)
    end
  end

  defp aggregate_usage(sim_id, slots) do
    agent_usage =
      slots
      |> Enum.map(fn slot ->
        {slot.id, Usage.artifact(slot.usage_collector, slot.state.sim_id)}
      end)
      |> Map.new()

    totals =
      agent_usage
      |> Map.values()
      |> Enum.map(& &1.totals)
      |> Enum.reduce(zero_totals(), &merge_usage_totals/2)

    actors =
      agent_usage
      |> Enum.flat_map(fn {agent_id, usage} ->
        Enum.map(usage.actors, fn {actor_id, actor_usage} ->
          {"#{agent_id}:#{actor_id}", actor_usage}
        end)
      end)
      |> Map.new()

    %{
      schema: "lemon_sim.usage.v1",
      sim_id: sim_id,
      totals: totals,
      cost_known?: Enum.all?(Map.values(agent_usage), &get(&1, :cost_known?, true)),
      actors: actors,
      agents: agent_usage
    }
  end

  defp zero_totals do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      decisions: 0,
      cost_usd: 0.0
    }
  end

  defp merge_usage_totals(totals, acc) do
    %{
      input_tokens: acc.input_tokens + totals.input_tokens,
      output_tokens: acc.output_tokens + totals.output_tokens,
      cache_read_tokens: acc.cache_read_tokens + totals.cache_read_tokens,
      cache_write_tokens: acc.cache_write_tokens + totals.cache_write_tokens,
      decisions: acc.decisions + totals.decisions,
      cost_usd: merge_cost(acc.cost_usd, totals.cost_usd)
    }
  end

  defp merge_cost(nil, _cost), do: nil
  defp merge_cost(_acc, nil), do: nil
  defp merge_cost(acc, cost), do: Float.round(acc + cost, 6)

  defp stable_json(value), do: Jason.encode!(jsonable(value), pretty: true) <> "\n"

  defp jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()

  defp jsonable(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), jsonable(value)} end)

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(value), do: value

  defp appended_recent_events(before_recent, after_recent) do
    Runtime.appended_recent_events(before_recent, after_recent)
  end

  defp stop_slots(slots) do
    Enum.each(slots, fn slot ->
      if is_pid(slot.external_decider),
        do: ExternalDecider.stop(slot.external_decider, "run_complete")

      if is_pid(slot.usage_collector) and Process.alive?(slot.usage_collector),
        do: Agent.stop(slot.usage_collector)
    end)
  end

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Runtime.get(map, key, default)

  defp get(map, key, default) when is_map(map), do: Runtime.get(map, key, default)
  defp get(_map, _key, default), do: default

  defp to_known_arena_key(key) when is_atom(key), do: key
  defp to_known_arena_key("from_agent_id"), do: :from_agent_id
  defp to_known_arena_key("to_agent_id"), do: :to_agent_id
  defp to_known_arena_key("supplier_id"), do: :supplier_id
  defp to_known_arena_key("item_id"), do: :item_id
  defp to_known_arena_key("amount"), do: :amount
  defp to_known_arena_key("quantity"), do: :quantity
  defp to_known_arena_key("reason"), do: :reason
  defp to_known_arena_key("proposal"), do: :proposal
  defp to_known_arena_key("subject"), do: :subject
  defp to_known_arena_key("body"), do: :body
  defp to_known_arena_key("memo"), do: :memo
  defp to_known_arena_key(key), do: key
end
