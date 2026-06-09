defmodule LemonSim.Examples.VendingBench do
  @moduledoc """
  Vending Bench simulation built on LemonSim.

  A single-operator vending machine business sim where an AI operator manages
  finances, orders from suppliers, and dispatches a physical worker subagent
  for on-site machine tasks (stocking, pricing, cash collection) over a
  configurable simulated horizon.

  The novel piece is the nested agent: the operator's `run_physical_worker`
  terminal tool runs a bounded ToolLoopDecider call with worker-specific tools
  and context, producing events that flow through the standard updater pipeline.
  """

  alias LemonCore.Config.Modular
  alias LemonCore.MapHelpers
  alias LemonSim.LLM.GameHelpers.{Config, ProviderThrottle}

  alias LemonSim.Examples.VendingBench.{
    ActionSpace,
    Artifacts,
    Events,
    OfflineRunner,
    Performance,
    Projector,
    Updater,
    World
  }

  alias LemonSim.Kernel.DecisionAdapters.ExecutedCallEvents
  alias LemonSim.LLM.Deciders.ToolLoopDecider
  alias LemonSim.LLM.Deciders.ToolPolicies.SingleTerminal
  alias LemonSim.LLM.Projectors.SectionedProjector
  alias LemonSim.Kernel.{Event, Runner, State, Store}

  @default_max_turns 300
  @default_max_days 30
  @empty_response_recovery_reason "Model returned an empty response after retries"
  @live_step_timeout_ms 60_000

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []), do: World.initial_world(opts)

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id =
      Keyword.get(opts, :sim_id, "vb_#{:erlang.phash2(:erlang.monotonic_time())}")

    opts = Keyword.put_new(opts, :sim_id, sim_id)
    max_days = Keyword.get(opts, :max_days, @default_max_days)

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "You are a vending machine operator. Manage your business over #{max_days} days. " <>
            "Order inventory from suppliers, dispatch your physical worker to stock " <>
            "the machine and set prices, and maximize your net worth. " <>
            "Use support tools to check your finances and inventory, then use one " <>
            "terminal action per turn."
      },
      plan_history: []
    )
  end

  @spec modules() :: map()
  def modules do
    %{
      action_space: ActionSpace,
      projector: SectionedProjector,
      decider: ToolLoopDecider,
      updater: Updater,
      decision_adapter: ExecutedCallEvents
    }
  end

  @spec projector_opts() :: keyword()
  def projector_opts, do: Projector.opts()

  @spec default_opts(keyword()) :: keyword()
  def default_opts(overrides \\ []) when is_list(overrides) do
    config = Modular.load(project_dir: File.cwd!())

    model =
      Keyword.get_lazy(overrides, :model, fn ->
        Config.resolve_configured_model!(config, "Vending Bench")
      end)

    stream_options =
      Keyword.get_lazy(overrides, :stream_options, fn ->
        %{api_key: Config.resolve_provider_api_key!(model.provider, config, "vending bench")}
      end)

    support_tool_matcher = fn tool ->
      String.starts_with?(tool.name, "memory_") or
        tool.name in ~w(read_inbox check_balance check_storage inspect_supplier_directory research_suppliers review_recent_sales create_reminder list_reminders complete_reminder send_supplier_message send_supplier_email)
    end

    projector_opts()
    |> Kernel.++(
      model: model,
      stream_options: stream_options,
      driver_max_turns: @default_max_turns,
      decision_max_turns: 4,
      persist?: true,
      terminal?: &terminal?/1,
      tool_policy: SingleTerminal,
      support_tool_matcher: support_tool_matcher,
      require_executed_call_events?: true,
      provider_min_interval_ms: %{zai: 10_000, google_gemini_cli: 5_000},
      on_before_step: &announce_turn/2,
      on_after_step: &print_step/2
    )
    |> maybe_put(:complete_fn, Keyword.get(overrides, :complete_fn))
  end

  @spec run(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    {run_opts, throttle} =
      default_opts(opts)
      |> Keyword.merge(opts)
      |> ProviderThrottle.wrap_opts()

    try do
      state =
        opts
        |> maybe_put(:model, Keyword.get(run_opts, :model))
        |> maybe_put(:physical_worker_model, Keyword.get(run_opts, :physical_worker_model))
        |> initial_state()
        |> stamp_runtime_models(run_opts)

      world = state.world

      IO.puts("Starting Vending Bench Simulation")
      IO.puts("Starting balance: $#{format_price(get(world, :bank_balance, 500.0))}")
      IO.puts("Max days: #{get(world, :max_days, 30)}")
      IO.puts("Machine: 4x3 grid (12 slots)")

      run_live_state(state, run_opts, [], [], 0)
    after
      ProviderThrottle.stop(throttle)
    end
  end

  @spec resume_from_artifacts(String.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def resume_from_artifacts(artifact_dir, opts \\ []) when is_binary(artifact_dir) do
    with {:ok, state, events, actions} <- load_live_checkpoint(artifact_dir, opts) do
      {run_opts, throttle} =
        default_opts(opts)
        |> Keyword.merge(opts)
        |> Keyword.put_new(:artifact_dir, artifact_dir)
        |> ProviderThrottle.wrap_opts()

      try do
        state = stamp_runtime_models(state, run_opts)
        world = state.world

        IO.puts("Resuming Vending Bench Simulation")
        IO.puts("Artifact dir: #{artifact_dir}")
        IO.puts("Current day: #{get(world, :day_number, 1)}/#{get(world, :max_days, 30)}")
        IO.puts("Completed turns: #{length(actions)}")

        run_live_state(state, run_opts, events, actions, length(actions))
      after
        ProviderThrottle.stop(throttle)
      end
    end
  end

  defp run_live_state(state, run_opts, events, actions, turn) do
    case run_live_collecting_artifacts(state, run_opts, events, actions, turn) do
      {:ok, final_state, events, actions, _steps} ->
        IO.puts("\nSimulation Complete!")
        print_final_state(final_state)

        if Keyword.get(run_opts, :persist?, true) do
          _ = Store.put_state(final_state)
        end

        if artifact_dir = Keyword.get(run_opts, :artifact_dir) do
          artifact_opts =
            run_opts
            |> Keyword.put(:artifact_dir, artifact_dir)
            |> Keyword.put(:artifact_report_title, "VendingBench Live Run Report")

          {:ok, artifacts} =
            Artifacts.write_run_artifacts(final_state, events, actions, artifact_opts)

          IO.puts("Artifacts written to #{Path.dirname(artifacts.final_world)}")
        end

        {:ok, final_state}

      {:error, reason} = error ->
        IO.puts("Simulation failed:")
        IO.inspect(reason)
        error
    end
  end

  defp load_live_checkpoint(artifact_dir, opts) do
    world_path = Path.join(artifact_dir, "final_world.json")
    events_path = Path.join(artifact_dir, "events.jsonl")
    actions_path = Path.join(artifact_dir, "actions.jsonl")
    scorecard_path = Path.join(artifact_dir, "scorecard.json")

    with {:ok, world} <- read_json_file(world_path),
         {:ok, scorecard} <- read_optional_json_file(scorecard_path, %{}),
         {:ok, events} <- read_event_jsonl(events_path),
         {:ok, actions} <- read_jsonl(actions_path),
         {:ok, sim_id} <- checkpoint_sim_id(opts, scorecard, artifact_dir) do
      state =
        opts
        |> Keyword.put(:sim_id, sim_id)
        |> Keyword.put(:max_days, get(world, :max_days, @default_max_days))
        |> initial_state()
        |> Map.put(:world, world)
        |> Map.put(:recent_events, Enum.take(events, -25))

      {:ok, state, events, actions}
    end
  end

  defp checkpoint_sim_id(opts, scorecard, artifact_dir) do
    sim_id =
      Keyword.get(opts, :sim_id) ||
        Map.get(scorecard, "sim_id") ||
        Map.get(scorecard, :sim_id) ||
        Path.basename(artifact_dir)

    if is_binary(sim_id) and String.trim(sim_id) != "" do
      {:ok, sim_id}
    else
      {:error, {:checkpoint_missing_sim_id, artifact_dir}}
    end
  end

  defp read_optional_json_file(path, default) do
    if File.exists?(path), do: read_json_file(path), else: {:ok, default}
  end

  defp read_json_file(path) do
    case File.read(path) do
      {:ok, body} ->
        Jason.decode(body)

      {:error, reason} ->
        {:error, {:checkpoint_read_failed, path, reason}}
    end
  end

  defp read_event_jsonl(path) do
    with {:ok, entries} <- read_jsonl(path) do
      {:ok, Enum.map(entries, &Event.new/1)}
    end
  end

  defp read_jsonl(path) do
    if File.exists?(path) do
      entries =
        path
        |> File.stream!()
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Enum.map(&Jason.decode!/1)

      {:ok, entries}
    else
      {:ok, []}
    end
  rescue
    error -> {:error, {:checkpoint_jsonl_decode_failed, path, error}}
  end

  @spec run_offline_strategy(String.t() | atom(), keyword()) ::
          {:ok, %{state: State.t(), artifacts: map(), steps: non_neg_integer()}}
          | {:error, term()}
  def run_offline_strategy(strategy, opts \\ [])
  def run_offline_strategy(strategy, opts), do: OfflineRunner.run_strategy(strategy, opts)

  @spec offline_baseline_events_for_day(map()) :: [LemonSim.Kernel.Event.t()]
  def offline_baseline_events_for_day(world), do: OfflineRunner.events_for_day(world)

  # -- Callbacks --

  defp terminal?(state) do
    status = MapHelpers.get_key(state.world, :status)
    status in ["complete", "bankrupt"]
  end

  defp stamp_runtime_models(%State{} = state, run_opts) do
    operator_model = Keyword.get(run_opts, :model, get(state.world, :operator_model))

    physical_worker_model =
      Keyword.get(
        run_opts,
        :physical_worker_model,
        get(state.world, :physical_worker_model, operator_model)
      )

    world =
      state.world
      |> Map.put(:operator_model, operator_model)
      |> Map.put(:physical_worker_model, physical_worker_model)
      |> Map.put(:runtime_models, World.runtime_models(operator_model, physical_worker_model))

    %{state | world: world}
  end

  defp run_live_collecting_artifacts(state, run_opts, events, actions, turn) do
    max_turns = Keyword.get(run_opts, :driver_max_turns, Keyword.get(run_opts, :max_turns, 50))

    cond do
      terminal?(state) ->
        {:ok, state, events, actions, turn}

      turn >= max_turns ->
        {:error, {:turn_limit_exceeded, max_turns}}

      true ->
        maybe_notify(Keyword.get(run_opts, :on_before_step), turn + 1, state)
        before_recent = state.recent_events

        case run_live_step(state, run_opts) do
          {:ok, result} ->
            maybe_notify(Keyword.get(run_opts, :on_after_step), turn + 1, result)
            appended = appended_recent_events(before_recent, result.state.recent_events)
            action = live_action_summary(turn + 1, state.world, result, appended)
            next_events = events ++ appended
            next_actions = actions ++ [action]

            maybe_persist_live_checkpoint(result.state, run_opts)
            maybe_write_live_checkpoint(result.state, next_events, next_actions, run_opts)

            run_live_collecting_artifacts(
              result.state,
              run_opts,
              next_events,
              next_actions,
              turn + 1
            )

          {:error, reason} ->
            case recover_live_step_failure(state, reason, actions, run_opts) do
              {:ok, next_state, appended, action} ->
                next_events = events ++ appended
                next_actions = actions ++ [Map.put(action, :turn, turn + 1)]

                maybe_persist_live_checkpoint(next_state, run_opts)
                maybe_write_live_checkpoint(next_state, next_events, next_actions, run_opts)

                run_live_collecting_artifacts(
                  next_state,
                  run_opts,
                  next_events,
                  next_actions,
                  turn + 1
                )

              :error ->
                {:error, {:step_failed, reason}}
            end
        end
    end
  end

  defp maybe_persist_live_checkpoint(state, run_opts) do
    if Keyword.get(run_opts, :persist?, true) do
      _ = Store.put_state(state)
    end

    :ok
  end

  defp maybe_write_live_checkpoint(state, events, actions, run_opts) do
    with artifact_dir when is_binary(artifact_dir) <- Keyword.get(run_opts, :artifact_dir),
         true <- Keyword.get(run_opts, :live_artifact_checkpoints?, true) do
      checkpoint_opts =
        run_opts
        |> Keyword.put(:artifact_dir, artifact_dir)
        |> Keyword.put(:artifact_report_title, "VendingBench Live Run Checkpoint Report")

      {:ok, _artifacts} = Artifacts.write_run_artifacts(state, events, actions, checkpoint_opts)
      IO.puts("Checkpoint artifacts written to #{artifact_dir}")
      :ok
    else
      _ -> :ok
    end
  end

  defp run_live_step(state, run_opts) do
    timeout_ms = Keyword.get(run_opts, :live_step_timeout_ms, @live_step_timeout_ms)

    if is_integer(timeout_ms) and timeout_ms > 0 do
      task = Task.async(fn -> Runner.step(state, modules(), run_opts) end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, {:live_step_timeout, timeout_ms}}
      end
    else
      Runner.step(state, modules(), run_opts)
    end
  end

  defp live_action_summary(turn, world, result, appended_events) do
    %{
      turn: turn,
      day: get(world, :day_number, 1),
      event_kinds: Enum.map(appended_events, & &1.kind),
      emitted_event_count: length(get(result, :events, [])),
      applied_event_count: length(appended_events),
      signal: inspect(get(result, :signal))
    }
  end

  defp recover_live_step_failure(state, reason, actions, run_opts) do
    with {:ok, reason_text} <- recoverable_live_step_failure(reason) do
      if live_missed_turn_autowait?(reason_text, actions, run_opts) do
        recover_live_missed_turn_autowait(state, reason_text)
      else
        recover_live_rejected_action(state, reason_text)
      end
    else
      :error -> :error
    end
  end

  defp recover_live_rejected_action(state, reason_text) do
    event = Events.action_rejected("operator", reason_text)
    before_recent = state.recent_events

    case Runner.ingest_events(state, [event], modules().updater) do
      {:ok, next_state, signal} ->
        appended = appended_recent_events(before_recent, next_state.recent_events)

        action = %{
          day: get(state.world, :day_number, 1),
          event_kinds: Enum.map(appended, & &1.kind),
          emitted_event_count: 1,
          applied_event_count: length(appended),
          signal: inspect(signal),
          rejected_reason: reason_text
        }

        {:ok, next_state, appended, action}

      {:error, _reason} ->
        :error
    end
  end

  defp recover_live_missed_turn_autowait(state, reason_text) do
    before_recent = state.recent_events

    case Runner.ingest_events(state, [Events.next_day_waited()], modules().updater) do
      {:ok, next_state, signal} ->
        appended = appended_recent_events(before_recent, next_state.recent_events)

        action = %{
          day: get(state.world, :day_number, 1),
          event_kinds: Enum.map(appended, & &1.kind),
          emitted_event_count: 1,
          applied_event_count: length(appended),
          signal: inspect(signal),
          fallback_action: "wait_for_next_day",
          fallback_reason: reason_text
        }

        {:ok, next_state, appended, action}

      {:error, _reason} ->
        :error
    end
  end

  defp live_missed_turn_autowait?(reason_text, actions, run_opts) do
    threshold =
      cond do
        reason_text == @empty_response_recovery_reason ->
          Keyword.get(run_opts, :live_empty_response_autowait_after, 1)

        String.starts_with?(reason_text, "Live model step timed out") ->
          Keyword.get(run_opts, :live_step_timeout_autowait_after, 0)

        true ->
          nil
      end

    is_integer(threshold) and threshold >= 0 and
      consecutive_rejected_actions(actions, reason_text) >= threshold
  end

  defp consecutive_rejected_actions(actions, reason_text) do
    actions
    |> Enum.reverse()
    |> Enum.reduce_while(0, fn action, count ->
      action_reason = Map.get(action, :rejected_reason) || Map.get(action, "rejected_reason")

      if action_reason == reason_text do
        {:cont, count + 1}
      else
        {:halt, count}
      end
    end)
  end

  defp recoverable_live_step_failure({:multiple_decision_tools, tool_names})
       when is_list(tool_names) do
    {:ok, "Model emitted multiple terminal tools in one turn: #{Enum.join(tool_names, ", ")}"}
  end

  defp recoverable_live_step_failure({:step_failed, reason}) do
    recoverable_live_step_failure(reason)
  end

  defp recoverable_live_step_failure({:decision_tool_must_be_last, tool_name}) do
    {:ok, "Model emitted terminal tool before support tools: #{tool_name}"}
  end

  defp recoverable_live_step_failure({:live_step_timeout, timeout_ms}) do
    {:ok, "Live model step timed out after #{timeout_ms}ms"}
  end

  defp recoverable_live_step_failure({:tool_call_required, details}) when is_map(details) do
    assistant_text =
      details
      |> Map.get(:assistant_text, Map.get(details, "assistant_text", ""))
      |> to_string()
      |> String.trim()

    reason =
      if assistant_text == "" do
        @empty_response_recovery_reason
      else
        "Model answered without choosing a terminal tool: #{String.slice(assistant_text, 0, 160)}"
      end

    {:ok, reason}
  end

  defp recoverable_live_step_failure({:max_turns_exceeded, details}) when is_map(details) do
    max_turns = Map.get(details, :max_turns) || Map.get(details, "max_turns")

    {:ok,
     "Model used too many support-tool rounds before choosing a terminal action: #{max_turns}"}
  end

  defp recoverable_live_step_failure(_reason), do: :error

  defp appended_recent_events(before_recent, after_recent) do
    max_overlap = min(length(before_recent), length(after_recent))

    overlap =
      max_overlap..0//-1
      |> Enum.find(0, fn count ->
        Enum.take(before_recent, -count) == Enum.take(after_recent, count)
      end)

    Enum.drop(after_recent, overlap)
  end

  defp maybe_notify(callback, turn, payload) when is_function(callback, 2) do
    callback.(turn, payload)
    :ok
  end

  defp maybe_notify(_callback, _turn, _payload), do: :ok

  defp announce_turn(turn, state) do
    day = get(state.world, :day_number, 1)
    time = get(state.world, :time_minutes, 540)
    hours = div(time, 60)
    mins = rem(time, 60)
    balance = get(state.world, :bank_balance, 0.0)

    IO.puts(
      "Step #{turn} | Day #{day} #{hours}:#{String.pad_leading(to_string(mins), 2, "0")} | Balance: $#{format_price(balance)}"
    )
  end

  defp print_step(_turn, %{state: next_state}) do
    day = get(next_state.world, :day_number, 1)
    balance = get(next_state.world, :bank_balance, 0.0)
    cash = get(next_state.world, :cash_in_machine, 0.0)
    worker_count = get(next_state.world, :physical_worker_run_count, 0)

    IO.puts(
      "  day=#{day} balance=$#{format_price(balance)} machine_cash=$#{format_price(cash)} worker_trips=#{worker_count}"
    )
  end

  defp print_step(_turn, _result), do: :ok

  defp print_final_state(state) do
    world = state.world
    status = get(world, :status, "unknown")
    day = get(world, :day_number, 1)

    IO.puts("Status: #{status}")
    IO.puts("Final Day: #{day}")

    performance = Performance.summarize(world)

    IO.puts("\nPerformance Summary:")
    IO.puts("  V1 Net Worth Score: $#{format_price(performance.score_modes.v1_net_worth)}")

    IO.puts("  Money Balance: $#{format_price(performance.score_modes.money_balance)}")

    IO.puts("  Lemon Operational Score: #{performance.score_modes.lemon_operational_score}")
    IO.puts("  Net Worth: $#{format_price(performance.net_worth)}")
    IO.puts("  Cash on Hand: $#{format_price(performance.cash_on_hand)}")
    IO.puts("  Cash in Machine: $#{format_price(performance.cash_in_machine)}")
    IO.puts("  Inventory Value: $#{format_price(performance.inventory_value_wholesale)}")
    IO.puts("  Units Sold: #{performance.units_sold}")
    IO.puts("  Average Margin: #{performance.average_margin}%")
    IO.puts("  Days Without Sales: #{performance.days_without_sales}")
    IO.puts("  Stockout Count: #{performance.stockout_count}")
    IO.puts("  Price Changes: #{performance.price_change_count}")
    IO.puts("  Worker Trips: #{performance.worker_trip_count}")
    IO.puts("  Coordination Failures: #{performance.coordination_failures}")
    IO.puts("  Suppliers Used: #{performance.supplier_count_used}")
    IO.puts("  Refunds Paid: $#{format_price(performance.refunds_paid)}")
    IO.puts("  Spoiled Units: #{performance.spoiled_units}")
    IO.puts("  Spoilage Loss: $#{format_price(performance.spoilage_loss)}")
    IO.puts("  Storage Overflow Units: #{performance.storage_overflow_units}")
    IO.puts("  Active Failure Modes: #{performance.active_failure_mode_count}")

    if performance.bankruptcy_day do
      IO.puts("  BANKRUPT on day #{performance.bankruptcy_day}")
    end

    starting = 500.0
    profit = performance.net_worth - starting
    IO.puts("\n  Profit: $#{format_price(profit)} (#{if profit >= 0, do: "PASS", else: "FAIL"})")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

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
