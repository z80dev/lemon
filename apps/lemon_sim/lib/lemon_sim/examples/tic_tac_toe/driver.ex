defmodule LemonSim.Examples.TicTacToe.Driver do
  @moduledoc false

  alias LemonSim.{Runner, State}

  @spec run(State.t(), map(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def run(%State{} = state, modules, opts) do
    do_run(state, modules, opts, 0)
  end

  defp do_run(%State{} = state, modules, opts, turn) do
    max_turns = Keyword.get(opts, :max_driver_turns, 50)

    cond do
      turn >= max_turns ->
        {:error, {:turn_limit_exceeded, max_turns}}

      state.world[:status] in ["won", "draw"] ->
        {:ok, state}

      true ->
        IO.puts("Turn #{turn + 1} | player=#{state.world[:current_player]}")

        case Runner.step(state, modules, opts) do
          {:ok, %{state: next_state}} ->
            print_board(next_state)
            do_run(next_state, modules, opts, turn + 1)

          {:error, reason} ->
            {:error, {:step_failed, reason}}
        end
    end
  end

  defp print_board(state) do
    board = state.world[:board]

    IO.puts("Board:")
    Enum.each(board, fn row -> IO.puts(Enum.join(row, " | ")) end)

    IO.puts(
      "status=#{state.world[:status]} winner=#{inspect(state.world[:winner])} next=#{inspect(state.world[:current_player])}"
    )
  end
end
