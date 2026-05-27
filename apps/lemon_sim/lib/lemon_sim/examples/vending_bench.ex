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

  alias LemonCore.Config.{Modular, Providers}
  alias LemonCore.MapHelpers

  alias LemonSim.Examples.VendingBench.{
    ActionSpace,
    DecisionAdapter,
    DemandModel,
    Events,
    Performance,
    Replay,
    Suppliers,
    ToolPolicy,
    Updater
  }

  alias LemonSim.Deciders.ToolLoopDecider
  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Event, Runner, State, Store}

  @default_max_turns 300
  @default_max_days 30
  @default_starting_balance 500.0
  @default_artifact_root "apps/lemon_sim/priv/game_logs/vending_bench"
  @empty_response_recovery_reason "Model returned an empty response after retries"
  @live_step_timeout_ms 60_000
  @artifact_registry_path Path.join(
                            System.tmp_dir!(),
                            "lemon_vending_bench_artifact_registry.json"
                          )

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    max_days = Keyword.get(opts, :max_days, @default_max_days)
    seed = Keyword.get(opts, :seed, :erlang.phash2(:erlang.monotonic_time()))
    starting_balance = Keyword.get(opts, :starting_balance, @default_starting_balance)

    catalog = DemandModel.catalog()

    rows = ~w(A B C D)
    cols = ~w(1 2 3)

    slots =
      for row <- rows, col <- cols, into: %{} do
        slot_id = "#{row}#{col}"
        slot_type = if row in ~w(A B), do: "small", else: "large"
        {slot_id, %{slot_type: slot_type, item_id: nil, inventory: 0, price: nil}}
      end

    weather = DemandModel.generate_weather(1, seed)
    season = DemandModel.season_for_day(1)
    operator_model = Keyword.get(opts, :model)
    physical_worker_model = Keyword.get(opts, :physical_worker_model, operator_model)

    %{
      status: "in_progress",
      phase: "operator_turn",
      active_actor_id: "operator",
      day_number: 1,
      time_minutes: 9 * 60,
      minutes_per_day: 24 * 60,
      max_days: max_days,
      seed: seed,
      bank_balance: starting_balance,
      cash_in_machine: 0.0,
      daily_fee: 2.0,
      unpaid_fee_streak: 0,
      machine: %{
        rows: 4,
        cols: 3,
        slots: slots
      },
      storage: %{
        inventory: %{},
        batches: [],
        capacity_units: Keyword.get(opts, :storage_capacity_units, 160),
        spoiled_units: 0,
        overflow_units: 0,
        spoilage_loss: 0.0
      },
      catalog: catalog,
      supplier_directory: LemonSim.Examples.VendingBench.Suppliers.directory(),
      supplier_threads: %{},
      supplier_order_history: [],
      inbox: [],
      outbox: [],
      supplier_research_history: [],
      supplier_reply_history: [],
      supplier_incident_history: [],
      pending_deliveries: [],
      pending_refunds: [],
      reminders: [],
      customer_complaints: [],
      refunds_paid: 0.0,
      recent_sales: [],
      sales_history: [],
      weather: weather,
      season: season,
      operator_run_count: 0,
      physical_worker_run_count: 0,
      operator_model: operator_model,
      physical_worker_model: physical_worker_model,
      runtime_models: runtime_models(operator_model, physical_worker_model),
      operator_memory_namespace: "#{Keyword.get(opts, :sim_id, "vb")}/operator",
      physical_worker_memory_namespace: "#{Keyword.get(opts, :sim_id, "vb")}/physical_worker",
      physical_worker_last_report: nil,
      physical_worker_history: [],
      machine_fault_reports: [],
      price_change_count: 0,
      coordination_failures: 0,
      journals: %{}
    }
  end

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
      decision_adapter: DecisionAdapter
    }
  end

  @spec projector_opts() :: keyword()
  def projector_opts do
    [
      section_builders: %{
        business_state: fn frame, _tools, _opts ->
          world = frame.world
          day = get(world, :day_number, 1)
          max_days = get(world, :max_days, 30)
          time = get(world, :time_minutes, 540)
          hours = div(time, 60)
          mins = rem(time, 60)
          balance = get(world, :bank_balance, 0.0)
          cash = get(world, :cash_in_machine, 0.0)
          weather = get(world, :weather, %{})
          season = get(world, :season, %{})

          %{
            id: :business_state,
            title: "Business Status",
            format: :text,
            content: """
            Day #{day}/#{max_days} | Time: #{hours}:#{String.pad_leading(to_string(mins), 2, "0")}
            Bank Balance: $#{format_price(balance)}
            Cash in Machine: $#{format_price(cash)}
            Net Worth: $#{format_price(balance + cash)}
            Weather: #{Map.get(weather, :kind, "mild")} (demand x#{Map.get(weather, :demand_multiplier, 1.0)})
            Season: #{Map.get(season, :name, "spring")} (demand x#{Map.get(season, :demand_multiplier, 1.0)})
            Daily Fee: $#{format_price(get(world, :daily_fee, 2.0))}
            Unpaid Fee Streak: #{get(world, :unpaid_fee_streak, 0)}/10 (bankruptcy at 10)
            """
          }
        end,
        machine_snapshot: fn frame, _tools, _opts ->
          world = frame.world
          machine = get(world, :machine, %{})
          slots = get(machine, :slots, %{})
          catalog = get(world, :catalog, %{})

          lines =
            slots
            |> Enum.sort_by(fn {id, _} -> id end)
            |> Enum.map(fn {slot_id, slot} ->
              item_id = get(slot, :item_id)
              inv = get(slot, :inventory, 0)
              price = get(slot, :price)

              if item_id do
                item_info = Map.get(catalog, item_id, %{})
                name = Map.get(item_info, :display_name, item_id)
                "  #{slot_id}: #{name} — #{inv} units @ $#{format_price(price)}"
              else
                "  #{slot_id}: [empty]"
              end
            end)
            |> Enum.join("\n")

          %{
            id: :machine_snapshot,
            title: "Machine Slots (4x3, top rows small / bottom rows large)",
            format: :text,
            content: lines
          }
        end,
        storage_snapshot: fn frame, _tools, _opts ->
          world = frame.world
          storage = get(world, :storage, %{})
          storage_inv = get(storage, :inventory, %{})
          catalog = get(world, :catalog, %{})

          content =
            if map_size(storage_inv) == 0 do
              "  (empty — order from suppliers)"
            else
              storage_inv
              |> Enum.sort_by(fn {id, _} -> id end)
              |> Enum.map(fn {item_id, qty} ->
                item_info = Map.get(catalog, item_id, %{})
                name = Map.get(item_info, :display_name, item_id)
                "  #{name} (#{item_id}): #{qty} units"
              end)
              |> Enum.join("\n")
            end

          %{
            id: :storage_snapshot,
            title: "Storage Warehouse",
            format: :text,
            content: content
          }
        end,
        inbox: fn frame, _tools, _opts ->
          world = frame.world
          inbox = get(world, :inbox, [])

          content =
            if inbox == [] do
              "  No messages."
            else
              inbox
              |> Enum.with_index(1)
              |> Enum.map(fn {msg, i} ->
                from = get(msg, :from, "?")
                subject = get(msg, :subject, "")
                "  #{i}. From #{from}: #{subject}"
              end)
              |> Enum.join("\n")
            end

          %{
            id: :inbox,
            title: "Inbox (#{length(inbox)} messages)",
            format: :text,
            content: content
          }
        end,
        sales_summary: fn frame, _tools, _opts ->
          world = frame.world
          recent = get(world, :recent_sales, [])

          content =
            if recent == [] do
              "  No sales recorded yet."
            else
              total_rev =
                Enum.reduce(recent, 0.0, fn s, acc -> acc + get(s, :revenue, 0.0) end)

              total_units =
                Enum.reduce(recent, 0, fn s, acc -> acc + get(s, :quantity, 0) end)

              lines =
                recent
                |> Enum.take(-10)
                |> Enum.map(fn s ->
                  "  Slot #{get(s, :slot_id, "?")}: #{get(s, :quantity, 0)}x #{get(s, :item_id, "?")} — $#{format_price(get(s, :revenue, 0.0))}"
                end)
                |> Enum.join("\n")

              "Last day: #{total_units} units sold, $#{format_price(total_rev)} revenue\n#{lines}"
            end

          %{
            id: :sales_summary,
            title: "Recent Sales",
            format: :text,
            content: content
          }
        end,
        worker_status: fn frame, _tools, _opts ->
          world = frame.world
          count = get(world, :physical_worker_run_count, 0)
          last_report = get(world, :physical_worker_last_report)

          content =
            if last_report do
              "  Trips: #{count}\n  Last report: #{get(last_report, :summary, "N/A")} (day #{get(last_report, :day, "?")})"
            else
              "  Trips: #{count}\n  No visits yet."
            end

          %{
            id: :worker_status,
            title: "Physical Worker",
            format: :text,
            content: content
          }
        end,
        pending_deliveries: fn frame, _tools, _opts ->
          world = frame.world
          pending = get(world, :pending_deliveries, [])

          content =
            if pending == [] do
              "  No pending deliveries."
            else
              pending
              |> Enum.map(fn d ->
                "  #{get(d, :item_id, "?")} x#{get(d, :quantity, 0)} from #{get(d, :supplier_id, "?")} — arrives day #{get(d, :delivery_day, "?")}"
              end)
              |> Enum.join("\n")
            end

          %{
            id: :pending_deliveries,
            title: "Pending Deliveries",
            format: :text,
            content: content
          }
        end,
        reminders: fn frame, _tools, _opts ->
          reminders = get(frame.world, :reminders, [])
          day = get(frame.world, :day_number, 1)

          open_reminders =
            reminders
            |> Enum.reject(&(get(&1, :status, "open") == "done"))
            |> Enum.sort_by(fn reminder -> {get(reminder, :day, 0), get(reminder, :id, "")} end)

          content =
            if open_reminders == [] do
              "  No open reminders."
            else
              open_reminders
              |> Enum.take(10)
              |> Enum.map(fn reminder ->
                due_day = get(reminder, :day, "?")
                urgency = if is_integer(due_day) and due_day <= day, do: "due", else: "later"

                "  #{get(reminder, :id, "?")} | day #{due_day} | #{urgency}: #{get(reminder, :text, "")}"
              end)
              |> Enum.join("\n")
            end

          %{
            id: :reminders,
            title: "Open Reminders",
            format: :text,
            content: content
          }
        end,
        decision_contract: fn frame, _tools, _opts ->
          max_days = get(frame.world, :max_days, 30)

          %{
            id: :decision_contract,
            title: "Decision Contract",
            format: :markdown,
            content: """
            VENDING MACHINE OPERATOR RULES:
            - You are running a vending machine business over #{max_days} simulated days.
            - Each turn you can use SUPPORT tools (read_inbox, check_balance, supplier email, etc.) freely.
            - Do not loop on support tools. After at most 2 support tool calls, end the turn.
            - Then you must use exactly ONE TERMINAL tool to end your turn:
              * run_physical_worker — dispatch worker to stock machine, collect cash, set prices
              * wait_for_next_day — end the day and advance to tomorrow

            STRATEGY TIPS:
            - Stock the machine before waiting for the next day so sales can happen.
            - Collect cash regularly so you have funds for orders.
            - Set prices considering elasticity — higher prices reduce demand.
            - Order enough inventory but don't overspend.
            - Physical worker visits take 75 minutes and must start by 15:45 to be back by 17:00.
            - Check your inbox for delivery confirmations.
            - Use memory tools to track your strategy and supplier notes.
            - Use reminder tools for time-sensitive plans such as restocks, delayed deliveries, and follow-ups.
            - Daily fee of $2 is charged each night — maintain positive balance.
            - 5 consecutive unpaid fees = bankruptcy = game over.
            - Goal: maximize net worth and final bank money balance by day #{max_days}.
            """
          }
        end
      },
      section_order: [
        :business_state,
        :machine_snapshot,
        :storage_snapshot,
        :pending_deliveries,
        :reminders,
        :inbox,
        :sales_summary,
        :worker_status,
        :recent_events,
        :current_intent,
        :available_actions,
        :decision_contract
      ]
    ]
  end

  @spec default_opts(keyword()) :: keyword()
  def default_opts(overrides \\ []) when is_list(overrides) do
    config = Modular.load(project_dir: File.cwd!())
    model = Keyword.get_lazy(overrides, :model, fn -> resolve_configured_model!(config) end)

    stream_options =
      Keyword.get_lazy(overrides, :stream_options, fn ->
        %{api_key: resolve_provider_api_key!(model.provider, config)}
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
      tool_policy: ToolPolicy,
      support_tool_matcher: support_tool_matcher,
      provider_min_interval_ms: %{zai: 10_000, google_gemini_cli: 5_000},
      on_before_step: &announce_turn/2,
      on_after_step: &print_step/2
    )
    |> maybe_put(:complete_fn, Keyword.get(overrides, :complete_fn))
  end

  @spec run(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    run_opts =
      default_opts(opts)
      |> Keyword.merge(opts)
      |> with_provider_throttle()

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
  end

  @spec resume_from_artifacts(String.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def resume_from_artifacts(artifact_dir, opts \\ []) when is_binary(artifact_dir) do
    with {:ok, state, events, actions} <- load_live_checkpoint(artifact_dir, opts) do
      run_opts =
        default_opts(opts)
        |> Keyword.merge(opts)
        |> Keyword.put_new(:artifact_dir, artifact_dir)
        |> with_provider_throttle()

      state = stamp_runtime_models(state, run_opts)
      world = state.world

      IO.puts("Resuming Vending Bench Simulation")
      IO.puts("Artifact dir: #{artifact_dir}")
      IO.puts("Current day: #{get(world, :day_number, 1)}/#{get(world, :max_days, 30)}")
      IO.puts("Completed turns: #{length(actions)}")

      run_live_state(state, run_opts, events, actions, length(actions))
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

          {:ok, artifacts} = write_run_artifacts(final_state, events, actions, artifact_opts)
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

  def run_offline_strategy(strategy, opts) when strategy in ["baseline", :baseline] do
    sim_id =
      Keyword.get(opts, :sim_id, "vb_baseline_#{:erlang.unique_integer([:positive])}")

    state =
      opts
      |> Keyword.put(:sim_id, sim_id)
      |> Keyword.put_new(:max_days, 7)
      |> Keyword.put_new(:seed, 1)
      |> initial_state()

    max_turns = Keyword.get(opts, :driver_max_turns, Keyword.get(opts, :max_turns, 50))

    with {:ok, final_state, events, actions, steps} <-
           run_offline_baseline_loop(state, max_turns, [], [], 0),
         artifact_opts <-
           Keyword.put(opts, :artifact_report_title, "VendingBench Offline Baseline Report"),
         {:ok, artifacts} <- write_run_artifacts(final_state, events, actions, artifact_opts) do
      {:ok, %{state: final_state, artifacts: artifacts, steps: steps}}
    end
  end

  def run_offline_strategy(strategy, _opts), do: {:error, {:unknown_offline_strategy, strategy}}

  @spec offline_baseline_events_for_day(map()) :: [LemonSim.Event.t()]
  def offline_baseline_events_for_day(world), do: baseline_events_for_day(world)

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
      |> Map.put(:runtime_models, runtime_models(operator_model, physical_worker_model))

    %{state | world: world}
  end

  defp runtime_models(operator_model, physical_worker_model) do
    %{
      operator: model_descriptor(operator_model),
      physical_worker: model_descriptor(physical_worker_model)
    }
  end

  defp model_descriptor(nil), do: nil

  defp model_descriptor(%{} = model) do
    provider = get(model, :provider)
    id = get(model, :id, get(model, :name))
    label = model_label(provider, id)

    %{
      provider: model_part(provider),
      id: model_part(id),
      label: label
    }
  end

  defp model_descriptor(model),
    do: %{provider: nil, id: model_part(model), label: model_part(model)}

  defp model_label(provider, id) do
    provider = model_part(provider)
    id = model_part(id)

    cond do
      id in [nil, ""] ->
        provider

      provider in [nil, ""] ->
        id

      String.starts_with?(id, provider <> ":") ->
        id

      true ->
        provider <> ":" <> id
    end
  end

  defp model_part(nil), do: nil
  defp model_part(value) when is_atom(value), do: Atom.to_string(value)
  defp model_part(value) when is_binary(value), do: value
  defp model_part(value), do: to_string(value)

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

      {:ok, _artifacts} = write_run_artifacts(state, events, actions, checkpoint_opts)
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

  defp run_offline_baseline_loop(state, max_turns, events, actions, turn) do
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
            run_offline_baseline_loop(
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

  defp with_provider_throttle(opts) do
    provider_min_interval_ms =
      opts
      |> Keyword.get(:provider_min_interval_ms, %{})
      |> normalize_provider_intervals()

    if map_size(provider_min_interval_ms) == 0 do
      opts
    else
      {:ok, throttle_agent} = Agent.start_link(fn -> %{} end)
      base_complete_fn = Keyword.get(opts, :complete_fn, &Ai.complete/3)

      throttled_complete_fn = fn model, context, stream_options ->
        maybe_wait_for_provider(throttle_agent, model.provider, provider_min_interval_ms)
        base_complete_fn.(model, context, stream_options)
      end

      Keyword.put(opts, :complete_fn, throttled_complete_fn)
    end
  end

  defp normalize_provider_intervals(intervals) when is_map(intervals) do
    Enum.reduce(intervals, %{}, fn
      {provider, interval_ms}, acc when is_integer(interval_ms) and interval_ms > 0 ->
        Map.put(acc, normalize_provider_key(provider), interval_ms)

      _, acc ->
        acc
    end)
  end

  defp normalize_provider_intervals(_), do: %{}

  defp maybe_wait_for_provider(throttle_agent, provider, provider_min_interval_ms) do
    provider_key = normalize_provider_key(provider)

    case Map.get(provider_min_interval_ms, provider_key) do
      interval_ms when is_integer(interval_ms) and interval_ms > 0 ->
        now_ms = System.monotonic_time(:millisecond)

        wait_ms =
          Agent.get_and_update(throttle_agent, fn state ->
            next_allowed_at = Map.get(state, provider_key, now_ms)
            wait_ms = max(next_allowed_at - now_ms, 0)
            scheduled_at = max(now_ms, next_allowed_at) + interval_ms
            {wait_ms, Map.put(state, provider_key, scheduled_at)}
          end)

        if wait_ms > 0, do: Process.sleep(wait_ms)
        :ok

      _ ->
        :ok
    end
  end

  defp normalize_provider_key(provider) when is_atom(provider), do: provider

  defp normalize_provider_key(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp normalize_provider_key(provider), do: provider

  defp ingest_collecting_events(state, events, collected_events) do
    Enum.reduce_while(events, {:ok, state, collected_events}, fn event,
                                                                 {:ok, current_state, acc_events} ->
      before_recent = current_state.recent_events

      case Runner.ingest_events(current_state, [event], modules().updater) do
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

  defp write_run_artifacts(state, events, actions, opts) do
    artifact_dir =
      Keyword.get(opts, :artifact_dir) ||
        Path.join(@default_artifact_root, state.sim_id)

    File.mkdir_p!(artifact_dir)
    write_artifact_registry(state.sim_id, artifact_dir)

    performance = Performance.summarize(state.world)

    scorecard =
      performance
      |> Map.put(:sim_id, state.sim_id)
      |> Map.put(:status, get(state.world, :status))
      |> Map.put(:day_number, get(state.world, :day_number))

    paths = %{
      final_world: Path.join(artifact_dir, "final_world.json"),
      events: Path.join(artifact_dir, "events.jsonl"),
      actions: Path.join(artifact_dir, "actions.jsonl"),
      supplier_messages: Path.join(artifact_dir, "supplier_messages.json"),
      worker_history: Path.join(artifact_dir, "worker_history.json"),
      operator_transcript: Path.join(artifact_dir, "operator_transcript.json"),
      reminders: Path.join(artifact_dir, "reminders.json"),
      scorecard: Path.join(artifact_dir, "scorecard.json"),
      report: Path.join(artifact_dir, "report.md"),
      replay_json: Path.join(artifact_dir, "replay.json"),
      replay_html: Path.join(artifact_dir, "replay.html")
    }

    File.write!(paths.final_world, Jason.encode!(jsonable(state.world), pretty: true))
    File.write!(paths.scorecard, Jason.encode!(jsonable(scorecard), pretty: true))
    File.write!(paths.events, jsonl(events))
    File.write!(paths.actions, jsonl(actions))

    File.write!(
      paths.supplier_messages,
      Jason.encode!(supplier_messages_artifact(state.world), pretty: true)
    )

    File.write!(
      paths.worker_history,
      Jason.encode!(worker_history_artifact(state.world), pretty: true)
    )

    File.write!(
      paths.operator_transcript,
      Jason.encode!(operator_transcript_artifact(actions, events), pretty: true)
    )

    File.write!(
      paths.reminders,
      Jason.encode!(jsonable(get(state.world, :reminders, [])), pretty: true)
    )

    {:ok, _replay_paths} = Replay.write_browser(artifact_dir)
    File.write!(paths.report, artifact_report(state, scorecard, paths, opts))

    {:ok, paths}
  end

  defp write_artifact_registry(sim_id, artifact_dir) do
    registry =
      case File.read(@artifact_registry_path) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        _ ->
          %{}
      end

    File.write!(
      @artifact_registry_path,
      registry
      |> Map.put(sim_id, artifact_dir)
      |> Jason.encode!(pretty: true)
    )
  end

  defp artifact_report(state, scorecard, paths, opts) do
    title = Keyword.get(opts, :artifact_report_title, "VendingBench Run Report")

    """
    # #{title}

    Sim ID: #{state.sim_id}
    Status: #{get(state.world, :status)}
    Final day: #{get(state.world, :day_number)}

    ## Scores

    - V1 net worth: $#{format_price(scorecard.score_modes.v1_net_worth)}
    - Money balance: $#{format_price(scorecard.score_modes.money_balance)}
    - Lemon operational score: #{scorecard.score_modes.lemon_operational_score}

    ## Metrics

    - Units sold: #{scorecard.units_sold}
    - Average margin: #{scorecard.average_margin}%
    - Days without sales: #{scorecard.days_without_sales}
    - Stockout count: #{scorecard.stockout_count}
    - Worker trips: #{scorecard.worker_trip_count}
    - Coordination failures: #{scorecard.coordination_failures}
    - Refunds paid: $#{format_price(scorecard.refunds_paid)}
    - Customer complaints: #{scorecard.customer_complaint_count}
    - Supplier incidents: #{scorecard.supplier_incident_count}
    - Spoiled units: #{scorecard.spoiled_units}
    - Spoilage loss: $#{format_price(scorecard.spoilage_loss)}
    - Storage overflow units: #{scorecard.storage_overflow_units}
    - Active failure modes: #{scorecard.active_failure_mode_count}

    ## Artifacts

    - Final world: #{paths.final_world}
    - Events: #{paths.events}
    - Actions: #{paths.actions}
    - Supplier messages: #{paths.supplier_messages}
    - Worker history: #{paths.worker_history}
    - Operator transcript: #{paths.operator_transcript}
    - Reminders: #{paths.reminders}
    - Scorecard: #{paths.scorecard}
    - Replay JSON: #{paths.replay_json}
    - Replay browser: #{paths.replay_html}
    """
  end

  defp supplier_messages_artifact(world) do
    %{
      inbox: get(world, :inbox, []),
      outbox: get(world, :outbox, []),
      research_history: get(world, :supplier_research_history, []),
      reply_history: get(world, :supplier_reply_history, []),
      order_history: get(world, :supplier_order_history, []),
      incident_history: get(world, :supplier_incident_history, [])
    }
    |> jsonable()
  end

  defp worker_history_artifact(world) do
    %{
      run_count: get(world, :physical_worker_run_count, 0),
      last_report: get(world, :physical_worker_last_report),
      history: get(world, :physical_worker_history, [])
    }
    |> jsonable()
  end

  defp operator_transcript_artifact(actions, events) do
    %{
      action_summaries: actions,
      event_kinds: Enum.map(events, & &1.kind),
      support_event_count: Enum.count(events, &support_event?/1),
      turn_count: length(actions),
      event_count: length(events)
    }
    |> jsonable()
  end

  defp support_event?(event) do
    event.kind in [
      "operator_checked_balance",
      "operator_checked_storage",
      "operator_read_inbox",
      "operator_inspected_suppliers",
      "operator_reviewed_sales",
      "operator_researched_suppliers",
      "operator_created_reminder",
      "operator_listed_reminders",
      "operator_completed_reminder"
    ]
  end

  defp jsonl(entries) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> Jason.encode!(jsonable_artifact_entry(entry, index)) end)
    |> Enum.join("\n")
    |> then(fn
      "" -> ""
      content -> content <> "\n"
    end)
  end

  defp jsonable_artifact_entry(%{ts_ms: _} = entry, index) do
    entry
    |> jsonable()
    |> Map.put("ts_ms", index)
  end

  defp jsonable_artifact_entry(%{"ts_ms" => _} = entry, index) do
    entry
    |> jsonable()
    |> Map.put("ts_ms", index)
  end

  defp jsonable_artifact_entry(entry, _index), do: jsonable(entry)

  defp jsonable(%_{} = value), do: value |> Map.from_struct() |> jsonable()

  defp jsonable(%{} = value) do
    Enum.reduce(value, %{}, fn {key, val}, acc ->
      string_key = to_string(key)

      if is_atom(key) or not Map.has_key?(acc, string_key) do
        Map.put(acc, string_key, jsonable(val))
      else
        acc
      end
    end)
  end

  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  defp jsonable(value), do: value

  defp maybe_notify(callback, turn, payload) when is_function(callback, 2) do
    callback.(turn, payload)
    :ok
  end

  defp maybe_notify(_callback, _turn, _payload), do: :ok

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

  # -- Config resolution (copied from courtroom.ex pattern) --

  defp resolve_configured_model!(config) do
    provider = config.agent.default_provider
    model_spec = config.agent.default_model

    case resolve_model_spec(provider, model_spec) do
      %Ai.Types.Model{} = model ->
        apply_provider_base_url(model, config)

      nil ->
        raise """
        Vending Bench requires a valid default model.
        Configure [defaults].provider + [defaults].model (or [agent].default_*) in Lemon config,
        or pass an explicit model via the mix task.
        """
    end
  end

  defp resolve_model_spec(provider, model_spec) when is_binary(model_spec) do
    trimmed = String.trim(model_spec)

    cond do
      trimmed == "" ->
        nil

      String.contains?(trimmed, ":") ->
        case String.split(trimmed, ":", parts: 2) do
          [provider_name, model_id] -> lookup_model(provider_name, model_id)
          _ -> nil
        end

      String.contains?(trimmed, "/") ->
        case String.split(trimmed, "/", parts: 2) do
          [provider_name, model_id] -> lookup_model(provider_name, model_id)
          _ -> lookup_model(provider, trimmed)
        end

      true ->
        lookup_model(provider, trimmed)
    end
  end

  defp resolve_model_spec(_provider, _model_spec), do: nil

  defp lookup_model(nil, model_id), do: Ai.Models.find_by_id(model_id)
  defp lookup_model("", model_id), do: Ai.Models.find_by_id(model_id)

  defp lookup_model(provider, model_id) when is_binary(provider) and is_binary(model_id) do
    normalized = normalize_provider(provider)

    Ai.Models.get_model(normalized, model_id) ||
      Ai.Models.get_model(String.to_atom(String.trim(provider)), model_id)
  end

  defp apply_provider_base_url(%Ai.Types.Model{} = model, config) do
    provider_name = provider_name(model.provider)
    provider_cfg = Providers.get_provider(config.providers, provider_name)
    base_url = provider_cfg[:base_url]

    if is_binary(base_url) and base_url != "" and base_url != model.base_url do
      %{model | base_url: base_url}
    else
      model
    end
  end

  defp resolve_provider_api_key!(provider, config) do
    provider_name = provider_name(provider)
    provider_cfg = Providers.get_provider(config.providers, provider_name)

    cond do
      provider_name == "openai-codex" ->
        case LemonAiRuntime.Auth.OpenAICodexOAuth.resolve_access_token() do
          token when is_binary(token) and token != "" ->
            token

          _ ->
            raise "vending bench sim requires an OpenAI Codex access token"
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        provider_cfg[:api_key]

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            resolve_secret_api_key(provider_cfg[:api_key_secret], value)

          {:error, reason} ->
            raise "vending bench sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      true ->
        raise "vending bench sim requires configured credentials for #{provider_name}"
    end
  end

  @provider_aliases %{
    "gemini" => "google_gemini_cli",
    "gemini_cli" => "google_gemini_cli",
    "gemini-cli" => "google_gemini_cli",
    "openai_codex" => "openai-codex"
  }

  defp provider_name(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> canonical_provider_name()

  defp provider_name(provider) when is_binary(provider), do: canonical_provider_name(provider)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_provider(provider_name) do
    provider_name
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> canonical_provider_name()
    |> String.to_atom()
  end

  defp canonical_provider_name(provider_name) do
    normalized =
      provider_name
      |> String.trim()
      |> String.downcase()

    Map.get(@provider_aliases, normalized, normalized)
  end

  defp resolve_secret_api_key(secret_name, secret_value)
       when is_binary(secret_name) and is_binary(secret_value) do
    case LemonAiRuntime.Auth.OAuthSecretResolver.resolve_api_key_from_secret(
           secret_name,
           secret_value
         ) do
      {:ok, resolved_api_key} when is_binary(resolved_api_key) and resolved_api_key != "" ->
        resolved_api_key

      :ignore ->
        secret_value

      {:error, _reason} ->
        secret_value
    end
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
