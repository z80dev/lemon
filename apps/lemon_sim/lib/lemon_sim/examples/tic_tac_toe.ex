defmodule LemonSim.Examples.TicTacToe do
  @moduledoc """
  Self-contained Tic Tac Toe example built on LemonSim.
  """

  alias LemonCore.Config.{Modular, Providers}
  alias LemonSim.Deciders.ToolLoopDecider

  alias LemonSim.Examples.TicTacToe.{
    ActionSpace,
    DecisionAdapter,
    Driver,
    OfflineComplete,
    Updater
  }

  alias LemonSim.Projectors.SectionedProjector
  alias LemonSim.{State, Store}

  @default_max_driver_turns 20

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
      updater: Updater,
      decision_adapter: DecisionAdapter
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
              "board" => frame.world[:board],
              "current_player" => frame.world[:current_player],
              "status" => frame.world[:status],
              "winner" => frame.world[:winner],
              "move_count" => frame.world[:move_count]
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
    runtime = resolve_runtime(model, config, overrides)

    projector_opts()
    |> Kernel.++(
      model: model,
      stream_options: runtime.stream_options,
      mode: runtime.mode,
      max_driver_turns: @default_max_driver_turns,
      persist?: true
    )
    |> maybe_put(:complete_fn, runtime.complete_fn)
    |> maybe_put(:offline_reason, runtime.offline_reason)
  end

  @spec run(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    run_opts = Keyword.merge(default_opts(opts), opts)

    IO.puts("Starting Tic Tac Toe self-play")

    if run_opts[:mode] == :offline do
      IO.puts(
        "Using offline fallback player: #{format_offline_reason(run_opts[:offline_reason])}"
      )
    end

    case Driver.run(initial_state(), modules(), run_opts) do
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

  defp resolve_runtime(%Ai.Types.Model{} = model, config, overrides) do
    cond do
      Keyword.has_key?(overrides, :complete_fn) ->
        %{
          mode: :offline,
          stream_options: Keyword.get(overrides, :stream_options, %{}),
          complete_fn: Keyword.fetch!(overrides, :complete_fn),
          offline_reason: :custom_complete_fn
        }

      Keyword.get(overrides, :offline, false) ->
        offline_runtime(:forced_offline)

      true ->
        case resolve_provider_api_key(model.provider, config) do
          {:ok, api_key} ->
            %{
              mode: :live,
              stream_options: Keyword.get(overrides, :stream_options, %{api_key: api_key}),
              complete_fn: nil,
              offline_reason: nil
            }

          {:error, reason} ->
            offline_runtime(reason)
        end
    end
  end

  defp offline_runtime(reason) do
    %{
      mode: :offline,
      stream_options: %{},
      complete_fn: &OfflineComplete.complete/3,
      offline_reason: reason
    }
  end

  defp resolve_provider_api_key(provider, config) do
    provider_name = provider_name(provider)
    provider_cfg = Providers.get_provider(config.providers, provider_name)

    cond do
      provider_name == "openai-codex" ->
        case Ai.Auth.OpenAICodexOAuth.resolve_access_token() do
          token when is_binary(token) and token != "" -> {:ok, token}
          _ -> {:error, {:provider_api_key_unavailable, provider_name, :missing_token}}
        end

      is_binary(provider_cfg[:api_key]) and provider_cfg[:api_key] != "" ->
        {:ok, provider_cfg[:api_key]}

      is_binary(provider_cfg[:api_key_secret]) ->
        case LemonCore.Secrets.resolve(provider_cfg[:api_key_secret], env_fallback: true) do
          {:ok, value, _source} when is_binary(value) and value != "" ->
            {:ok, value}

          {:error, reason} ->
            {:error, {:provider_api_key_unavailable, provider_name, reason}}
        end

      true ->
        {:error, {:provider_api_key_unavailable, provider_name, :missing_api_key}}
    end
  end

  defp provider_name(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_name(provider) when is_binary(provider), do: provider

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_offline_reason(:forced_offline), do: "forced by options"
  defp format_offline_reason(:custom_complete_fn), do: "custom complete function override"

  defp format_offline_reason({:provider_api_key_unavailable, provider, reason}) do
    "#{provider} credentials unavailable (#{inspect(reason)})"
  end

  defp format_offline_reason(other), do: inspect(other)

  defp normalize_provider(provider_name) do
    provider_name
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_atom()
  end
end
