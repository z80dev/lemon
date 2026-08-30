defmodule LemonSim.Examples.DungeonCrawl.GameLog do
  @moduledoc false

  alias LemonCore.MapHelpers
  alias LemonSim.Examples.GameLog, as: SharedGameLog

  defdelegate start(path), to: SharedGameLog
  defdelegate stop(log), to: SharedGameLog
  defdelegate log_init(log, world), to: SharedGameLog
  defdelegate default_log_path(sim_id), to: SharedGameLog
  defdelegate read_log(path), to: SharedGameLog

  def log_step(log, step, world, events \\ [])
  def log_step(nil, _step, _world, _events), do: :ok

  def log_step(log, step, world, events) do
    SharedGameLog.log_step(log, step, world, events, %{
      round: MapHelpers.get_key(world, :round),
      active_actor: MapHelpers.get_key(world, :active_actor_id),
      current_room: MapHelpers.get_key(world, :current_room)
    })
  end

  def log_game_over(nil, _step, _world), do: :ok

  def log_game_over(log, step, world) do
    SharedGameLog.log_terminal(log, "game_over", step, world, %{
      status: MapHelpers.get_key(world, :status),
      winner: MapHelpers.get_key(world, :winner)
    })
  end
end
