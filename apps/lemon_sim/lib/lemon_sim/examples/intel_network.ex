defmodule LemonSim.Examples.IntelNetwork do
  @moduledoc """
  Intelligence Network simulation built on LemonSim.

  A 6-8 agent game with compartmentalized information and graph-constrained
  communication. One agent is secretly the mole leaking intel to an adversary.

  Each round has five phases:
  1. **intel_briefing** - Each agent receives a private intel fragment
  2. **communication** - Agents send messages ONLY to adjacent nodes (max 2 per round)
  3. **analysis** - Each agent privately analyzes what they know
  4. **operation** - Agents propose operations (share_intel, relay_message, verify_agent, report_suspicion)
  5. **mole_action** - (hidden) The mole secretly leak_intel or frame_agent

  Win conditions:
  - Loyalists win: correctly identify the mole via majority vote by end of final round
  - Mole wins: survive to end undetected, OR leak 5+ intel fragments
  """

  alias LemonCore.Config.{Modular, Providers}
  alias LemonCore.MapHelpers

  alias LemonSim.Examples.IntelNetwork.{
    ActionSpace,
    NetworkGraph,
    Performance,
    Updater
  }

  alias LemonSim.Deciders.ToolLoopDecider
  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Runner, State, Store}

  @default_max_turns 300
  @default_max_rounds 8

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    player_count = Keyword.get(opts, :player_count, 6)
    player_count = max(6, min(8, player_count))

    player_ids = Enum.map(1..player_count, &"agent_#{&1}")
    adjacency = NetworkGraph.generate_adjacency(player_ids)
    codenames = NetworkGraph.agent_codenames(player_count)
    intel_assignments = NetworkGraph.distribute_intel(player_ids)
    mole_id = NetworkGraph.select_mole(player_ids)
    intel_pool = Enum.take(NetworkGraph.all_fragments(), player_count)

    players =
      Enum.into(1..player_count, %{}, fn idx ->
        id = "agent_#{idx}"
        codename = Enum.at(codenames, idx - 1, "AGENT #{idx}")
        role = if id == mole_id, do: "mole", else: "operative"
        initial_fragment = Map.get(intel_assignments, id)

        {id,
         %{
           codename: codename,
           role: role,
           status: "active",
           intel_fragments: if(is_binary(initial_fragment), do: [initial_fragment], else: []),
           trust_level: 0.5
         }}
      end)

    turn_order = player_ids

    %{
      players: players,
      adjacency: adjacency,
      intel_pool: intel_pool,
      leaked_intel: [],
      suspicion_board: %{},
      message_log: %{},
      operations_log: [],
      analysis_notes: %{},
      journals: %{},
      phase: "intel_briefing",
      round: 1,
      max_rounds: @default_max_rounds,
      active_actor_id: List.first(turn_order),
      turn_order: turn_order,
      messages_sent_this_round: %{},
      communication_done: MapSet.new(),
      analysis_done: MapSet.new(),
      operations_done: MapSet.new(),
      briefing_done: MapSet.new(),
      status: "in_progress",
      winner: nil
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    sim_id =
      Keyword.get(
        opts,
        :sim_id,
        "intel_network_#{:erlang.phash2(:erlang.monotonic_time())}"
      )

    State.new(
      sim_id: sim_id,
      world: initial_world(opts),
      intent: %{
        goal:
          "You are a field agent in a compartmentalized intelligence network. " <>
            "Your role is shown in your world state. " <>
            "If you are an OPERATIVE: share intel carefully with adjacent agents, " <>
            "analyze communications for signs of the mole, and vote to expose them. " <>
            "If you are the MOLE: leak intel to the adversary without being detected. " <>
            "Survive to the end OR leak 5+ fragments to win. " <>
            "You can only contact your ADJACENT nodes — you do not know the full network topology."
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
            title: "Network State",
            format: :json,
            content: visible_world(frame.world, actor_id)
          }
        end,
        your_identity: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          players = get(frame.world, :players, %{})
          player = Map.get(players, actor_id, %{})
          adjacency = get(frame.world, :adjacency, %{})
          neighbors = NetworkGraph.local_view(adjacency, actor_id)
          suspicion_board = get(frame.world, :suspicion_board, %{})

          # Show player what their adjacent nodes look like
          neighbor_info =
            Enum.map(neighbors, fn nid ->
              nplayer = Map.get(players, nid, %{})
              reports_against = length(Map.get(suspicion_board, nid, []))

              %{
                "agent_id" => nid,
                "codename" => get(nplayer, :codename, nid),
                "suspicion_reports_against" => reports_against
              }
            end)

          %{
            id: :your_identity,
            title: "Your Identity (#{actor_id})",
            format: :json,
            content: %{
              "agent_id" => actor_id,
              "codename" => get(player, :codename, actor_id),
              "role" => get(player, :role, "operative"),
              "intel_fragments" => get(player, :intel_fragments, []),
              "adjacent_nodes" => neighbor_info,
              "your_suspicion_reports" => length(Map.get(suspicion_board, actor_id, []))
            }
          }
        end,
        message_inbox: fn frame, _tools, _opts ->
          actor_id = MapHelpers.get_key(frame.world, :active_actor_id)
          message_log = get(frame.world, :message_log, %{})
          adjacency = get(frame.world, :adjacency, %{})
          neighbors = NetworkGraph.local_view(adjacency, actor_id)
          round = get(frame.world, :round, 1)

          # Show messages from edges involving this player in the current round
          my_messages =
            Enum.flat_map(neighbors, fn nid ->
              edge_key = edge_key(actor_id, nid)
              msgs = Map.get(message_log, edge_key, [])

              Enum.filter(msgs, fn m ->
                get(m, :to, get(m, "to")) == actor_id and
                  get(m, :round, get(m, "round")) == round
              end)
            end)

          %{
            id: :message_inbox,
            title: "Messages Received This Round",
            format: :json,
            content: my_messages
          }
        end,
        suspicion_board: fn frame, _tools, _opts ->
          board = get(frame.world, :suspicion_board, %{})
          players = get(frame.world, :players, %{})

          board_view =
            Enum.into(board, %{}, fn {suspect_id, reporters} ->
              player = Map.get(players, suspect_id, %{})
              codename = get(player, :codename, suspect_id)

              {suspect_id,
               %{
                 "codename" => codename,
                 "report_count" => length(reporters)
               }}
            end)

          %{
            id: :suspicion_board,
            title: "Suspicion Board",
            format: :json,
            content: board_view
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
        INTELLIGENCE NETWORK RULES:
        - You can ONLY communicate with your ADJACENT nodes. You do not know the full network topology.
        - In INTEL BRIEFING: call end_briefing to acknowledge your fragment assignment.
        - In COMMUNICATION: send up to 2 messages to adjacent nodes, then end_communication.
        - In ANALYSIS: submit_analysis with your private notes — trust assessments, suspicions, intel status.
        - In OPERATION: propose up to one operation per turn, then end_operations.
          * share_intel: give a fragment to an adjacent node
          * relay_message: pass a message through your node
          * verify_agent: request trust verification of an adjacent node
          * report_suspicion: publicly flag an adjacent node as potentially the mole
        - In MOLE_ACTION (moles only): choose leak_intel, frame_agent, or pass.
        - Operatives win by correctly identifying the mole with a majority of report_suspicion votes.
        - The mole wins by surviving all 8 rounds undetected OR leaking 5+ intel fragments.
        - STRATEGY (operative): Share intel carefully. Analyze who communicates with whom. Vote on the mole.
        - STRATEGY (mole): Appear cooperative. Leak intel when safe. Frame others to divert suspicion.
        - You MUST call an action to advance the game. Do not stall.
        """
      },
      section_order: [
        :world_state,
        :your_identity,
        :message_inbox,
        :suspicion_board,
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

    player_count = map_size(get(state.world, :players, %{}))
    IO.puts("Starting Intelligence Network game with #{player_count} agents")

    mole_id = find_mole_id(state.world)
    IO.puts("Network topology generated. [REDACTED: mole is #{mole_id}]")

    case Runner.run_until_terminal(state, modules(), run_opts) do
      {:ok, final_state} ->
        IO.puts("\nMission Complete!")
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
    players = get(world, :players, %{})
    adjacency = get(world, :adjacency, %{})
    my_neighbors = NetworkGraph.local_view(adjacency, actor_id)

    # Each agent only sees their own portion of the network
    visible_adjacency = Map.take(adjacency, [actor_id | my_neighbors])

    # Players view: hide roles except own
    player_view =
      Enum.into(players, %{}, fn {id, info} ->
        is_self = id == actor_id

        {id,
         %{
           "codename" => get(info, :codename, id),
           "role" => if(is_self, do: get(info, :role, "operative"), else: "unknown"),
           "intel_fragments_count" => length(get(info, :intel_fragments, [])),
           "is_adjacent" => id in my_neighbors
         }}
      end)

    %{
      "phase" => get(world, :phase, "intel_briefing"),
      "round" => get(world, :round, 1),
      "max_rounds" => get(world, :max_rounds, 8),
      "active_player" => MapHelpers.get_key(world, :active_actor_id),
      "visible_adjacency" => visible_adjacency,
      "players" => player_view,
      "leaked_intel_count" => length(get(world, :leaked_intel, [])),
      "suspicion_board_summary" => suspicion_summary(get(world, :suspicion_board, %{}))
    }
  end

  defp suspicion_summary(board) do
    Enum.into(board, %{}, fn {suspect_id, reporters} ->
      {suspect_id, length(reporters)}
    end)
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
    print_network_summary(next_state)
  end

  defp print_step(_turn, _result), do: :ok

  defp print_network_summary(state) do
    players = get(state.world, :players, %{})
    leaked = length(get(state.world, :leaked_intel, []))

    IO.puts("Network status — leaked: #{leaked}/5")

    players
    |> Map.keys()
    |> Enum.sort()
    |> Enum.each(fn agent_id ->
      info = Map.get(players, agent_id, %{})
      codename = get(info, :codename, agent_id)
      fragments = length(get(info, :intel_fragments, []))
      IO.puts("  #{agent_id} [#{codename}]: #{fragments} fragments")
    end)

    IO.puts(
      "status=#{get(state.world, :status, "?")} winner=#{inspect(get(state.world, :winner, nil))}"
    )
  end

  defp print_final_state(state) do
    print_network_summary(state)

    winner = get(state.world, :winner, nil)
    round = get(state.world, :round, 1)
    performance = Performance.summarize(state.world)
    mole_id = find_mole_id(state.world)
    players = get(state.world, :players, %{})

    mole_info = Map.get(players, mole_id, %{})
    mole_codename = get(mole_info, :codename, mole_id)

    IO.puts("\nMole was: #{mole_id} (#{mole_codename})")

    if winner do
      IO.puts("Winner: #{winner} after #{round - 1} rounds!")
    end

    IO.puts("\nPerformance summary:")

    performance
    |> get(:players, %{})
    |> Enum.sort_by(fn {_agent, metrics} ->
      {if(get(metrics, :won, false), do: 0, else: 1), get(metrics, :messages_sent, 0) * -1}
    end)
    |> Enum.each(fn {agent_id, metrics} ->
      IO.puts(
        "  #{agent_id}#{if get(metrics, :won, false), do: " [winner]", else: ""}" <>
          " [#{get(metrics, :role, "?")}]" <>
          ": messages=#{get(metrics, :messages_sent, 0)}" <>
          " ops=#{get(metrics, :operations_performed, 0)}" <>
          " intel=#{get(metrics, :intel_fragments_held, 0)}" <>
          " suspicion_against=#{get(metrics, :times_reported, 0)}"
      )
    end)

    IO.puts("  detection_accuracy=#{performance.detection_accuracy}")
    IO.puts("  propagation_efficiency=#{performance.propagation_efficiency}")
    IO.puts("  network_utilization=#{performance.network_utilization}")
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
        IntelNetwork example requires a valid default model.
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
            raise "intel_network sim requires an OpenAI Codex access token"
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        provider_cfg[:api_key]

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            resolve_secret_api_key(provider_cfg[:api_key_secret], value)

          {:error, reason} ->
            raise "intel_network sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      true ->
        raise "intel_network sim requires configured credentials for #{provider_name}"
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

  defp find_mole_id(world) do
    players = get(world, :players, %{})

    case Enum.find(players, fn {_id, p} -> get(p, :role, "operative") == "mole" end) do
      {id, _} -> id
      nil -> nil
    end
  end

  defp edge_key(a, b) do
    [a, b] |> Enum.sort() |> Enum.join("--")
  end

  defp get(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
