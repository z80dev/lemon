defmodule LemonSim.Examples.TcgShop do
  @moduledoc """
  Trading card game shop simulation built on LemonSim.

  A single-operator local game store benchmark where an agent manages sealed
  product, singles, buylist collection buying, grading submissions, events,
  online orders, and volatile franchise demand across Pokemon, Yu-Gi-Oh!,
  One Piece, Dragon Ball Super, and accessories.
  """

  alias LemonCore.Config.Modular
  alias LemonCore.MapHelpers

  alias LemonSim.Examples.TcgShop.{
    ActionSpace,
    Catalog,
    OfflineRunner,
    Performance,
    Updater
  }

  alias LemonSim.Kernel.{Runner, State, Store}
  alias LemonSim.Kernel.DecisionAdapters.ExecutedCallEvents
  alias LemonSim.LLM.Deciders.ToolLoopDecider
  alias LemonSim.LLM.Deciders.ToolPolicies.SingleTerminal
  alias LemonSim.LLM.GameHelpers.{Config, ProviderThrottle}
  alias LemonSim.LLM.Projectors.SectionedProjector

  @default_max_days 14
  @default_max_turns 180
  @default_starting_balance 10_000.0

  def initial_world(opts \\ []) do
    max_days = Keyword.get(opts, :max_days, @default_max_days)
    seed = Keyword.get(opts, :seed, :erlang.phash2(:erlang.monotonic_time()))
    starting_balance = Keyword.get(opts, :starting_balance, @default_starting_balance)
    catalog = Catalog.catalog()

    inventory =
      catalog
      |> Enum.into(%{}, fn {line_id, line} ->
        starter_qty =
          case line.category do
            "sealed" -> 4
            "accessory" -> 24
            _ -> 0
          end

        {line_id, %{on_hand: starter_qty, price: line.suggested_price}}
      end)

    %{
      mode: "tcg_shop",
      status: "in_progress",
      phase: "operator_turn",
      active_actor_id: "operator",
      day_number: 1,
      max_days: max_days,
      seed: seed,
      starting_balance: starting_balance,
      bank_balance: starting_balance,
      daily_rent: Keyword.get(opts, :daily_rent, 125.0),
      reputation: 55,
      online_rating: 4.4,
      catalog: catalog,
      inventory: inventory,
      supplier_directory: supplier_directory(),
      pending_deliveries: [],
      pending_grading: [],
      singles_case: %{
        cards_on_hand: 160,
        total_market_value: 1_750.0,
        graded_cards: []
      },
      release_calendar: Catalog.release_calendar(max_days),
      market_pulses: [market_pulse(1, seed, Catalog.release_calendar(max_days))],
      customer_queue: initial_customer_queue(),
      competitor_snapshot: competitor_snapshot(1, seed),
      sales_history: [],
      buylist_history: [],
      supplier_order_history: [],
      price_history: [],
      tournament_history: [],
      grading_history: [],
      research_history: [],
      online_order_history: [],
      invalid_action_count: 0,
      journals: %{}
    }
  end

  def initial_state(opts \\ []) do
    sim_id = Keyword.get(opts, :sim_id, "tcg_#{:erlang.phash2(:erlang.monotonic_time())}")
    max_days = Keyword.get(opts, :max_days, @default_max_days)

    State.new(
      sim_id: sim_id,
      world: initial_world(Keyword.put(opts, :sim_id, sim_id)),
      intent: %{
        goal:
          "Run a realistic TCG shop for #{max_days} simulated days. " <>
            "Manage sealed product allocations, singles liquidity, buylist collection buys, " <>
            "grading submissions, weekly play events, online orders, customer trust, and cash flow. " <>
            "Maximize final net worth without wrecking reputation or cash liquidity."
      },
      plan_history: []
    )
  end

  def modules do
    %{
      action_space: ActionSpace,
      projector: SectionedProjector,
      decider: ToolLoopDecider,
      updater: Updater,
      decision_adapter: ExecutedCallEvents
    }
  end

  def projector_opts do
    [
      system_prompt: """
      You are the owner-operator of a local trading card game shop.
      Think like a real store owner: cash is finite, allocations are lumpy,
      hype can reverse, events build community, singles tie up working capital,
      grading is slow, and online customers punish bad packing.
      Use support tools for context, then take exactly one terminal action.
      """,
      section_builders: %{
        shop_state: fn frame, _tools, _opts ->
          world = frame.world

          %{
            id: :shop_state,
            title: "Shop State",
            format: :json,
            content: %{
              day: get(world, :day_number, 1),
              max_days: get(world, :max_days, @default_max_days),
              bank_balance: get(world, :bank_balance, 0.0),
              net_worth: Performance.scorecard(world).net_worth,
              reputation: get(world, :reputation, 50),
              online_rating: get(world, :online_rating, 4.3),
              pending_deliveries: get(world, :pending_deliveries, []),
              pending_grading: get(world, :pending_grading, [])
            }
          }
        end,
        inventory: fn frame, _tools, _opts ->
          %{
            id: :inventory,
            title: "Inventory",
            format: :json,
            content: visible_inventory(frame.world)
          }
        end,
        market: fn frame, _tools, _opts ->
          %{
            id: :market,
            title: "Market And Customers",
            format: :json,
            content: %{
              market_pulse: List.last(get(frame.world, :market_pulses, [])),
              release_calendar: get(frame.world, :release_calendar, []),
              customer_queue: get(frame.world, :customer_queue, []),
              competitors: get(frame.world, :competitor_snapshot, %{})
            }
          }
        end,
        scoring: fn frame, _tools, _opts ->
          %{
            id: :scoring,
            title: "Objective Scorecard",
            format: :json,
            content: Performance.scorecard(frame.world)
          }
        end
      }
    ]
  end

  def default_opts(overrides \\ []) do
    config = Modular.load(project_dir: File.cwd!())

    model =
      Keyword.get_lazy(overrides, :model, fn ->
        Config.resolve_configured_model!(config, "TCG Shop")
      end)

    stream_options =
      Keyword.get_lazy(overrides, :stream_options, fn ->
        %{api_key: Config.resolve_provider_api_key!(model.provider, config, "tcg shop")}
      end)

    projector_opts()
    |> Kernel.++(
      model: model,
      stream_options: stream_options,
      driver_max_turns: @default_max_turns,
      decision_max_turns: 4,
      persist?: true,
      terminal?: &terminal?/1,
      tool_policy: SingleTerminal,
      support_tool_matcher: &support_tool?/1,
      require_executed_call_events?: true,
      provider_min_interval_ms: %{zai: 10_000, google_gemini_cli: 5_000}
    )
    |> maybe_put(:complete_fn, Keyword.get(overrides, :complete_fn))
  end

  def support_tool?(%{name: name}) when is_binary(name) do
    String.starts_with?(name, "memory_") or
      name in ~w(tcg_check_dashboard tcg_inspect_inventory tcg_research_market tcg_review_customers)
  end

  def support_tool?(_), do: false

  def run(opts \\ []) do
    {run_opts, throttle} =
      default_opts(opts)
      |> Keyword.merge(opts)
      |> ProviderThrottle.wrap_opts()

    try do
      state =
        opts
        |> initial_state()

      case Runner.run_until_terminal(state, modules(), run_opts) do
        {:ok, final_state} ->
          if Keyword.get(run_opts, :persist?, true), do: Store.put_state(final_state)
          {:ok, final_state}

        error ->
          error
      end
    after
      ProviderThrottle.stop(throttle)
    end
  end

  def run_offline_strategy(strategy, opts \\ []) do
    OfflineRunner.run_strategy(strategy, opts)
  end

  def terminal?(%State{world: world}) do
    get(world, :status, "in_progress") in ["complete", "bankrupt"]
  end

  def supplier_directory do
    [
      %{
        id: "alliance_distribution",
        name: "Alliance Distribution",
        terms: "Net 0, normal allocation"
      },
      %{
        id: "gts_distribution",
        name: "GTS Distribution",
        terms: "Reliable Pokemon and accessories"
      },
      %{
        id: "premium_secondary",
        name: "Premium Secondary Market",
        terms: "Fast, expensive restocks"
      },
      %{id: "local_collections", name: "Local Collections", terms: "Walk-in buys and estate lots"}
    ]
  end

  def market_pulse(day, seed, calendar) do
    release =
      Enum.find(calendar, fn item -> item.day == day end) ||
        Enum.find(calendar, fn item -> abs(item.day - day) <= 1 end)

    franchises = Catalog.franchises() -- ["Accessories"]
    featured = Enum.at(franchises, rem(seed + day * 3, length(franchises)))
    buzz = 0.9 + rem(seed + day * 17, 45) / 100

    %{
      day: day,
      featured_franchise: if(release, do: release.franchise, else: featured),
      buzz_multiplier: Float.round(if(release, do: buzz + release.demand_bonus, else: buzz), 2),
      note: if(release, do: release.title, else: "#{featured} demand is moving normally")
    }
  end

  def competitor_snapshot(day, seed) do
    %{
      big_box_stock: Enum.at(["thin", "normal", "heavy"], rem(seed + day, 3)),
      nearby_lgs_price_posture:
        Enum.at(["aggressive", "msrp", "premium"], rem(seed + day * 2, 3)),
      online_spread: Enum.at(["tight", "healthy", "volatile"], rem(seed + day * 5, 3))
    }
  end

  defp visible_inventory(world) do
    catalog = get(world, :catalog, %{})

    world
    |> get(:inventory, %{})
    |> Enum.map(fn {line_id, item} ->
      line = Map.get(catalog, line_id, %{})

      %{
        line_id: line_id,
        name: get(line, :name, line_id),
        franchise: get(line, :franchise, "Unknown"),
        on_hand: get(item, :on_hand, 0),
        price: get(item, :price, 0.0),
        market_price: get(line, :market_price, 0.0)
      }
    end)
    |> Enum.sort_by(& &1.line_id)
  end

  defp initial_customer_queue do
    [
      %{type: "player", need: "Pokemon sealed for weekend league", urgency: "high"},
      %{type: "collector", need: "clean One Piece chase singles", urgency: "medium"},
      %{type: "parent", need: "starter-friendly accessories", urgency: "medium"},
      %{type: "competitive", need: "Yu-Gi-Oh! staples after regional results", urgency: "high"}
    ]
  end

  defp get(map, key, default) do
    MapHelpers.get_key(map, key) || default
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
