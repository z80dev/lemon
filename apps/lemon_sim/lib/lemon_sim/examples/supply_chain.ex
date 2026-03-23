defmodule LemonSim.Examples.SupplyChain do
  @moduledoc """
  Supply Chain coordination game built on LemonSim.

  A 4-agent linear supply chain simulation that explores the bullwhip effect
  and multi-tier demand forecasting under information asymmetry.

  Each round has five phases (four are automated after the order phase):
  1. **Observe** - Each tier checks inventory, incoming orders, pending deliveries
  2. **Communicate** - Each tier can send one message to an adjacent tier (optional)
  3. **Order** - Each tier places an order to their upstream supplier
  4. **Fulfill** - Orders are fulfilled from inventory (automated, partial fulfills possible)
  5. **Accounting** - Costs assessed: holding + stockout + ordering (automated)

  Win condition: Lowest total cost across all 20 rounds.
  Team bonus if total supply chain cost stays below the threshold.

  ## Information Asymmetry

  - Retailer sees consumer demand directly; no one else does
  - Each tier sees only their own inventory and orders from downstream
  - Communication can be truthful or misleading (agents choose)
  """

  alias LemonCore.Config.{Modular, Providers}
  alias LemonCore.MapHelpers

  alias LemonSim.Examples.SupplyChain.{
    ActionSpace,
    DemandModel,
    Performance,
    Updater
  }

  alias LemonSim.Deciders.ToolLoopDecider
  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Runner, State, Store}

  @default_max_turns 300
  @default_max_rounds 20
  @delivery_delay 2
  @initial_inventory 20

  @tier_order ["retailer", "distributor", "factory", "raw_materials"]
  @tier_roles %{
    "retailer" => "Retailer (sells to end consumers)",
    "distributor" => "Distributor (warehouses and distributes)",
    "factory" => "Factory (converts raw materials to finished goods)",
    "raw_materials" => "Raw Materials Supplier (produces raw materials)"
  }

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    max_rounds = Keyword.get(opts, :max_rounds, @default_max_rounds)
    demand_seed = Keyword.get(opts, :demand_seed, :erlang.phash2(:erlang.monotonic_time()))

    tiers =
      @tier_order
      |> Enum.into(%{}, fn tier_id ->
        {tier_id,
         %{
           role: Map.get(@tier_roles, tier_id, tier_id),
           inventory: @initial_inventory,
           backlog: 0,
           pending_order: 0,
           incoming_deliveries: [],
           cash: 0.0,
           total_cost: 0.0,
           safety_stock: 5,
           order_history: [],
           cost_history: [],
           orders_received: 0,
           orders_fulfilled: 0,
           order_placed_this_round: false
         }}
      end)

    %{
      tiers: tiers,
      phase: "observe",
      round: 1,
      max_rounds: max_rounds,
      active_actor_id: List.first(@tier_order),
      observe_done: MapSet.new(),
      communicate_done: MapSet.new(),
      order_done: MapSet.new(),
      messages: Enum.into(@tier_order, %{}, &{&1, []}),
      message_log: [],
      consumer_demand: 0,
      demand_history: [],
      demand_seed: demand_seed,
      costs: DemandModel.default_costs(),
      cost_threshold: DemandModel.team_bonus_threshold(),
      delivery_delay: @delivery_delay,
      journals: %{},
      status: "in_progress",
      winner: nil,
      team_bonus: false,
      total_chain_cost: nil
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id =
      Keyword.get(opts, :sim_id, "supply_chain_#{:erlang.phash2(:erlang.monotonic_time())}")

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "Minimize your total cost in the supply chain. " <>
            "Balance holding costs (excess inventory) against stockout penalties (unfilled orders). " <>
            "Coordinate with adjacent tiers to reduce the bullwhip effect. " <>
            "You are the active tier shown in world state."
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
      updater: Updater
    }
  end

  @spec projector_opts() :: keyword()
  def projector_opts do
    [
      section_builders: %{
        world_state: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)

          %{
            id: :world_state,
            title: "World State",
            format: :json,
            content: visible_world(frame.world, actor_id)
          }
        end,
        your_tier: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          tiers = get(frame.world, :tiers, %{})
          tier = Map.get(tiers, actor_id, %{})
          costs = get(frame.world, :costs, DemandModel.default_costs())
          round = get(frame.world, :round, 1)

          incoming = get(tier, :incoming_deliveries, [])

          incoming_summary =
            Enum.map(incoming, fn d ->
              %{
                "from" => get(d, :from, get(d, "from", "?")),
                "quantity" => get(d, :quantity, get(d, "quantity", 0)),
                "arrives_round" => get(d, :arrive_round, get(d, "arrive_round", "?"))
              }
            end)

          order_history = get(tier, :order_history, [])
          recent_orders = Enum.take(order_history, -5)

          # Messages received this round
          all_messages = get(frame.world, :messages, %{})
          my_messages = Map.get(all_messages, actor_id, [])

          recent_msgs =
            Enum.filter(my_messages, fn m -> get(m, "round", get(m, :round, 0)) == round end)

          %{
            id: :your_tier,
            title: "Your Tier (#{actor_id})",
            format: :json,
            content: %{
              "tier_id" => actor_id,
              "role" => get(tier, :role, actor_id),
              "inventory" => get(tier, :inventory, 0),
              "backlog" => get(tier, :backlog, 0),
              "safety_stock_target" => get(tier, :safety_stock, 0),
              "incoming_deliveries" => incoming_summary,
              "total_incoming" =>
                Enum.sum(Enum.map(incoming, fn d -> get(d, :quantity, get(d, "quantity", 0)) end)),
              "total_cost_so_far" => get(tier, :total_cost, 0.0),
              "orders_received" => get(tier, :orders_received, 0),
              "orders_fulfilled" => get(tier, :orders_fulfilled, 0),
              "fill_rate" =>
                fill_rate_pct(get(tier, :orders_fulfilled, 0), get(tier, :orders_received, 0)),
              "recent_orders" => recent_orders,
              "messages_received_this_round" => recent_msgs,
              "holding_cost_per_unit" => get(costs, :holding_cost_per_unit, 0.5),
              "stockout_penalty_per_unit" => get(costs, :stockout_penalty_per_unit, 2.0)
            }
          }
        end,
        demand_context: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          demand_history = get(frame.world, :demand_history, [])
          consumer_demand = get(frame.world, :consumer_demand, 0)
          tiers = get(frame.world, :tiers, %{})

          # Retailer sees current consumer demand; others only see aggregates
          demand_info =
            if actor_id == "retailer" do
              %{
                "current_consumer_demand" => consumer_demand,
                "demand_last_5_rounds" => Enum.take(demand_history, -5),
                "avg_demand" => avg_demand(demand_history)
              }
            else
              %{
                "note" =>
                  "You cannot observe end consumer demand directly. Infer from retailer communication.",
                "demand_avg_visible_from_comms" => nil
              }
            end

          %{
            id: :demand_context,
            title: "Demand Information",
            format: :json,
            content: demand_info
          }
        end,
        recent_events: fn frame, _tools, _opts ->
          %{
            id: :recent_events,
            title: "Recent Events",
            format: :json,
            content: Enum.take(frame.recent_events, -15)
          }
        end
      },
      section_overrides: %{
        decision_contract: """
        SUPPLY CHAIN RULES:
        - In the OBSERVE phase: call check_inventory to see your stats and advance.
        - In the COMMUNICATE phase: optionally send a forecast or request info from an adjacent tier, then end_communicate.
          - You can only communicate with your direct upstream or downstream neighbor.
          - Communication is NOT verified — you may share accurate or misleading information.
        - In the ORDER phase: call place_order to set your order quantity, then the round resolves automatically.
          - Orders take 2 rounds to arrive (delivery_delay = 2).
          - Raw materials tier produces what it orders (no upstream supplier).
          - Expedite orders arrive in 1 round but cost 3x extra per unit.

        COST STRUCTURE:
        - Holding cost: 0.5 per unit in inventory per round (avoid excess stock)
        - Stockout penalty: 2.0 per unfilled unit per round (avoid running out)
        - Order cost: 1.0 per order placed
        - Expedite surcharge: 3.0 per unit expedited

        STRATEGY - THE BULLWHIP EFFECT:
        - The bullwhip effect: small demand fluctuations amplify as you move upstream.
        - Overordering creates massive inventory swings and wasted holding cost.
        - Underordering triggers stockouts that cascade downstream.
        - Optimal strategy: order close to what downstream actually needs, not what you fear.
        - Use safety stock targets to reduce panic ordering during demand spikes.
        - Share honest forecasts to reduce information asymmetry.

        WIN CONDITION:
        - Individual winner: tier with lowest total cost after 20 rounds.
        - Team bonus: if total supply chain cost < 600, all tiers earn a team bonus.
        - You MUST call check_inventory (observe), end_communicate, or place_order to finish your turn.
        """
      },
      section_order: [
        :world_state,
        :your_tier,
        :demand_context,
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

    projector_opts()
    |> Kernel.++(
      model: model,
      stream_options: stream_options,
      driver_max_turns: @default_max_turns,
      persist?: true,
      terminal?: &terminal?/1,
      on_before_step: &announce_turn/2,
      on_after_step: &print_step/2
    )
    |> maybe_put(:complete_fn, Keyword.get(overrides, :complete_fn))
  end

  @spec run(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    state = initial_state(opts)

    run_opts =
      default_opts(opts)
      |> Keyword.merge(opts)

    IO.puts("Starting Supply Chain simulation")
    IO.puts("Tiers: #{Enum.join(@tier_order, " -> ")} -> Consumers")

    IO.puts(
      "Rounds: #{get(state.world, :max_rounds, @default_max_rounds)} | Delivery delay: #{@delivery_delay} rounds"
    )

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

  # -- Visibility --

  defp visible_world(world, actor_id) do
    tiers = get(world, :tiers, %{})
    round = get(world, :round, 1)
    max_rounds = get(world, :max_rounds, @default_max_rounds)
    phase = get(world, :phase, "observe")

    # Each tier only sees high-level info about others (not their inventories)
    tier_view =
      Enum.into(@tier_order, %{}, fn tier_id ->
        tier = Map.get(tiers, tier_id, %{})

        if tier_id == actor_id do
          {tier_id, "your_tier_details_in_your_tier_section"}
        else
          {tier_id,
           %{
             "role" => get(tier, :role, tier_id),
             "visible_to_you" => false,
             "note" => "You cannot observe this tier's inventory directly"
           }}
        end
      end)

    %{
      "phase" => phase,
      "round" => round,
      "max_rounds" => max_rounds,
      "active_tier" => MapHelpers.get_key(world, :active_actor_id),
      "tiers" => tier_view,
      "delivery_delay_rounds" => get(world, :delivery_delay, @delivery_delay),
      "status" => get(world, :status, "in_progress"),
      "winner" => get(world, :winner, nil)
    }
  end

  # -- Callbacks --

  defp terminal?(state) do
    status = MapHelpers.get_key(state.world, :status)
    status == "won"
  end

  defp announce_turn(turn, state) do
    actor_id = MapHelpers.get_key(state.world, :active_actor_id)
    phase = get(state.world, :phase, "?")
    round = get(state.world, :round, 1)

    IO.puts("Step #{turn} | round=#{round} phase=#{phase} actor=#{actor_id}")
  end

  defp print_step(_turn, %{state: next_state}) do
    print_tier_summary(next_state)
  end

  defp print_step(_turn, _result), do: :ok

  defp print_tier_summary(state) do
    tiers = get(state.world, :tiers, %{})

    IO.puts("Tier status:")

    Enum.each(@tier_order, fn tier_id ->
      tier = Map.get(tiers, tier_id, %{})
      inv = get(tier, :inventory, 0)
      backlog = get(tier, :backlog, 0)
      cost = get(tier, :total_cost, 0.0)

      IO.puts(
        "  #{tier_id}: inventory=#{inv} backlog=#{backlog} total_cost=#{Float.round(cost, 1)}"
      )
    end)

    IO.puts(
      "status=#{get(state.world, :status, "?")} winner=#{inspect(get(state.world, :winner, nil))}"
    )
  end

  defp print_final_state(state) do
    print_tier_summary(state)

    winner = get(state.world, :winner, nil)
    round = get(state.world, :round, 1)
    team_bonus = get(state.world, :team_bonus, false)
    total_chain_cost = get(state.world, :total_chain_cost, nil)
    performance = Performance.summarize(state.world)

    if winner do
      IO.puts("\nWinner: #{winner} after #{round - 1} rounds!")
    end

    if team_bonus do
      IO.puts("Team bonus earned! Supply chain cost stayed below threshold.")
    end

    if total_chain_cost do
      IO.puts("Total chain cost: $#{Float.round(total_chain_cost, 2)}")
    end

    IO.puts("\nPerformance summary:")

    performance
    |> get(:tiers, %{})
    |> Enum.sort_by(fn {_tier, metrics} -> get(metrics, :total_cost, 999_999.0) end)
    |> Enum.each(fn {tier_id, metrics} ->
      IO.puts(
        "  #{tier_id}#{if get(metrics, :won, false), do: " [winner]", else: ""}: " <>
          "total_cost=#{get(metrics, :total_cost, 0.0)} " <>
          "fill_rate=#{get(metrics, :fill_rate, 0.0)} " <>
          "messages_sent=#{get(metrics, :messages_sent, 0)} " <>
          "bullwhip=#{inspect(get(metrics, :bullwhip_ratio, nil))}"
      )
    end)
  end

  # -- Helpers --

  defp fill_rate_pct(_fulfilled, 0), do: "N/A"

  defp fill_rate_pct(fulfilled, received) do
    pct = Float.round(fulfilled / received * 100, 1)
    "#{pct}%"
  end

  defp avg_demand([]), do: nil
  defp avg_demand(history), do: Float.round(Enum.sum(history) / length(history), 1)

  # -- Config resolution --

  defp resolve_configured_model!(config) do
    provider = config.agent.default_provider
    model_spec = config.agent.default_model

    case resolve_model_spec(provider, model_spec) do
      %Ai.Types.Model{} = model ->
        apply_provider_base_url(model, config)

      nil ->
        raise """
        Supply Chain example requires a valid default model.
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
            raise "supply chain sim requires an OpenAI Codex access token"
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        provider_cfg[:api_key]

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            resolve_secret_api_key(provider_cfg[:api_key_secret], value)

          {:error, reason} ->
            raise "supply chain sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      true ->
        raise "supply chain sim requires configured credentials for #{provider_name}"
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

  defp get(map, key, default)

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
