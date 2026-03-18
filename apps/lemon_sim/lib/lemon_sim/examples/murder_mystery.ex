defmodule LemonSim.Examples.MurderMystery do
  @moduledoc """
  Murder Mystery deduction game built on LemonSim.

  A 3-6 player game where investigators try to identify the killer, their
  weapon, and the crime room before time runs out, while the killer attempts
  to escape detection.

  Each round has five phases:
  1. **Investigation** - Players search rooms for clues
  2. **Interrogation** - Players question each other on their whereabouts
  3. **Discussion** - Players share findings and theories publicly
  4. **Killer's Move** - The killer can plant false evidence or destroy real clues
  5. **Deduction Vote** - Players formally accuse a suspect (or pass)

  Win conditions:
  - **Investigators** win if any player makes a correct formal accusation
    (naming the killer, weapon, and room).
  - **Killer** wins if all rounds pass without a correct accusation.
  """

  alias LemonCore.Config.{Modular, Providers}
  alias LemonCore.MapHelpers

  alias LemonSim.Examples.MurderMystery.{
    ActionSpace,
    CaseGenerator,
    Performance,
    Updater
  }

  alias LemonSim.Deciders.ToolLoopDecider
  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Runner, State, Store}

  @default_max_turns 300
  @default_max_rounds 5

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    player_count = Keyword.get(opts, :player_count, 6)
    max_rounds = Keyword.get(opts, :max_rounds, @default_max_rounds)

    case_data = CaseGenerator.generate(player_count)

    turn_order = case_data.turn_order

    Map.merge(case_data, %{
      phase: "investigation",
      round: 1,
      max_rounds: max_rounds,
      active_actor_id: List.first(turn_order),
      searched_this_round: MapSet.new(),
      asked_this_round: MapSet.new(),
      pending_question: nil,
      discussion_done: MapSet.new(),
      deduction_done: MapSet.new(),
      interrogation_log: [],
      discussion_log: [],
      accusations: [],
      planted_evidence: [],
      destroyed_evidence: [],
      journals: %{},
      status: "in_progress",
      winner: nil,
      winning_player: nil
    })
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id =
      Keyword.get(
        opts,
        :sim_id,
        "murder_mystery_#{:erlang.phash2(:erlang.monotonic_time())}"
      )

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "Solve the murder mystery. Investigate rooms for clues, interrogate suspects, " <>
            "share findings, and ultimately identify the killer, murder weapon, and crime room. " <>
            "If you are the killer, mislead investigators and survive all rounds undetected. " <>
            "You are the active player shown in world state."
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
        your_character: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          players = get(frame.world, :players, %{})
          player_info = Map.get(players, actor_id, %{})
          role = get(player_info, :role, "investigator")

          clues_found = get(player_info, :clues_found, [])
          evidence = get(frame.world, :evidence, %{})

          clue_details =
            Enum.map(clues_found, fn clue_id ->
              clue = Map.get(evidence, clue_id, %{})

              %{
                "clue_id" => clue_id,
                "clue_type" => get(clue, :clue_type, "unknown"),
                "room_found" => get(clue, :room_id, "unknown"),
                "points_to" => get(clue, :points_to, "unknown")
              }
            end)

          # Build solution hint if killer
          solution_hint =
            if role == "killer" do
              solution = get(frame.world, :solution, %{})
              planted = get(frame.world, :planted_evidence, [])
              destroyed = get(frame.world, :destroyed_evidence, [])

              %{
                "your_role" => "KILLER",
                "true_solution" => %{
                  "weapon" => get(solution, :weapon, "unknown"),
                  "room_id" => get(solution, :room_id, "unknown")
                },
                "evidence_planted" => length(planted),
                "evidence_destroyed" => length(destroyed),
                "goal" => "Survive all #{get(frame.world, :max_rounds, @default_max_rounds)} rounds without being correctly accused"
              }
            else
              %{
                "your_role" => "investigator",
                "goal" => "Find and correctly accuse the killer with the right weapon and room",
                "accusations_remaining" => get(player_info, :accusations_remaining, 1)
              }
            end

          %{
            id: :your_character,
            title: "Your Character (#{actor_id})",
            format: :json,
            content: %{
              "player_id" => actor_id,
              "name" => get(player_info, :name, actor_id),
              "role" => role,
              "alibi" => get(player_info, :alibi, "unknown"),
              "clues_found" => clue_details,
              "clue_count" => length(clues_found),
              "role_info" => solution_hint
            }
          }
        end,
        other_suspects: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          players = get(frame.world, :players, %{})
          turn_order = get(frame.world, :turn_order, [])

          suspect_list =
            turn_order
            |> Enum.reject(&(&1 == actor_id))
            |> Enum.map(fn pid ->
              info = Map.get(players, pid, %{})

              %{
                "player_id" => pid,
                "name" => get(info, :name, pid),
                "alibi" => get(info, :alibi, "unknown"),
                "clues_found_count" => length(get(info, :clues_found, [])),
                "accusations_remaining" => get(info, :accusations_remaining, 1)
              }
            end)

          %{
            id: :other_suspects,
            title: "Other Suspects",
            format: :json,
            content: suspect_list
          }
        end,
        interrogation_record: fn frame, _tools, _opts ->
          log = get(frame.world, :interrogation_log, [])
          answered = Enum.filter(log, &(Map.get(&1, "answer") != nil))

          %{
            id: :interrogation_record,
            title: "Interrogation Record",
            format: :json,
            content: Enum.take(answered, -10)
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
        MURDER MYSTERY RULES:

        PHASES (in order each round):
        1. INVESTIGATION: Search one room to find clues. Clues reveal what type of evidence is
           present and which player it points to. You may only search once per round.
        2. INTERROGATION: Ask one other suspect a direct question. They must answer publicly.
           Use this to probe alibis, challenge stories, or gather information.
        3. DISCUSSION: Share a finding, make a theory, challenge an alibi, or end your turn.
           One action per player per round in this phase.
        4. KILLER'S MOVE: Only the killer acts here. They may plant false evidence in a room,
           destroy a real clue, or do nothing. Investigators cannot act during this phase.
        5. DEDUCTION VOTE: Each player may make one formal accusation (naming the killer,
           weapon, and room) OR skip. A correct accusation wins the game for investigators.
           A wrong accusation wastes your accusation token.

        STRATEGY FOR INVESTIGATORS:
        - Cross-reference clues: multiple clues pointing to the same suspect strengthen the case.
        - Listen carefully to interrogations - lies often contain inconsistencies.
        - Be cautious about accusing - you only have 1 accusation. Wait until confident.
        - Share findings openly to help all investigators.

        STRATEGY FOR THE KILLER:
        - Maintain your alibi consistently across all answers.
        - Plant evidence pointing to other suspects to sow confusion.
        - Destroy the clue pointing to you if you can find it.
        - Deflect suspicion through strategic discussion entries.
        - Survive all #{@default_max_rounds} rounds without being correctly accused.

        You MUST use an available action tool to complete your turn. Do not stall.
        """
      },
      section_order: [
        :world_state,
        :your_character,
        :other_suspects,
        :interrogation_record,
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
    solution = get(state.world, :solution, %{})
    killer_id = get(solution, :killer_id, "unknown")

    IO.puts("Starting Murder Mystery with #{player_count} suspects")
    IO.puts("Secret: killer=#{killer_id}, weapon=#{get(solution, :weapon, "?")}, room=#{get(solution, :room_id, "?")}")

    case Runner.run_until_terminal(state, modules(), run_opts) do
      {:ok, final_state} ->
        IO.puts("\nCase Closed!")
        print_final_state(final_state)

        if Keyword.get(run_opts, :persist?, true) do
          _ = Store.put_state(final_state)
        end

        {:ok, final_state}

      {:error, reason} = error ->
        IO.puts("Murder mystery sim failed:")
        IO.inspect(reason)
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp visible_world(world, actor_id) do
    rooms = get(world, :rooms, %{})
    players = get(world, :players, %{})
    phase = get(world, :phase, "investigation")
    round = get(world, :round, 1)
    max_rounds = get(world, :max_rounds, @default_max_rounds)
    active_actor = MapHelpers.get_key(world, :active_actor_id)
    accusations = get(world, :accusations, [])

    # Build room view - hide solution details
    room_view =
      Enum.into(rooms, %{}, fn {room_id, room_info} ->
        clues = get(room_info, :clues_present, [])
        searched_by = get(room_info, :searched_by, [])

        {room_id,
         %{
           "name" => get(room_info, :name, room_id),
           "clue_count" => length(clues),
           "searched_by" => searched_by
         }}
      end)

    # Build player view - hide roles unless game over
    status = get(world, :status, "in_progress")
    game_over = status != "in_progress"

    player_view =
      Enum.into(players, %{}, fn {pid, info} ->
        role = get(info, :role, "investigator")
        show_role = game_over or pid == actor_id

        {pid,
         %{
           "name" => get(info, :name, pid),
           "alibi" => get(info, :alibi, "unknown"),
           "clues_found_count" => length(get(info, :clues_found, [])),
           "accusations_remaining" => get(info, :accusations_remaining, 1),
           "role" => if(show_role, do: role, else: "unknown")
         }}
      end)

    %{
      "phase" => phase,
      "round" => round,
      "max_rounds" => max_rounds,
      "active_player" => active_actor,
      "status" => status,
      "winner" => get(world, :winner, nil),
      "rooms" => room_view,
      "players" => player_view,
      "accusations" => accusations,
      "planted_evidence_count" => length(get(world, :planted_evidence, [])),
      "destroyed_evidence_count" => length(get(world, :destroyed_evidence, []))
    }
  end

  defp terminal?(state) do
    status = MapHelpers.get_key(state.world, :status)
    status == "won"
  end

  defp announce_turn(turn, state) do
    actor_id = MapHelpers.get_key(state.world, :active_actor_id)
    phase = get(state.world, :phase, "?")
    round = get(state.world, :round, 1)
    players = get(state.world, :players, %{})
    player_info = Map.get(players, actor_id, %{})
    role = get(player_info, :role, "investigator")

    IO.puts("Step #{turn} | round=#{round} phase=#{phase} actor=#{actor_id} role=#{role}")
  end

  defp print_step(_turn, %{state: next_state}) do
    print_investigation_summary(next_state)
  end

  defp print_step(_turn, _result), do: :ok

  defp print_investigation_summary(state) do
    players = get(state.world, :players, %{})
    rooms = get(state.world, :rooms, %{})

    total_clues_found =
      players
      |> Map.values()
      |> Enum.sum_by(fn p -> length(get(p, :clues_found, [])) end)

    total_clues_in_rooms =
      rooms
      |> Map.values()
      |> Enum.sum_by(fn r -> length(get(r, :clues_present, [])) end)

    IO.puts(
      "clues_found=#{total_clues_found} clues_in_rooms=#{total_clues_in_rooms} " <>
        "planted=#{length(get(state.world, :planted_evidence, []))} " <>
        "destroyed=#{length(get(state.world, :destroyed_evidence, []))}"
    )
  end

  defp print_final_state(state) do
    winner = get(state.world, :winner, nil)
    winning_player = get(state.world, :winning_player, nil)
    round = get(state.world, :round, 1)
    solution = get(state.world, :solution, %{})
    performance = Performance.summarize(state.world)

    IO.puts("\nSolution: killer=#{get(solution, :killer_id, "?")} weapon=#{get(solution, :weapon, "?")} room=#{get(solution, :room_id, "?")}")

    case winner do
      "investigators" ->
        IO.puts("Result: INVESTIGATORS WIN! #{winning_player} solved the case after #{round} round(s).")

      "killer" ->
        killer_id = get(solution, :killer_id, "?")
        IO.puts("Result: KILLER WINS! #{killer_id} evaded justice for #{round} round(s).")

      _ ->
        IO.puts("Result: Game ended (round #{round})")
    end

    IO.puts("\nPerformance summary:")

    performance
    |> get(:players, %{})
    |> Enum.sort_by(fn {_player, metrics} ->
      {if(get(metrics, :won, false), do: 0, else: 1), get(metrics, :clues_found, 0) * -1}
    end)
    |> Enum.each(fn {player_id, metrics} ->
      won_marker = if get(metrics, :won, false), do: " [WON]", else: ""

      IO.puts(
        "  #{player_id} [#{get(metrics, :role, "?")}]#{won_marker}: " <>
          "clues_found=#{get(metrics, :clues_found, 0)} " <>
          "questions_asked=#{get(metrics, :questions_asked, 0)} " <>
          "discussion_entries=#{get(metrics, :discussion_entries, 0)} " <>
          "accusations_made=#{get(metrics, :accusations_made, 0)} " <>
          "correct=#{get(metrics, :correct_accusation, false)}"
      )
    end)
  end

  # ---------------------------------------------------------------------------
  # Config resolution (mirrors Diplomacy pattern)
  # ---------------------------------------------------------------------------

  defp resolve_configured_model!(config) do
    provider = config.agent.default_provider
    model_spec = config.agent.default_model

    case resolve_model_spec(provider, model_spec) do
      %Ai.Types.Model{} = model ->
        apply_provider_base_url(model, config)

      nil ->
        raise """
        Murder Mystery example requires a valid default model.
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
        case Ai.Auth.OpenAICodexOAuth.resolve_access_token() do
          token when is_binary(token) and token != "" ->
            token

          _ ->
            raise "murder mystery sim requires an OpenAI Codex access token"
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        provider_cfg[:api_key]

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            resolve_secret_api_key(provider_cfg[:api_key_secret], value)

          {:error, reason} ->
            raise "murder mystery sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      true ->
        raise "murder mystery sim requires configured credentials for #{provider_name}"
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
    case Ai.Auth.OAuthSecretResolver.resolve_api_key_from_secret(secret_name, secret_value) do
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
