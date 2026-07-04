defmodule LemonSim.Examples.TicTacToe.OfflineRunner do
  @moduledoc false

  alias LemonCore.MapHelpers
  alias LemonSim.Examples.TicTacToe
  alias LemonSim.Examples.TicTacToe.{ActionSpace, Updater}
  alias LemonSim.Kernel.{Runner, Store}

  @spec run_strategy(String.t() | atom(), keyword()) ::
          {:ok, LemonSim.Kernel.State.t()} | {:error, term()}
  def run_strategy(strategy, opts \\ [])

  def run_strategy(strategy, opts) when strategy in ["random", :random] do
    seed = Keyword.get(opts, :seed, 1)
    rng = :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})
    max_turns = Keyword.get(opts, :driver_max_turns, Keyword.get(opts, :max_turns, 20))

    state =
      opts
      |> Keyword.take([:sim_id])
      |> TicTacToe.initial_state()

    IO.puts("Starting Tic Tac Toe offline random self-play")

    case run_loop(state, max_turns, rng, 0, opts) do
      {:ok, final_state} = ok ->
        IO.puts("Final state: #{inspect(final_state.world)}")

        if Keyword.get(opts, :persist?, true) do
          _ = Store.put_state(final_state)
        end

        ok

      {:error, _reason} = error ->
        error
    end
  end

  def run_strategy(strategy, _opts), do: {:error, {:unknown_offline_strategy, strategy}}

  defp run_loop(state, max_turns, rng, turn, opts) do
    cond do
      terminal?(state) ->
        {:ok, state}

      turn >= max_turns ->
        {:error, {:offline_turn_limit_exceeded, max_turns}}

      true ->
        case decide_random_move(state, rng, opts) do
          {:ok, event, next_rng} ->
            case Runner.ingest_events(state, [event], Updater, opts) do
              {:ok, next_state, _signal} ->
                print_step(next_state)
                run_loop(next_state, max_turns, next_rng, turn + 1, opts)

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp decide_random_move(state, rng, opts) do
    with {:ok, [tool]} <- ActionSpace.tools(state, opts),
         {:ok, row, col, next_rng} <- random_empty_cell(state.world, rng),
         {:ok, result} <- tool.execute.("offline-random", %{"row" => row, "col" => col}, nil, nil),
         %{"event" => event} <- result.details do
      {:ok, event, next_rng}
    else
      {:ok, []} -> {:error, :no_available_actions}
      %{} = details -> {:error, {:missing_event, details}}
      other -> {:error, other}
    end
  end

  defp random_empty_cell(world, rng) do
    cells =
      world
      |> MapHelpers.get_key(:board)
      |> Enum.with_index()
      |> Enum.flat_map(fn {row, row_index} ->
        row
        |> Enum.with_index()
        |> Enum.filter(fn {cell, _col_index} -> cell == " " end)
        |> Enum.map(fn {_cell, col_index} -> {row_index, col_index} end)
      end)

    case cells do
      [] ->
        {:error, :no_empty_cells}

      _ ->
        {index, next_rng} = :rand.uniform_s(length(cells), rng)
        {row, col} = Enum.at(cells, index - 1)
        {:ok, row, col, next_rng}
    end
  end

  defp terminal?(state), do: MapHelpers.get_key(state.world, :status) in ["won", "draw"]

  defp print_step(state) do
    board = MapHelpers.get_key(state.world, :board)

    IO.puts("Board:")
    Enum.each(board, fn row -> IO.puts(Enum.join(row, " | ")) end)

    IO.puts(
      "status=#{MapHelpers.get_key(state.world, :status)} winner=#{inspect(MapHelpers.get_key(state.world, :winner))} next=#{inspect(MapHelpers.get_key(state.world, :current_player))}"
    )
  end
end
