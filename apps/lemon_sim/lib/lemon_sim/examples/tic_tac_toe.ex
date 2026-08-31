defmodule LemonSim.Examples.TicTacToe do
  @moduledoc """
  Self-contained Tic Tac Toe example built on LemonSim.
  """

  alias LemonCore.Config.Modular
  alias LemonCore.MapHelpers
  alias LemonSim.LLM.Deciders.ToolLoopDecider
  alias LemonSim.LLM.GameHelpers.Config

  alias LemonSim.Examples.TicTacToe.{
    ActionSpace,
    OfflineRunner,
    Updater
  }

  alias LemonSim.LLM.Projectors.SectionedProjector
  alias LemonSim.Kernel.{Runner, State, Store}

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

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    State.new(
      sim_id: Keyword.get(opts, :sim_id, "tic_tac_toe_1"),
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

    model =
      Keyword.get_lazy(overrides, :model, fn ->
        Config.resolve_configured_model!(config, "tic tac toe",
          error_label: "Tic Tac Toe example"
        )
      end)

    stream_options =
      Keyword.get_lazy(overrides, :stream_options, fn ->
        %{api_key: Config.resolve_provider_api_key!(model.provider, config, "tic tac toe")}
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
        IO.puts("Final state: #{inspect(final_state.world)}")

        if Keyword.get(run_opts, :persist?, true) do
          _ = Store.put_state(final_state)
        end

        {:ok, final_state}

      {:error, reason} = error ->
        IO.puts("Driver failed: #{inspect(reason)}")
        error
    end
  end

  @spec run_offline_strategy(String.t() | atom(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def run_offline_strategy(strategy, opts \\ []) do
    OfflineRunner.run_strategy(strategy, opts)
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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
