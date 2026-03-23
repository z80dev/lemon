defmodule LemonSim.Examples.Courtroom do
  @moduledoc """
  Courtroom Trial adversarial argumentation simulation built on LemonSim.

  A multi-phase trial with prosecution, defense, witnesses, and jury agents.
  Each agent has a distinct role and private information packet.

  Phases:
  1. **opening_statements** - Prosecution then defense deliver opening statements
  2. **prosecution_case** - Prosecution calls witnesses, presents evidence, examines
  3. **cross_examination** - Defense cross-examines prosecution's witnesses
  4. **defense_case** - Defense calls witnesses, presents evidence, examines
  5. **defense_cross** - Prosecution cross-examines defense's witnesses
  6. **closing_arguments** - Both sides deliver closing arguments
  7. **deliberation** - Jury discusses and deliberates
  8. **verdict** - Each juror casts a guilty/not_guilty vote

  Win condition:
  - Prosecution wins if majority verdict is "guilty"
  - Defense wins if majority verdict is "not_guilty" or hung jury
  """

  alias LemonCore.Config.{Modular, Providers}
  alias LemonCore.MapHelpers

  alias LemonSim.Examples.Courtroom.{
    ActionSpace,
    CaseGenerator,
    Performance,
    Updater
  }

  alias LemonSim.Deciders.ToolLoopDecider
  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Runner, State, Store}

  @default_max_turns 300
  @default_witness_count 3
  @default_juror_count 3

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    witness_count = Keyword.get(opts, :witness_count, @default_witness_count)
    juror_count = Keyword.get(opts, :juror_count, @default_juror_count)
    seed = Keyword.get(opts, :seed, :erlang.phash2(:erlang.monotonic_time()))

    case_file =
      CaseGenerator.generate(
        witness_count: witness_count,
        seed: seed
      )

    witness_ids = case_file.witnesses |> Map.keys() |> Enum.sort()
    juror_ids = Enum.map(1..juror_count, &"juror_#{&1}")

    players =
      %{}
      |> Map.put("prosecution", %{role: "prosecution", status: "active", model: nil})
      |> Map.put("defense", %{role: "defense", status: "active", model: nil})
      |> then(fn acc ->
        Enum.reduce(witness_ids, acc, fn wid, a ->
          witness_info = Map.get(case_file.witnesses, wid, %{})

          Map.put(a, wid, %{
            role: "witness",
            status: "active",
            archetype: Map.get(witness_info, :archetype, "witness"),
            testimony: Map.get(witness_info, :testimony, ""),
            knows_evidence: Map.get(witness_info, :knows_evidence, [])
          })
        end)
      end)
      |> then(fn acc ->
        Enum.reduce(juror_ids, acc, fn jid, a ->
          Map.put(a, jid, %{role: "juror", status: "active", model: nil})
        end)
      end)

    # Opening statements: prosecution first, then defense
    turn_order = ["prosecution", "defense"] ++ witness_ids ++ juror_ids
    opening_actors = ["prosecution", "defense"]

    %{
      case_file: case_file,
      players: players,
      turn_order: turn_order,
      phase: "opening_statements",
      actors_in_phase: opening_actors,
      active_actor_id: List.first(opening_actors),
      phase_done: MapSet.new(),
      testimony_log: [],
      evidence_presented: [],
      objections: [],
      jury_notes: %{},
      verdict_votes: %{},
      current_witness_id: nil,
      journals: %{},
      status: "in_progress",
      winner: nil,
      outcome: nil
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id =
      Keyword.get(opts, :sim_id, "courtroom_#{:erlang.phash2(:erlang.monotonic_time())}")

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "Participate in a courtroom trial according to your assigned role. " <>
            "Your role and private information are shown in the world state. " <>
            "Use the available tools to argue your case, examine witnesses, or deliberate."
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
            title: "Trial State",
            format: :json,
            content: visible_world(frame.world, actor_id)
          }
        end,
        your_role: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          players = get(frame.world, :players, %{})
          player_info = Map.get(players, actor_id, %{})
          role = get(player_info, :role, "unknown")
          case_file = get(frame.world, :case_file, %{})

          role_brief = build_role_brief(role, actor_id, player_info, case_file, frame.world)

          %{
            id: :your_role,
            title: "Your Role",
            format: :json,
            content: role_brief
          }
        end,
        testimony_log: fn frame, _tools, _opts ->
          log = get(frame.world, :testimony_log, [])

          %{
            id: :testimony_log,
            title: "Court Record (Recent)",
            format: :json,
            content: Enum.take(log, -20)
          }
        end,
        recent_events: fn frame, _tools, _opts ->
          %{
            id: :recent_events,
            title: "Recent Events",
            format: :json,
            content: Enum.take(frame.recent_events, -10)
          }
        end
      },
      section_overrides: %{
        decision_contract: """
        COURTROOM RULES:
        - You must act according to your assigned role.
        - PROSECUTION: Make the case that the defendant is guilty. Use evidence, examine witnesses.
        - DEFENSE: Defend against the charges. Challenge prosecution's evidence and witnesses.
        - WITNESSES: Answer questions based on your testimony packet. You may be truthful or evasive.
        - JURY: Deliberate carefully based on all testimony and evidence. Vote fairly.
        - Each phase has specific actions available. You MUST use the provided tools.
        - Objections can disrupt the opposing side — use them strategically.
        - The jury decides: majority guilty = prosecution wins; majority not_guilty = defense wins.
        - STAY IN CHARACTER: argue as a lawyer, testify as a witness, deliberate as a juror.
        """
      },
      section_order: [
        :world_state,
        :your_role,
        :testimony_log,
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
    case_file = get(state.world, :case_file, %{})
    players = get(state.world, :players, %{})

    run_opts =
      default_opts(opts)
      |> Keyword.merge(opts)

    IO.puts("Starting Courtroom Trial: #{get(case_file, :title, "Unknown Case")}")
    IO.puts("Defendant: #{get(case_file, :defendant, "Unknown")}")
    IO.puts("Participants: #{map_size(players)} (prosecution, defense, witnesses, jury)")

    case Runner.run_until_terminal(state, modules(), run_opts) do
      {:ok, final_state} ->
        IO.puts("\nTrial Concluded!")
        print_final_state(final_state)

        if Keyword.get(run_opts, :persist?, true) do
          _ = Store.put_state(final_state)
        end

        {:ok, final_state}

      {:error, reason} = error ->
        IO.puts("Trial failed:")
        IO.inspect(reason)
        error
    end
  end

  # -- Visibility --

  defp visible_world(world, actor_id) do
    players = get(world, :players, %{})
    case_file = get(world, :case_file, %{})
    evidence_presented = get(world, :evidence_presented, [])
    objections = get(world, :objections, [])
    verdict_votes = get(world, :verdict_votes, %{})

    player_view =
      Enum.into(players, %{}, fn {id, info} ->
        {id,
         %{
           "role" => get(info, :role, "unknown"),
           "status" => get(info, :status, "active")
         }}
      end)

    %{
      "phase" => get(world, :phase, "opening_statements"),
      "active_player" => MapHelpers.get_key(world, :active_actor_id),
      "your_id" => actor_id,
      "case_title" => get(case_file, :title, "Unknown"),
      "defendant" => get(case_file, :defendant, "Unknown"),
      "evidence_presented" => evidence_presented,
      "evidence_count" => length(evidence_presented),
      "total_evidence_available" => length(get(case_file, :evidence_list, [])),
      "objections_raised" => length(objections),
      "objections_sustained" =>
        Enum.count(objections, &(get(&1, :ruling, "overruled") == "sustained")),
      "jury_votes_cast" => map_size(verdict_votes),
      "players" => player_view
    }
  end

  defp build_role_brief("prosecution", actor_id, _info, case_file, world) do
    %{
      "your_id" => actor_id,
      "your_role" => "prosecution",
      "objective" => "Prove the defendant is guilty beyond reasonable doubt.",
      "case_description" => get(case_file, :description, ""),
      "defendant" => get(case_file, :defendant, "Unknown"),
      "evidence_available" => get(case_file, :evidence_list, []),
      "evidence_details" => format_evidence_details(case_file),
      "witnesses_available" => witnesses_summary(world)
    }
  end

  defp build_role_brief("defense", actor_id, _info, case_file, world) do
    %{
      "your_id" => actor_id,
      "your_role" => "defense",
      "objective" => "Defend the defendant and raise reasonable doubt.",
      "case_description" => get(case_file, :description, ""),
      "defendant" => get(case_file, :defendant, "Unknown"),
      "evidence_available" => get(case_file, :evidence_list, []),
      "evidence_details" => format_evidence_details(case_file),
      "witnesses_available" => witnesses_summary(world),
      "note" => "Your client maintains their innocence."
    }
  end

  defp build_role_brief("witness", actor_id, info, case_file, _world) do
    %{
      "your_id" => actor_id,
      "your_role" => "witness",
      "archetype" => get(info, :archetype, "witness"),
      "your_testimony" => get(info, :testimony, ""),
      "evidence_you_know_about" => get(info, :knows_evidence, []),
      "case_title" => get(case_file, :title, "Unknown"),
      "instruction" =>
        "Answer questions based on your testimony. You may elaborate or be evasive, but do not outright lie."
    }
  end

  defp build_role_brief("juror", actor_id, _info, case_file, world) do
    jury_notes = get(world, :jury_notes, %{})
    my_notes = Map.get(jury_notes, actor_id, [])

    %{
      "your_id" => actor_id,
      "your_role" => "juror",
      "objective" =>
        "Listen carefully to all testimony and evidence. " <>
          "Deliberate with fellow jurors and cast an impartial verdict.",
      "case_title" => get(case_file, :title, "Unknown"),
      "defendant" => get(case_file, :defendant, "Unknown"),
      "evidence_presented_so_far" => get(world, :evidence_presented, []),
      "your_notes" => my_notes,
      "instruction" =>
        "Vote guilty only if convinced of guilt beyond reasonable doubt. " <>
          "Otherwise vote not_guilty."
    }
  end

  defp build_role_brief(role, actor_id, _info, _case_file, _world) do
    %{"your_id" => actor_id, "your_role" => role}
  end

  defp format_evidence_details(case_file) do
    evidence_list = get(case_file, :evidence_list, [])
    evidence_details = get(case_file, :evidence_details, %{})

    Enum.into(evidence_list, %{}, fn ev_id ->
      info = Map.get(evidence_details, ev_id, %{})
      {ev_id, Map.get(info, :description, ev_id)}
    end)
  end

  defp witnesses_summary(world) do
    players = get(world, :players, %{})

    players
    |> Enum.filter(fn {_id, info} -> get(info, :role) == "witness" end)
    |> Enum.map(fn {id, info} ->
      %{"id" => id, "archetype" => get(info, :archetype, "witness")}
    end)
  end

  # -- Callbacks --

  defp terminal?(state) do
    status = MapHelpers.get_key(state.world, :status)
    status == "complete"
  end

  defp announce_turn(turn, state) do
    actor_id = MapHelpers.get_key(state.world, :active_actor_id)
    phase = get(state.world, :phase, "?")

    IO.puts("Step #{turn} | phase=#{phase} actor=#{actor_id}")
  end

  defp print_step(_turn, %{state: next_state}) do
    phase = get(next_state.world, :phase, "?")
    log_size = length(get(next_state.world, :testimony_log, []))
    evidence_count = length(get(next_state.world, :evidence_presented, []))
    IO.puts("  phase=#{phase} testimony_entries=#{log_size} evidence_presented=#{evidence_count}")
  end

  defp print_step(_turn, _result), do: :ok

  defp print_final_state(state) do
    outcome = get(state.world, :outcome, "unknown")
    winner = get(state.world, :winner, nil)
    verdict_votes = get(state.world, :verdict_votes, %{})
    case_file = get(state.world, :case_file, %{})

    IO.puts("Case: #{get(case_file, :title, "Unknown")}")
    IO.puts("Outcome: #{outcome}")

    if winner do
      players = get(state.world, :players, %{})
      player_info = Map.get(players, winner, %{})
      role = get(player_info, :role, "unknown")
      IO.puts("Winner: #{winner} (#{role})")
    end

    IO.puts("\nVerdict votes:")

    verdict_votes
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.each(fn {juror_id, vote} ->
      IO.puts("  #{juror_id}: #{vote}")
    end)

    performance = Performance.summarize(state.world)
    IO.puts("\nPerformance summary:")

    performance
    |> get(:players, %{})
    |> Enum.sort_by(fn {_player, metrics} -> get(metrics, :role, "") end)
    |> Enum.each(fn {player_id, metrics} ->
      IO.puts(
        "  #{player_id} [#{get(metrics, :role, "?")}]#{if get(metrics, :won, false), do: " [winner]", else: ""}: " <>
          "statements=#{get(metrics, :statements_made, 0)} " <>
          "questions=#{get(metrics, :questions_asked, 0)} " <>
          "objections=#{get(metrics, :objections_raised, 0)}/#{get(metrics, :objections_sustained, 0)}"
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
        Courtroom example requires a valid default model.
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
            raise "courtroom sim requires an OpenAI Codex access token"
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        provider_cfg[:api_key]

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            resolve_secret_api_key(provider_cfg[:api_key_secret], value)

          {:error, reason} ->
            raise "courtroom sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      true ->
        raise "courtroom sim requires configured credentials for #{provider_name}"
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

  defp get(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end
