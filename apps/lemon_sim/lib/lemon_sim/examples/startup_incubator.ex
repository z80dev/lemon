defmodule LemonSim.Examples.StartupIncubator do
  @moduledoc """
  Startup Incubator — multi-phase resource allocation and coalition forming
  under information asymmetry, built on LemonSim.

  N Founders and M Investors compete across 5 funding rounds.  Each round has
  five phases:

  1. **Pitch** — Founders deliver public pitches (bluffing allowed).
  2. **Due Diligence** — Investors ask private questions; founders may lie.
  3. **Negotiation** — Investors make term-sheet offers; founders counter,
     accept, reject, or propose mergers with other founders.
  4. **Market Event** — Automatic random market shift alters sector
     multipliers (AI boom, fintech crackdown, etc.).
  5. **Operations** — Founders allocate cash to growth, hiring, pivot, or
     reserve; metrics update.

  Win conditions:
  - Founders: highest startup valuation at the end of round 5.
  - Investors: highest portfolio return (stake value / capital deployed).
  - Overall winner: the player with the highest absolute gain.
  """

  alias LemonCore.Config.{Modular, Providers}
  alias LemonCore.MapHelpers

  alias LemonSim.Examples.StartupIncubator.{
    ActionSpace,
    Market,
    Performance,
    Updater
  }

  alias LemonSim.Deciders.ToolLoopDecider
  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Runner, State, Store}

  @default_max_turns 300
  @default_max_rounds 5
  @default_founder_count 4
  @default_investor_count 2

  # ---------------------------------------------------------------------------
  # World construction
  # ---------------------------------------------------------------------------

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    founder_count =
      opts
      |> Keyword.get(:founder_count, @default_founder_count)
      |> max(2)
      |> min(6)

    investor_count =
      opts
      |> Keyword.get(:investor_count, @default_investor_count)
      |> max(1)
      |> min(4)

    founder_ids = Enum.map(1..founder_count, &"founder_#{&1}")
    investor_ids = Enum.map(1..investor_count, &"investor_#{&1}")

    sectors = Market.sectors()

    startups =
      Enum.into(founder_ids, %{}, fn id ->
        sector = Enum.random(sectors)

        {id,
         %{
           sector: sector,
           traction: Enum.random(5..20),
           burn_rate: 50_000,
           funding_raised: 0,
           cash_on_hand: 100_000,
           valuation: 0,
           employees: Enum.random(2..8),
           pivoted?: false
         }}
      end)

    fund_size = 5_000_000

    investors =
      Enum.into(investor_ids, %{}, fn id ->
        # Each investor has different sector preferences
        preferred = Enum.take_random(sectors, 2)

        {id,
         %{
           fund_size: fund_size,
           remaining_capital: fund_size,
           portfolio: [],
           sector_preferences: preferred,
           risk_tolerance: Enum.random(["conservative", "moderate", "aggressive"])
         }}
      end)

    founders_player_map =
      Enum.into(founder_ids, %{}, fn id ->
        startup = Map.get(startups, id, %{})

        {id,
         %{
           role: "founder",
           sector: Map.get(startup, :sector, "unknown"),
           status: "active"
         }}
      end)

    investors_player_map =
      Enum.into(investor_ids, %{}, fn id ->
        investor = Map.get(investors, id, %{})

        {id,
         %{
           role: "investor",
           sector_preferences: Map.get(investor, :sector_preferences, []),
           status: "active"
         }}
      end)

    players = Map.merge(founders_player_map, investors_player_map)

    # Turn order: founders first for pitch, then investors, interleaved
    turn_order = founder_ids ++ investor_ids

    market_conditions = Market.initial_conditions()

    # Compute initial valuations
    startups_with_valuations =
      Enum.into(startups, %{}, fn {id, startup} ->
        val = Market.compute_valuation(startup, market_conditions)
        {id, Map.put(startup, :valuation, val)}
      end)

    %{
      players: players,
      startups: startups_with_valuations,
      investors: investors,
      round: 1,
      max_rounds: Keyword.get(opts, :max_rounds, @default_max_rounds),
      phase: "pitch",
      active_actor_id: List.first(founder_ids),
      turn_order: turn_order,
      phase_done: MapSet.new(),
      term_sheets: %{},
      pending_answers: %{},
      market_conditions: market_conditions,
      market_event_log: [],
      pitch_log: [],
      question_log: [],
      deal_history: [],
      journals: %{},
      status: "in_progress",
      winner: nil,
      final_scores: %{}
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id =
      Keyword.get(
        opts,
        :sim_id,
        "startup_incubator_#{:erlang.phash2(:erlang.monotonic_time())}"
      )

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "Win the Startup Incubator. If you are a founder, build the highest-valued startup. " <>
            "If you are an investor, achieve the best portfolio return. " <>
            "Use information asymmetry, bluff in pitches, probe with due diligence, " <>
            "and negotiate aggressively. You are the active player shown in world state."
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
        your_position: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)

          %{
            id: :your_position,
            title: "Your Position (#{actor_id})",
            format: :json,
            content: private_view(frame.world, actor_id)
          }
        end,
        deal_room: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          term_sheets = get(frame.world, :term_sheets, %{})
          deal_history = get(frame.world, :deal_history, [])

          my_offers =
            term_sheets
            |> Enum.filter(fn {_key, sheet} ->
              Map.get(sheet, "founder_id") == actor_id or
                Map.get(sheet, "investor_id") == actor_id
            end)
            |> Enum.map(fn {_key, sheet} -> sheet end)

          %{
            id: :deal_room,
            title: "Deal Room",
            format: :json,
            content: %{
              "active_term_sheets" => my_offers,
              "recent_deals" => Enum.take(deal_history, -10)
            }
          }
        end,
        market_intel: fn frame, _tools, _opts ->
          market_conditions = get(frame.world, :market_conditions, %{})
          market_event_log = get(frame.world, :market_event_log, [])

          %{
            id: :market_intel,
            title: "Market Intelligence",
            format: :json,
            content: %{
              "sector_multipliers" => market_conditions,
              "recent_events" => Enum.take(market_event_log, -3)
            }
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
        STARTUP INCUBATOR RULES:
        - PITCH phase: Founders deliver public pitches (can exaggerate). Then call end_phase.
        - DUE DILIGENCE phase: Investors ask founders questions (ask_question). Founders answer questions (answer_question, can be misleading). Then call end_phase.
        - NEGOTIATION phase: Investors make term sheet offers (make_offer). Founders counter (counter_offer), accept (accept_deal), reject (reject_deal), or merge with another founder (merge_startups). Then call end_phase.
        - Market event is automatic — you cannot influence it.
        - OPERATIONS phase: Founders allocate funds to growth/hiring/pivot/reserve. Then call end_phase.
        - You MUST call end_phase to advance your turn. Do not stall.
        - Rounds: 5 total. After round 5, highest-valued startup or best portfolio return wins.

        STRATEGY NOTES:
        - Founders: Bluff your traction in pitches to attract better terms. Reveal truth selectively in due diligence.
        - Investors: Probe founders hard in due diligence before committing capital. Diversify sector exposure.
        - Merging startups combines traction and employees — useful if another founder is struggling.
        - Pivoting resets traction to 50% but lets you chase a booming sector.
        - Watch market events — sector multipliers shift every round. Time your sector allocation.
        - Deals close immediately on accept_deal — the capital flows into the startup.
        """
      },
      section_order: [
        :world_state,
        :your_position,
        :deal_room,
        :market_intel,
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

    world = state.world
    founders = world.players |> Enum.count(fn {_, p} -> get(p, :role, "founder") == "founder" end)

    investors =
      world.players |> Enum.count(fn {_, p} -> get(p, :role, "investor") == "investor" end)

    IO.puts(
      "Starting Startup Incubator: #{founders} founders, #{investors} investors, #{get(world, :max_rounds, 5)} rounds"
    )

    case Runner.run_until_terminal(state, modules(), run_opts) do
      {:ok, final_state} ->
        IO.puts("\nGame Over!")
        print_final_state(final_state)

        if Keyword.get(run_opts, :persist?, true) do
          _ = Store.put_state(final_state)
        end

        {:ok, final_state}

      {:error, reason} = error ->
        IO.puts("Game failed:")
        IO.inspect(reason)
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Visibility helpers
  # ---------------------------------------------------------------------------

  defp visible_world(world, actor_id) do
    players = get(world, :players, %{})
    startups = get(world, :startups, %{})
    investors_map = get(world, :investors, %{})
    market_conditions = get(world, :market_conditions, %{})
    actor = Map.get(players, actor_id, %{})
    actor_role = get(actor, :role, "founder")

    startup_view =
      Enum.into(startups, %{}, fn {id, startup} ->
        # Investors see public metrics; founders see their own private data
        is_self = id == actor_id

        public = %{
          "sector" => Map.get(startup, :sector, Map.get(startup, "sector", "unknown")),
          "valuation" => Map.get(startup, :valuation, Map.get(startup, "valuation", 0)),
          "employees" => Map.get(startup, :employees, Map.get(startup, "employees", 0)),
          "funding_raised" =>
            Map.get(startup, :funding_raised, Map.get(startup, "funding_raised", 0))
        }

        private_additions =
          if is_self or actor_role == "investor" do
            %{
              "traction" => Map.get(startup, :traction, Map.get(startup, "traction", 0)),
              "cash_on_hand" =>
                Map.get(startup, :cash_on_hand, Map.get(startup, "cash_on_hand", 0)),
              "burn_rate" => Map.get(startup, :burn_rate, Map.get(startup, "burn_rate", 50_000)),
              "pivoted" => Map.get(startup, :pivoted?, Map.get(startup, "pivoted?", false))
            }
          else
            %{}
          end

        {id, Map.merge(public, private_additions)}
      end)

    investor_view =
      Enum.into(investors_map, %{}, fn {id, investor} ->
        is_self = id == actor_id

        public = %{
          "portfolio_count" =>
            length(Map.get(investor, :portfolio, Map.get(investor, "portfolio", [])))
        }

        private =
          if is_self do
            %{
              "fund_size" => Map.get(investor, :fund_size, Map.get(investor, "fund_size", 0)),
              "remaining_capital" =>
                Map.get(investor, :remaining_capital, Map.get(investor, "remaining_capital", 0)),
              "sector_preferences" =>
                Map.get(
                  investor,
                  :sector_preferences,
                  Map.get(investor, "sector_preferences", [])
                ),
              "portfolio" => Map.get(investor, :portfolio, Map.get(investor, "portfolio", []))
            }
          else
            %{}
          end

        {id, Map.merge(public, private)}
      end)

    %{
      "phase" => get(world, :phase, "pitch"),
      "round" => get(world, :round, 1),
      "max_rounds" => get(world, :max_rounds, 5),
      "active_player" => MapHelpers.get_key(world, :active_actor_id),
      "startups" => startup_view,
      "investors" => investor_view,
      "market_conditions" => market_conditions,
      "status" => get(world, :status, "in_progress")
    }
  end

  defp private_view(world, actor_id) do
    players = get(world, :players, %{})
    actor = Map.get(players, actor_id, %{})
    role = get(actor, :role, "founder")

    if role == "founder" do
      startups = get(world, :startups, %{})
      startup = Map.get(startups, actor_id, %{})

      %{
        "role" => "founder",
        "sector" => Map.get(startup, :sector, Map.get(startup, "sector", "unknown")),
        "traction" => Map.get(startup, :traction, Map.get(startup, "traction", 0)),
        "employees" => Map.get(startup, :employees, Map.get(startup, "employees", 0)),
        "cash_on_hand" => Map.get(startup, :cash_on_hand, Map.get(startup, "cash_on_hand", 0)),
        "burn_rate" => Map.get(startup, :burn_rate, Map.get(startup, "burn_rate", 0)),
        "funding_raised" =>
          Map.get(startup, :funding_raised, Map.get(startup, "funding_raised", 0)),
        "valuation" => Map.get(startup, :valuation, Map.get(startup, "valuation", 0)),
        "pivoted" => Map.get(startup, :pivoted?, Map.get(startup, "pivoted?", false))
      }
    else
      investors_map = get(world, :investors, %{})
      investor = Map.get(investors_map, actor_id, %{})

      %{
        "role" => "investor",
        "fund_size" => Map.get(investor, :fund_size, Map.get(investor, "fund_size", 0)),
        "remaining_capital" =>
          Map.get(investor, :remaining_capital, Map.get(investor, "remaining_capital", 0)),
        "sector_preferences" =>
          Map.get(investor, :sector_preferences, Map.get(investor, "sector_preferences", [])),
        "risk_tolerance" =>
          Map.get(investor, :risk_tolerance, Map.get(investor, "risk_tolerance", "moderate")),
        "portfolio" => Map.get(investor, :portfolio, Map.get(investor, "portfolio", []))
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

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
    print_startup_summary(next_state)
  end

  defp print_step(_turn, _result), do: :ok

  defp print_startup_summary(state) do
    startups = get(state.world, :startups, %{})
    market_conditions = get(state.world, :market_conditions, Market.initial_conditions())

    IO.puts("Startup valuations:")

    startups
    |> Enum.reject(fn {_id, s} -> Map.get(s, :merged_into) end)
    |> Enum.sort_by(fn {_id, s} -> -Market.compute_valuation(s, market_conditions) end)
    |> Enum.each(fn {id, startup} ->
      val = Market.compute_valuation(startup, market_conditions)
      sector = Map.get(startup, :sector, Map.get(startup, "sector", "?"))
      traction = Map.get(startup, :traction, Map.get(startup, "traction", 0))
      funding = Map.get(startup, :funding_raised, Map.get(startup, "funding_raised", 0))

      IO.puts(
        "  #{id} [#{sector}]: val=$#{format_number(val)} traction=#{traction} raised=$#{format_number(funding)}"
      )
    end)

    IO.puts(
      "status=#{get(state.world, :status, "?")} winner=#{inspect(get(state.world, :winner, nil))}"
    )
  end

  defp print_final_state(state) do
    print_startup_summary(state)

    winner = get(state.world, :winner, nil)
    round = get(state.world, :round, 1)
    performance = Performance.summarize(state.world)

    if winner do
      players = get(state.world, :players, %{})
      player_info = Map.get(players, winner, %{})
      role = get(player_info, :role, "player")
      IO.puts("\nWinner: #{winner} (#{role}) after #{round - 1} rounds!")
    end

    IO.puts("\nPerformance summary:")

    performance
    |> get(:players, %{})
    |> Enum.sort_by(fn {_player, metrics} ->
      val = Map.get(metrics, :final_valuation, Map.get(metrics, :portfolio_value, 0))
      -val
    end)
    |> Enum.each(fn {player_id, metrics} ->
      won_label = if Map.get(metrics, :won, false), do: " [winner]", else: ""
      role = Map.get(metrics, :role, "founder")

      extra =
        if role == "founder" do
          "val=$#{format_number(Map.get(metrics, :final_valuation, 0))} deals=#{Map.get(metrics, :deals_closed, 0)}"
        else
          "return=#{Map.get(metrics, :return_pct, 0.0)}% portfolio=#{Map.get(metrics, :portfolio_companies, 0)}"
        end

      IO.puts("  #{player_id}#{won_label}: #{extra}")
    end)
  end

  # ---------------------------------------------------------------------------
  # Config resolution (identical to Diplomacy pattern)
  # ---------------------------------------------------------------------------

  defp resolve_configured_model!(config) do
    provider = config.agent.default_provider
    model_spec = config.agent.default_model

    case resolve_model_spec(provider, model_spec) do
      %Ai.Types.Model{} = model ->
        apply_provider_base_url(model, config)

      nil ->
        raise """
        StartupIncubator example requires a valid default model.
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
            raise "startup incubator sim requires an OpenAI Codex access token"
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        provider_cfg[:api_key]

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            resolve_secret_api_key(provider_cfg[:api_key_secret], value)

          {:error, reason} ->
            raise "startup incubator sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      true ->
        raise "startup incubator sim requires configured credentials for #{provider_name}"
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

  defp format_number(n) when is_number(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_number(n) when is_number(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 0) |> trunc()}K"
  end

  defp format_number(n) when is_number(n), do: "#{trunc(n)}"
  defp format_number(n), do: to_string(n)

  defp get(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
