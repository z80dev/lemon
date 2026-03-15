defmodule LemonSim.Examples.Survivor do
  @moduledoc """
  Survivor / Tribal Council social strategy game built on LemonSim.

  A multiplayer game (6-8 players) split into tribes, competing in challenges,
  forming alliances through whispers, and voting to eliminate opponents at
  tribal council. Post-merge, eliminated players join the jury and ultimately
  decide the winner at Final Tribal Council.

  ## Phases (per episode)
  1. **Challenge** - Players pick a strategy (physical/puzzle/endurance).
     Resolution determines which tribe wins immunity (or individual post-merge).
  2. **Strategy** - Losing tribe (or all post-merge) make statements and whispers.
  3. **Tribal Council** - Idol decisions, then voting to eliminate.
  4. **Final Tribal Council** - When 3 remain, jury questions finalists and votes for a winner.

  ## Key Mechanics
  - **Tribes:** Pre-merge two tribes compete. Post-merge (~5-6 alive), individual game.
  - **Hidden Immunity Idol:** One player starts with an idol; can negate votes once.
  - **Whisper Graph:** Who whispered to whom is public; content is private.
  - **Jury:** Post-merge eliminations join the jury; jury votes for the winner.
  """

  import LemonSim.GameHelpers
  import LemonSim.GameHelpers.EventHelpers

  alias LemonSim.GameHelpers.Runner, as: GameRunner
  alias LemonSim.Deciders.ToolLoopDecider

  alias LemonSim.Examples.Survivor.{
    ActionSpace,
    Performance,
    Tribes,
    Updater
  }

  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.State

  @default_max_turns 400
  @default_player_count 8

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    player_count = Keyword.get(opts, :player_count, @default_player_count)
    player_names = Tribes.player_names(player_count)
    {players, tribes} = Tribes.assign_tribes(player_names)

    # Assign personality traits and backstory connections
    traits = Tribes.assign_traits(player_names)
    connections = Tribes.generate_connections(player_names)

    # Add traits to player maps
    players =
      Enum.into(players, %{}, fn {name, info} ->
        {name, Map.put(info, :traits, Map.get(traits, name, []))}
      end)

    challenge_order = Tribes.challenge_turn_order(players)
    first_actor = List.first(challenge_order)

    %{
      players: players,
      tribes: tribes,
      phase: "challenge",
      episode: 1,
      merged: false,
      merge_tribe_name: Tribes.merge_tribe_name(),
      active_actor_id: first_actor,
      turn_order: challenge_order,
      challenge_choices: %{},
      challenge_winner: nil,
      challenge_history: [],
      losing_tribe: nil,
      immune_player: nil,
      whisper_log: [],
      whisper_history: [],
      whisper_graph: [],
      statements: [],
      strategy_actions: %{},
      votes: %{},
      vote_history: [],
      idol_played_by: nil,
      idol_history: [],
      idol_phase_done: false,
      idol_turn_order: [],
      tc_voters: [],
      elimination_log: [],
      jury: [],
      jury_votes: %{},
      jury_statements: [],
      ftc_sub_phase: nil,
      status: "in_progress",
      winner: nil,
      # Personality & backstory
      traits: traits,
      connections: connections,
      # Internal journals
      journals: %{}
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id =
      Keyword.get(opts, :sim_id, "survivor_#{:erlang.phash2(:erlang.monotonic_time())}")

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "Play Survivor strategically. Form alliances, win challenges, and navigate tribal council. " <>
            "Balance being strategic with maintaining jury goodwill -- the jury decides the winner. " <>
            "Whisper to build alliances, but be aware others can see who you talk to."
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
          world = frame.world
          actor_id = get(world, :active_actor_id)

          %{
            id: :world_state,
            title: "Game State",
            format: :json,
            content: build_player_view(world, actor_id)
          }
        end,
        player_info: fn frame, _tools, _opts ->
          world = frame.world
          actor_id = get(world, :active_actor_id)
          players = get(world, :players, %{})
          actor = Map.get(players, actor_id, %{})

          # Build trait descriptions for this player
          actor_traits = get(actor, :traits, [])

          trait_guidance =
            actor_traits
            |> Enum.map(&Tribes.trait_description/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.join(" ")

          # Build connections for this player
          connections = get(world, :connections, [])
          my_connections = Tribes.connections_for_player(connections, actor_id)

          connection_info =
            Enum.map(my_connections, fn conn ->
              other =
                conn
                |> Map.get(:players, [])
                |> Enum.find(&(&1 != actor_id))

              %{
                "other_player" => other,
                "type" => Map.get(conn, :type),
                "description" => Map.get(conn, :description)
              }
            end)

          # Build journal entries
          journals = get(world, :journals, %{})
          my_journal = Map.get(journals, actor_id, [])

          base_info = build_player_info(world, actor_id, actor)

          enriched_info =
            base_info
            |> Map.put("your_traits", actor_traits)
            |> Map.put("trait_guidance", trait_guidance)
            |> Map.put("your_connections", connection_info)
            |> Map.put("your_journal", Enum.take(my_journal, -10))

          %{
            id: :player_info,
            title: "Your Player Info (some info is private to you)",
            format: :json,
            content: enriched_info
          }
        end,
        social_graph: fn frame, _tools, _opts ->
          world = frame.world
          actor_id = get(world, :active_actor_id)
          whisper_graph = get(world, :whisper_graph, [])
          statements = get(world, :statements, [])

          %{
            id: :social_graph,
            title: "Social Graph & Statements",
            format: :json,
            content: %{
              "public_whisper_graph" =>
                Enum.map(whisper_graph, fn entry ->
                  %{"from" => get(entry, :from), "to" => get(entry, :to)}
                end),
              "public_statements" =>
                Enum.map(statements, fn entry ->
                  %{"player" => get(entry, :player), "statement" => get(entry, :statement)}
                end),
              "your_whispers" => build_private_whispers(world, actor_id)
            }
          }
        end,
        recent_events: fn frame, _tools, _opts ->
          actor_id = get(frame.world, :active_actor_id)

          filtered =
            frame.recent_events
            |> Enum.take(-20)
            |> Enum.filter(&event_visible?(&1, actor_id))
            |> Enum.map(&sanitize_event(&1, actor_id))

          %{
            id: :recent_events,
            title: "Recent Events",
            format: :json,
            content: filtered
          }
        end
      },
      section_overrides: %{
        decision_contract: """
        SURVIVOR GAME RULES:
        - You are a contestant on Survivor, playing for the title of Sole Survivor.
        - Use exactly one tool call per turn.
        - During CHALLENGE: Choose a strategy (physical/puzzle/endurance). Your tribe (or you individually post-merge) competes.
        - During STRATEGY: Make a public statement AND send a private whisper. Build alliances, sow distrust, or stay under the radar.
        - During TRIBAL COUNCIL: First decide whether to play your Hidden Immunity Idol (if you have one), then vote to eliminate someone.
        - During FINAL TRIBAL COUNCIL: Jury members make statements and vote for a winner. Finalists make their case.
        - IMPORTANT: The whisper GRAPH is public (everyone sees who talks to whom), but whisper CONTENT is private.
        - IMPORTANT: Post-merge eliminated players become jury members who vote for the winner. Don't burn bridges unnecessarily.
        - Think about both short-term survival and long-term jury management.
        - PERSONALITY: You have a personality. Stay in character based on your traits. Let them influence how you speak, strategize, and react.
        - CONNECTIONS: You have connections with other players that may influence your decisions. Use them to your advantage or navigate around them.
        - JOURNAL: Use the optional "thought" field in any tool to record private observations. These persist across episodes.
        - Use player names when referring to other players in discussion and tool calls.
        """
      },
      section_order: [
        :world_state,
        :player_info,
        :social_graph,
        :recent_events,
        :current_intent,
        :available_actions,
        :decision_contract
      ]
    ]
  end

  @spec default_opts(keyword()) :: keyword()
  def default_opts(overrides \\ []) when is_list(overrides) do
    GameRunner.build_default_opts(projector_opts(), overrides,
      game_name: "survivor",
      max_turns: @default_max_turns,
      terminal?: &terminal?/1,
      on_before_step: &announce_turn/2,
      on_after_step: &print_step/2
    )
  end

  @spec run(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    state = initial_state(opts)

    GameRunner.run(state, modules(), &default_opts/1, opts,
      print_setup: fn s ->
        IO.puts("Starting Survivor game with #{map_size(get(s.world, :players, %{}))} players")
        print_tribe_assignments(s.world)
      end,
      print_result: &print_game_result/1
    )
  end

  @doc """
  Runs a Survivor game with different models assigned to different players.

  ## Options
    * `:model_assignments` - map of player_id => {%Model{}, api_key_string}
    * `:transcript_path` - path to write JSONL transcript
    * All other opts from `run/1`
  """
  @spec run_multi_model(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run_multi_model(opts \\ []) when is_list(opts) do
    model_assignments = Keyword.fetch!(opts, :model_assignments)
    state = initial_state(opts) |> attach_model_assignments(model_assignments)

    GameRunner.run_multi_model(state, modules(), &default_opts/1, opts,
      print_setup: fn s ->
        IO.puts(
          "Starting Survivor game with #{map_size(get(s.world, :players, %{}))} players (multi-model)"
        )

        print_tribe_assignments(s.world)
      end,
      print_result: &print_game_result/1,
      announce_turn: &announce_turn/2,
      print_step: &print_step/2,
      transcript_detail: &transcript_detail/1,
      transcript_game_over_extra: &transcript_game_over_extra/1
    )
  end

  # -- Transcript detail callbacks for multi-model --

  defp transcript_detail(world) do
    phase = get(world, :phase)

    case phase do
      "strategy" ->
        statements = get(world, :statements, [])
        last = List.last(statements)
        if last, do: %{statement: get(last, :statement), speaker: get(last, :player)}, else: %{}

      "tribal_council" ->
        %{votes: get(world, :votes, %{})}

      "challenge" ->
        %{choices: get(world, :challenge_choices, %{})}

      "final_tribal_council" ->
        %{
          sub_phase: get(world, :ftc_sub_phase),
          jury_votes: get(world, :jury_votes, %{})
        }

      _ ->
        %{}
    end
  end

  defp transcript_game_over_extra(world) do
    %{
      episode: get(world, :episode),
      elimination_log: get(world, :elimination_log, []),
      jury: get(world, :jury, []),
      jury_votes: get(world, :jury_votes, %{}),
      statements: get(world, :statements, []),
      performance: Performance.summarize(world)
    }
  end

  # -- View builders for information hiding --

  defp build_player_view(world, _actor_id) do
    players = get(world, :players, %{})
    tribes = get(world, :tribes, %{})
    merged = get(world, :merged, false)

    player_summary =
      players
      |> Enum.sort_by(fn {id, _p} -> id end)
      |> Enum.map(fn {id, p} ->
        status = get(p, :status, "alive")
        tribe = get(p, :tribe, "unknown")
        traits = get(p, :traits, [])

        base = %{"name" => id, "status" => status, "tribe" => tribe, "traits" => traits}

        if get(p, :jury_member, false) do
          Map.put(base, "jury_member", true)
        else
          base
        end
      end)

    view = %{
      "phase" => get(world, :phase),
      "episode" => get(world, :episode),
      "active_player" => get(world, :active_actor_id),
      "players" => player_summary,
      "living_count" => Tribes.living_count(players),
      "merged" => merged
    }

    view =
      if merged do
        view
      else
        Map.put(view, "tribes", tribes)
      end

    # Add challenge winner if relevant
    challenge_winner = get(world, :challenge_winner)

    if challenge_winner do
      immune = get(world, :immune_player)
      view = Map.put(view, "challenge_winner", challenge_winner)
      if immune, do: Map.put(view, "immune_player", immune), else: view
    else
      view
    end
  end

  defp build_player_info(world, actor_id, actor) do
    base = %{
      "your_id" => actor_id,
      "your_tribe" => get(actor, :tribe, "unknown"),
      "your_status" => get(actor, :status, "alive"),
      "has_idol" => get(actor, :has_idol, false)
    }

    jury_member = get(actor, :jury_member, false)

    base =
      if jury_member do
        Map.put(base, "jury_member", true)
      else
        base
      end

    # Add context based on phase
    phase = get(world, :phase)

    case phase do
      "challenge" ->
        Map.put(
          base,
          "description",
          "Choose your challenge strategy wisely. Physical beats endurance, " <>
            "endurance beats puzzle, puzzle beats physical. Challenge outcomes depend on how your tribe's picks match up against the opposition."
        )

      "strategy" ->
        Map.put(
          base,
          "description",
          "Make a public statement to influence others, then send a private whisper " <>
            "to one player. Everyone can see WHO you whisper to, but not WHAT you say."
        )

      "tribal_council" ->
        idol_played_by = get(world, :idol_played_by)
        idol_info = if idol_played_by, do: %{"idol_played_by" => idol_played_by}, else: %{}

        Map.merge(base, idol_info)
        |> Map.put(
          "description",
          "Tribal council! If you have an idol, you can play it to negate votes against you. " <>
            "Then vote to eliminate someone. The person with the most votes goes home."
        )

      "final_tribal_council" ->
        sub_phase = get(world, :ftc_sub_phase, "jury_statements")
        jury_statements = get(world, :jury_statements, [])

        Map.merge(base, %{
          "ftc_sub_phase" => sub_phase,
          "jury_statements" => jury_statements,
          "description" =>
            case sub_phase do
              "jury_statements" ->
                "As a jury member, question the finalists. Hold them accountable for their gameplay."

              "finalist_pleas" ->
                "As a finalist, make your case to the jury. Explain your moves and why you deserve to win."

              "jury_voting" ->
                "Cast your jury vote for who you think played the best game and deserves to be the Sole Survivor."

              _ ->
                "Final Tribal Council is in session."
            end
        })

      _ ->
        base
    end
  end

  defp build_private_whispers(world, actor_id) do
    whisper_log = get(world, :whisper_log, [])

    whisper_log
    |> Enum.filter(fn entry ->
      get(entry, :from) == actor_id or get(entry, :to) == actor_id
    end)
    |> Enum.map(fn entry ->
      %{
        "from" => get(entry, :from),
        "to" => get(entry, :to),
        "message" => get(entry, :message)
      }
    end)
  end

  # -- Event visibility filtering --

  defp event_visible?(event, _actor_id) when not is_map(event), do: false

  defp event_visible?(event, actor_id) do
    kind = event_kind(event)

    cond do
      # Whisper events: only sender and recipient see the content
      kind == "send_whisper" ->
        payload = event_payload(event)

        from =
          Map.get(payload, :from_id, Map.get(payload, "from_id")) ||
            Map.get(payload, :player_id, Map.get(payload, "player_id"))

        to = Map.get(payload, :to_id, Map.get(payload, "to_id"))
        from == actor_id or to == actor_id

      # Idol decisions: only the player who decided
      kind in ["play_idol", "skip_idol"] ->
        event_player_id(event) == actor_id

      # Action rejections: only the rejected player
      kind == "action_rejected" ->
        event_player_id(event) == actor_id

      # Everything else is public
      true ->
        true
    end
  end

  defp sanitize_event(event, _actor_id) when not is_map(event), do: event

  defp sanitize_event(event, _actor_id) do
    kind = event_kind(event)

    case kind do
      # Strip private whisper content from events (shouldn't reach here, but safety)
      "send_whisper" ->
        payload = event_payload(event)

        sanitized_payload =
          payload
          |> Map.delete(:message)
          |> Map.delete("message")

        put_payload(event, sanitized_payload)

      _ ->
        event
    end
  end

  # -- Callbacks --

  defp terminal?(state), do: get(state.world, :status) in ["game_over"]

  defp announce_turn(turn, state) do
    actor_id = get(state.world, :active_actor_id)
    phase = get(state.world, :phase)
    episode = get(state.world, :episode, 1)

    IO.puts("Step #{turn} | ep=#{episode} phase=#{phase} actor=#{actor_id}")
  end

  defp print_step(_turn, %{state: next_state}) do
    world = next_state.world
    phase = get(world, :phase)

    case phase do
      "strategy" ->
        statements = get(world, :statements, [])

        case List.last(statements) do
          nil -> :ok
          entry -> IO.puts("  [#{get(entry, :player)}]: \"#{get(entry, :statement)}\"")
        end

      "tribal_council" ->
        votes = get(world, :votes, %{})

        if map_size(votes) > 0 do
          latest =
            votes
            |> Enum.to_list()
            |> List.last()

          case latest do
            {voter, target} -> IO.puts("  #{voter} voted for #{target}")
            _ -> :ok
          end
        end

      "final_tribal_council" ->
        jury_statements = get(world, :jury_statements, [])

        case List.last(jury_statements) do
          nil -> :ok
          entry -> IO.puts("  [#{get(entry, :player)}]: \"#{get(entry, :statement)}\"")
        end

      "game_over" ->
        IO.puts("  Game over! Sole Survivor: #{get(world, :winner)}")

      _ ->
        :ok
    end
  end

  defp print_step(_turn, _result), do: :ok

  defp print_tribe_assignments(world) do
    players = get(world, :players, %{})
    tribes = get(world, :tribes, %{})

    IO.puts("Tribe assignments:")

    Enum.each(tribes, fn {tribe_name, members} ->
      IO.puts("  #{tribe_name}: #{Enum.join(members, ", ")}")
    end)

    # Show idol holder (hidden from players)
    idol_holder =
      players
      |> Enum.find(fn {_id, p} -> get(p, :has_idol, false) end)

    case idol_holder do
      {id, _p} -> IO.puts("  Hidden Idol: #{id}")
      nil -> :ok
    end

    IO.puts("")
  end

  defp print_game_result(world) do
    winner = get(world, :winner)
    players = get(world, :players, %{})
    elimination_log = get(world, :elimination_log, [])
    jury = get(world, :jury, [])
    jury_votes = get(world, :jury_votes, %{})
    performance = Performance.summarize(world)

    IO.puts("Sole Survivor: #{winner}")
    IO.puts("\nFinal player status:")

    players
    |> Enum.sort_by(fn {id, _p} -> id end)
    |> Enum.each(fn {id, p} ->
      status = get(p, :status)
      tribe = get(p, :tribe)
      jury_member = if get(p, :jury_member, false), do: " [JURY]", else: ""
      IO.puts("  #{id}: #{tribe} (#{status})#{jury_member}")
    end)

    IO.puts("\nElimination order:")

    Enum.each(elimination_log, fn entry ->
      IO.puts("  Ep #{get(entry, :episode)}: #{get(entry, :player)} - #{get(entry, :reason)}")
    end)

    if map_size(jury_votes) > 0 do
      IO.puts("\nJury votes:")

      jury
      |> Enum.each(fn juror_id ->
        target = Map.get(jury_votes, juror_id, "?")
        IO.puts("  #{juror_id} -> #{target}")
      end)
    end

    IO.puts("\nPerformance summary:")

    performance
    |> get(:players, %{})
    |> Enum.sort_by(fn {_id, metrics} ->
      {get(metrics, :challenge_wins, 0) * -1, get(metrics, :name, "")}
    end)
    |> Enum.each(fn {_id, metrics} ->
      IO.puts(
        "  #{get(metrics, :name)}#{if get(metrics, :won), do: " [winner]", else: ""}: " <>
          "challenge_wins=#{get(metrics, :challenge_wins, 0)} " <>
          "whispers_sent=#{get(metrics, :whispers_sent, 0)} " <>
          "correct_votes=#{get(metrics, :correct_votes, 0)} " <>
          "wrong_votes=#{get(metrics, :wrong_votes, 0)} " <>
          "idol_plays=#{get(metrics, :idol_plays, 0)} " <>
          "jury_votes_received=#{get(metrics, :jury_votes_received, 0)}"
      )
    end)

    IO.puts("Model summary:")

    performance
    |> get(:models, %{})
    |> Enum.sort_by(fn {model, _metrics} -> model || "" end)
    |> Enum.each(fn {model, metrics} ->
      IO.puts(
        "  #{model}: seats=#{get(metrics, :seats, 0)} wins=#{get(metrics, :wins, 0)} " <>
          "challenge_wins=#{get(metrics, :challenge_wins, 0)} correct_votes=#{get(metrics, :correct_votes, 0)} " <>
          "jury_votes_received=#{get(metrics, :jury_votes_received, 0)}"
      )
    end)
  end

  defp attach_model_assignments(state, model_assignments) do
    players =
      state.world
      |> get(:players, %{})
      |> Enum.into(%{}, fn {player_id, info} ->
        {model, _key} = Map.get(model_assignments, player_id, {nil, nil})
        model_name = if model, do: "#{model.provider}/#{model.id}", else: nil
        {player_id, Map.put(info, :model, model_name)}
      end)

    %{state | world: Map.put(state.world, :players, players)}
  end
end
