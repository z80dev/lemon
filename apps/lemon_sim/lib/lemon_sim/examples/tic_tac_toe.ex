defmodule LemonSim.Examples.TicTacToe do
  @moduledoc """
  Self-contained Tic Tac Toe example built on LemonSim.
  """

  alias LemonCore.Config.{Modular, Providers}
  alias LemonCore.MapHelpers
  alias LemonSim.Deciders.ToolLoopDecider

  alias LemonSim.Examples.TicTacToe.{
    ActionSpace,
    Updater
  }

  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{Runner, State, Store}

  @default_max_turns 20

  @spec initial_world() :: map()
  def initial_world do
    %{
      board: [
        [" ", " ", " "],
        [" ", " ", " "],
        [" ", " ", " "]
      ],
      current_player: "X",
      status: "in_progress",
      winner: nil,
      move_count: 0
    }
  end

  @spec initial_state() :: State.t()
  def initial_state do
    State.new(
      sim_id: "tic_tac_toe_1",
      world: initial_world(),
      intent: %{goal: "Play tic tac toe and win the game"},
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
          %{
            id: :world_state,
            title: "Current Board",
            format: :json,
            content: %{
              "board" => MapHelpers.get_key(frame.world, :board),
              "current_player" => MapHelpers.get_key(frame.world, :current_player),
              "status" => MapHelpers.get_key(frame.world, :status),
              "winner" => MapHelpers.get_key(frame.world, :winner),
              "move_count" => MapHelpers.get_key(frame.world, :move_count)
            }
          }
        end,
        recent_events: fn frame, _tools, _opts ->
          %{
            id: :recent_events,
            title: "Recent Events",
            format: :json,
            content: Enum.take(frame.recent_events, -8)
          }
        end
      },
      section_overrides: %{
        decision_contract: """
        - Use exactly one tool call: `place_mark`.
        - Choose an empty cell only.
        - If a move is rejected, choose a different cell.
        - Play optimally for the current player shown in world state.
        """
      },
      section_order: [
        :world_state,
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
    run_opts = Keyword.merge(default_opts(opts), opts)

    IO.puts("Starting Tic Tac Toe self-play")

    case Runner.run_until_terminal(initial_state(), modules(), run_opts) do
      {:ok, final_state} ->
        IO.puts("Final state:")
        IO.inspect(final_state.world)

        if Keyword.get(run_opts, :persist?, true) do
          _ = Store.put_state(final_state)
        end

        {:ok, final_state}

      {:error, reason} = error ->
        IO.puts("Driver failed:")
        IO.inspect(reason)
        error
    end
  end

  defp terminal?(state), do: MapHelpers.get_key(state.world, :status) in ["won", "draw"]

  defp announce_turn(turn, state) do
    IO.puts("Turn #{turn} | player=#{MapHelpers.get_key(state.world, :current_player)}")
  end

  defp print_step(_turn, %{state: next_state}) do
    print_board(next_state)
  end

  defp print_step(_turn, _result), do: :ok

  defp print_board(state) do
    board = MapHelpers.get_key(state.world, :board)

    IO.puts("Board:")
    Enum.each(board, fn row -> IO.puts(Enum.join(row, " | ")) end)

    IO.puts(
      "status=#{MapHelpers.get_key(state.world, :status)} winner=#{inspect(MapHelpers.get_key(state.world, :winner))} next=#{inspect(MapHelpers.get_key(state.world, :current_player))}"
    )
  end

  defp resolve_configured_model!(config) do
    provider = config.agent.default_provider
    model_spec = config.agent.default_model

    case resolve_model_spec(provider, model_spec) do
      %Ai.Types.Model{} = model ->
        apply_provider_base_url(model, config)

      nil ->
        raise """
        Tic Tac Toe example requires a valid default model.
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
    provider
    |> normalize_provider()
    |> then(&Ai.Models.get_model(&1, model_id))
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
            raise "tic tac toe sim requires an OpenAI Codex access token"
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        provider_cfg[:api_key]

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            resolve_secret_api_key(provider_cfg[:api_key_secret], value)

          {:error, reason} ->
            raise "tic tac toe sim could not resolve #{provider_name} credentials: #{inspect(reason)}"
        end

      true ->
        raise "tic tac toe sim requires configured credentials for #{provider_name}"
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
end
