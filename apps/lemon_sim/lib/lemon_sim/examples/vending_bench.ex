defmodule LemonSim.Examples.VendingBench do
  @moduledoc """
  Vending Bench simulation built on LemonSim.

  A single-operator vending machine business sim where an AI operator manages
  finances, orders from suppliers, and dispatches a physical worker subagent
  for on-site machine tasks (stocking, pricing, cash collection) over 30
  simulated days.

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
    Performance,
    ToolPolicy,
    Updater
  }

  alias LemonSim.Deciders.ToolLoopDecider
  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Runner, State, Store}

  @default_max_turns 300
  @default_max_days 30
  @default_starting_balance 500.0

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    max_days = Keyword.get(opts, :max_days, @default_max_days)
    seed = Keyword.get(opts, :seed, :erlang.phash2(:erlang.monotonic_time()))
    starting_balance = Keyword.get(opts, :starting_balance, @default_starting_balance)

    catalog = DemandModel.catalog()

    # Build 4x3 machine grid (A1-D3), all empty
    rows = ~w(A B C D)
    cols = ~w(1 2 3)

    slots =
      for row <- rows, col <- cols, into: %{} do
        slot_id = "#{row}#{col}"
        {slot_id, %{slot_type: "small", item_id: nil, inventory: 0, price: nil}}
      end

    weather = DemandModel.generate_weather(1, seed)
    season = DemandModel.season_for_day(1)

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
        inventory: %{}
      },
      catalog: catalog,
      supplier_directory: LemonSim.Examples.VendingBench.Suppliers.directory(),
      supplier_threads: %{},
      supplier_order_history: [],
      inbox: [],
      pending_deliveries: [],
      pending_refunds: [],
      customer_complaints: [],
      recent_sales: [],
      sales_history: [],
      weather: weather,
      season: season,
      operator_run_count: 0,
      physical_worker_run_count: 0,
      operator_model: Keyword.get(opts, :model),
      physical_worker_model: Keyword.get(opts, :physical_worker_model, Keyword.get(opts, :model)),
      operator_memory_namespace: "#{Keyword.get(opts, :sim_id, "vb")}/operator",
      physical_worker_memory_namespace: "#{Keyword.get(opts, :sim_id, "vb")}/physical_worker",
      physical_worker_last_report: nil,
      physical_worker_history: [],
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

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "You are a vending machine operator. Manage your business over 30 days. " <>
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
            Unpaid Fee Streak: #{get(world, :unpaid_fee_streak, 0)}/#{5} (bankruptcy at 5)
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
            title: "Machine Slots (4x3)",
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
        end
      },
      section_overrides: %{
        decision_contract: """
        VENDING MACHINE OPERATOR RULES:
        - You are running a vending machine business over 30 simulated days.
        - Each turn you can use SUPPORT tools (read_inbox, check_balance, etc.) freely.
        - Then you must use exactly ONE TERMINAL tool to end your turn:
          * send_supplier_email — order inventory from a supplier
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
        - Daily fee of $2 is charged each night — maintain positive balance.
        - 5 consecutive unpaid fees = bankruptcy = game over.
        - Goal: maximize net worth (bank + cash in machine + inventory value) by day 30.
        """
      },
      section_order: [
        :business_state,
        :machine_snapshot,
        :storage_snapshot,
        :pending_deliveries,
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
        tool.name in ~w(read_inbox check_balance check_storage inspect_supplier_directory review_recent_sales)
    end

    projector_opts()
    |> Kernel.++(
      model: model,
      stream_options: stream_options,
      driver_max_turns: @default_max_turns,
      persist?: true,
      terminal?: &terminal?/1,
      tool_policy: ToolPolicy,
      support_tool_matcher: support_tool_matcher,
      on_before_step: &announce_turn/2,
      on_after_step: &print_step/2
    )
    |> maybe_put(:complete_fn, Keyword.get(overrides, :complete_fn))
  end

  @spec run(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    state = initial_state(opts)
    world = state.world

    run_opts =
      default_opts(opts)
      |> Keyword.merge(opts)

    IO.puts("Starting Vending Bench Simulation")
    IO.puts("Starting balance: $#{format_price(get(world, :bank_balance, 500.0))}")
    IO.puts("Max days: #{get(world, :max_days, 30)}")
    IO.puts("Machine: 4x3 grid (12 slots)")

    case Runner.run_until_terminal(state, modules(), run_opts) do
      {:ok, final_state} ->
        IO.puts("\nSimulation Complete!")
        print_final_state(final_state)

        if Keyword.get(run_opts, :persist?, true) do
          _ = Store.put_state(final_state)
        end

        {:ok, final_state}

      {:error, reason} = error ->
        IO.puts("Simulation failed:")
        IO.inspect(reason)
        error
    end
  end

  # -- Callbacks --

  defp terminal?(state) do
    status = MapHelpers.get_key(state.world, :status)
    status in ["complete", "bankrupt"]
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
    case LemonAiRuntime.Auth.OAuthSecretResolver.resolve_api_key_from_secret(secret_name, secret_value) do
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
