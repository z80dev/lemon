defmodule LemonSim.Examples.Legislature do
  @moduledoc """
  Legislature multi-issue negotiation and logrolling game built on LemonSim.

  A 5-7 player legislative simulation where each player represents a different
  faction/constituency negotiating over 5 bills across 3 sessions.

  Each session has five phases:
  1. **Caucus** - Private messaging and logrolling deals (max 3 per session)
  2. **Floor Debate** - Public speeches about bills (each legislator speaks once)
  3. **Amendment** - Propose amendments to bills (costs 20 political capital)
  4. **Amendment Vote** - Vote on each proposed amendment
  5. **Final Vote** - Simultaneous vote on all 5 bills (yes/no per bill)

  Win condition: Highest score after 3 sessions.
  Scoring: +10/#1, +7/#2, +5/#3, +3/#4, +1/#5 preference; +5 per passed amendment; capital 1:1.
  """

  alias LemonCore.Config.{Modular, Providers}
  alias LemonCore.MapHelpers

  alias LemonSim.Examples.Legislature.{
    ActionSpace,
    Bills,
    Performance,
    Updater
  }

  alias LemonSim.Deciders.ToolLoopDecider
  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Runner, State, Store}

  @default_max_turns 300
  @default_player_count 5

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    player_count = Keyword.get(opts, :player_count, @default_player_count)
    player_count = max(5, min(7, player_count))

    factions = Bills.factions_for(player_count)
    player_ids = Enum.map(1..player_count, &"player_#{&1}")

    players =
      Enum.into(Enum.with_index(factions), %{}, fn {faction, idx} ->
        player_id = "player_#{idx + 1}"
        ranking = Bills.preference_ranking(faction.id)

        {player_id,
         %{
           faction: faction.name,
           faction_id: faction.id,
           description: faction.description,
           preference_ranking: ranking,
           political_capital: 100,
           status: "alive"
         }}
      end)

    turn_order = player_ids

    %{
      bills: Bills.all_bills(),
      players: players,
      session: 1,
      max_sessions: 3,
      phase: "caucus",
      active_actor_id: List.first(turn_order),
      turn_order: turn_order,
      caucus_messages: Enum.into(turn_order, %{}, &{&1, []}),
      caucus_messages_sent: %{},
      message_history: [],
      floor_statements: [],
      proposed_amendments: [],
      vote_record: %{},
      scores: Enum.into(turn_order, %{}, &{&1, 0}),
      caucus_done: MapSet.new(),
      floor_debate_done: MapSet.new(),
      amendment_done: MapSet.new(),
      amendment_vote_done: MapSet.new(),
      votes_cast: MapSet.new(),
      journals: %{},
      status: "in_progress",
      winner: nil
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id =
      Keyword.get(opts, :sim_id, "legislature_#{:erlang.phash2(:erlang.monotonic_time())}")

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "Win the legislature game by accumulating the highest score across 3 sessions. " <>
            "Negotiate trades in caucus, make persuasive speeches, propose amendments, " <>
            "and vote strategically to pass bills that match your faction's preferences. " <>
            "You are the active legislator shown in world state."
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
        your_faction: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          players = get(frame.world, :players, %{})
          player_info = Map.get(players, actor_id, %{})

          %{
            id: :your_faction,
            title: "Your Faction (#{actor_id})",
            format: :json,
            content: %{
              "player_id" => actor_id,
              "faction" => get(player_info, :faction, "Unknown"),
              "description" => get(player_info, :description, ""),
              "preference_ranking" => get(player_info, :preference_ranking, []),
              "political_capital" => get(player_info, :political_capital, 0),
              "current_score" => Map.get(get(frame.world, :scores, %{}), actor_id, 0)
            }
          }
        end,
        caucus_inbox: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          inbox = get(frame.world, :caucus_messages, %{})
          my_messages = Map.get(inbox, actor_id, [])

          %{
            id: :caucus_inbox,
            title: "Your Private Messages",
            format: :json,
            content: my_messages
          }
        end,
        floor_statements: fn frame, _tools, _opts ->
          statements = get(frame.world, :floor_statements, [])
          session = get(frame.world, :session, 1)

          session_statements =
            Enum.filter(statements, fn s ->
              Map.get(s, "session", Map.get(s, :session, 1)) == session
            end)

          %{
            id: :floor_statements,
            title: "Floor Statements This Session",
            format: :json,
            content: session_statements
          }
        end,
        proposed_amendments: fn frame, _tools, _opts ->
          amendments = get(frame.world, :proposed_amendments, [])

          visible_amendments =
            Enum.map(amendments, fn a ->
              %{
                "id" => Map.get(a, :id, Map.get(a, "id")),
                "bill_id" => Map.get(a, :bill_id, Map.get(a, "bill_id")),
                "proposer_id" => Map.get(a, :proposer_id, Map.get(a, "proposer_id")),
                "amendment_text" => Map.get(a, :amendment_text, Map.get(a, "amendment_text")),
                "passed" => Map.get(a, :passed, nil)
              }
            end)

          %{
            id: :proposed_amendments,
            title: "Proposed Amendments",
            format: :json,
            content: visible_amendments
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
        LEGISLATURE RULES:
        - In the CAUCUS phase: send up to 3 private messages or trade proposals, then end_caucus.
        - Messages are private. Trade proposals offer logrolling deals (I vote X if you vote Y).
        - In FLOOR DEBATE: make_speech about one bill (optional), then end_floor_debate.
        - In AMENDMENT: optionally propose_amendment (costs 20 capital) or lobby, then end_amendment.
        - In AMENDMENT VOTE: cast_amendment_vote for each pending amendment, then end_amendment_vote.
        - In FINAL VOTE: cast_votes on all 5 bills simultaneously (yes/no for each).
        - Votes are simultaneous - your vote is secret until all have voted.
        - SCORING: +10 for top preference passing, +7/#2, +5/#3, +3/#4, +1/#5.
        - BONUS: +5 for each passed amendment you proposed. Remaining capital adds to score.
        - STRATEGY: Logrolling (trading votes) is the key mechanic. Form coalitions in caucus.
        - 3 sessions total. Highest cumulative score wins.

        ROLEPLAY:
        - You represent your FACTION shown in "Your Faction" section.
        - Your preference_ranking shows which bills matter most to your constituents.
        - Negotiate from your faction's perspective. Your constituents expect results.
        - Honor your trade deals when it serves your interests, but adapt if circumstances change.
        """
      },
      section_order: [
        :world_state,
        :your_faction,
        :caucus_inbox,
        :floor_statements,
        :proposed_amendments,
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

    player_count = length(get(state.world, :turn_order, []))
    IO.puts("Starting Legislature game with #{player_count} legislators")
    IO.puts("Bills: #{Enum.join(Bills.bill_ids(), ", ")}")

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

  # -- Visibility --

  defp visible_world(world, _actor_id) do
    bills = get(world, :bills, %{})
    players = get(world, :players, %{})
    scores = get(world, :scores, %{})

    bill_view =
      Enum.into(bills, %{}, fn {bill_id, bill} ->
        {bill_id,
         %{
           "title" => Map.get(bill, :title, Map.get(bill, "title", bill_id)),
           "status" => Map.get(bill, :status, Map.get(bill, "status", "pending")),
           "amendments_count" =>
             length(Map.get(bill, :amendments, Map.get(bill, "amendments", []))),
           "lobby_total" =>
             Map.get(bill, :lobby_support, Map.get(bill, "lobby_support", %{}))
             |> Map.values()
             |> Enum.sum()
         }}
      end)

    player_view =
      Enum.into(players, %{}, fn {id, info} ->
        {id,
         %{
           "faction" => get(info, :faction, "Unknown"),
           "political_capital" => get(info, :political_capital, 0),
           "score" => Map.get(scores, id, 0)
         }}
      end)

    %{
      "phase" => get(world, :phase, "caucus"),
      "session" => get(world, :session, 1),
      "max_sessions" => get(world, :max_sessions, 3),
      "active_player" => MapHelpers.get_key(world, :active_actor_id),
      "bills" => bill_view,
      "players" => player_view
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
    session = get(state.world, :session, 1)

    IO.puts("Step #{turn} | session=#{session} phase=#{phase} actor=#{actor_id}")
  end

  defp print_step(_turn, %{state: next_state}) do
    print_score_summary(next_state)
  end

  defp print_step(_turn, _result), do: :ok

  defp print_score_summary(state) do
    players = get(state.world, :players, %{})
    scores = get(state.world, :scores, %{})

    IO.puts("Scores:")

    players
    |> Map.keys()
    |> Enum.sort()
    |> Enum.each(fn player_id ->
      score = Map.get(scores, player_id, 0)
      player_info = Map.get(players, player_id, %{})
      faction = get(player_info, :faction, "?")
      capital = get(player_info, :political_capital, 0)
      IO.puts("  #{player_id} [#{faction}]: score=#{score} capital=#{capital}")
    end)

    IO.puts(
      "status=#{get(state.world, :status, "?")} winner=#{inspect(get(state.world, :winner, nil))}"
    )
  end

  defp print_final_state(state) do
    print_score_summary(state)

    winner = get(state.world, :winner, nil)
    session = get(state.world, :session, 1)
    performance = Performance.summarize(state.world)

    if winner do
      players = get(state.world, :players, %{})
      player_info = Map.get(players, winner, %{})
      faction = get(player_info, :faction, "Unknown")
      IO.puts("\nWinner: #{winner} (#{faction}) after #{session} sessions!")
    end

    IO.puts("\nBills passed: #{Enum.join(performance.passed_bill_ids, ", ")}")
    IO.puts("\nPerformance summary:")

    performance
    |> get(:players, %{})
    |> Enum.sort_by(fn {_player, metrics} ->
      get(metrics, :final_score, 0) * -1
    end)
    |> Enum.each(fn {player_id, metrics} ->
      IO.puts(
        "  #{player_id}#{if get(metrics, :won, false), do: " [winner]", else: ""}: " <>
          "score=#{get(metrics, :final_score, 0)} " <>
          "preferences_satisfied=#{get(metrics, :preferences_satisfied, 0)} " <>
          "messages_sent=#{get(metrics, :messages_sent, 0)} " <>
          "amendments_proposed=#{get(metrics, :amendments_proposed, 0)} " <>
          "amendments_passed=#{get(metrics, :amendments_passed, 0)}"
      )
    end)
  end

  # -- Config resolution --

  defp resolve_configured_model!(config) do
    provider = config.agent.default_provider
    model_spec = config.agent.default_model

    case resolve_model_spec(provider, model_spec) do
      %Ai.Types.Model{} = model ->
        apply_provider_base_url(model, config)

      nil ->
        raise """
        Legislature example requires a valid default model.
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
            raise "legislature sim requires an OpenAI Codex access token"
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        provider_cfg[:api_key]

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            resolve_secret_api_key(provider_cfg[:api_key_secret], value)

          {:error, reason} ->
            raise "legislature sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      true ->
        raise "legislature sim requires configured credentials for #{provider_name}"
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

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
