defmodule Mix.Tasks.LemonPoker.Play do
  @shortdoc "Run a multi-player poker match between default-profile agents"
  @moduledoc """
  Runs a no-limit holdem match in-process and prints actions as they happen.

  Examples:

      mix lemon_poker.play
      mix lemon_poker.play --players 6
      mix lemon_poker.play --hands 2 --seed 42
      mix lemon_poker.play --stack 2000 --small-blind 25 --big-blind 50
  """

  use Mix.Task

  @switches [
    hands: :integer,
    players: :integer,
    stack: :integer,
    small_blind: :integer,
    big_blind: :integer,
    seed: :integer,
    timeout_ms: :integer,
    max_decisions: :integer,
    agent_id: :string,
    table_id: :string
  ]

  @aliases [h: :hands, p: :players, s: :seed]

  @impl true
  def run(args) do
    Application.put_env(:lemon_control_plane, :port, 0)
    Application.put_env(:lemon_gateway, :health_port, 0)
    Application.put_env(:lemon_router, :health_port, 0)

    Mix.Task.run("app.start")

    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    case LemonPoker.HeadsUpMatch.play(opts) do
      {:ok, table} ->
        print_final_stacks(table)
        Mix.shell().info("match complete")

      {:error, reason, table} ->
        print_final_stacks(table)
        Mix.raise("match failed: #{inspect(reason)}")
    end
  end

  defp print_final_stacks(table) do
    table.seats
    |> Enum.sort_by(fn {seat, _} -> seat end)
    |> Enum.each(fn {seat, player} ->
      Mix.shell().info(
        "seat #{seat}: stack=#{player.stack} status=#{player.status} player_id=#{player.player_id}"
      )
    end)
  end
end
