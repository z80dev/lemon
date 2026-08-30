defmodule LemonSim.Examples.Survivor.GameLog do
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
      episode: MapHelpers.get_key(world, :episode),
      phase: MapHelpers.get_key(world, :phase),
      active_actor: MapHelpers.get_key(world, :active_actor_id)
    })
  end

  def log_game_over(nil, _step, _world), do: :ok

  def log_game_over(log, step, world) do
    SharedGameLog.log_terminal(log, "game_over", step, world, %{
      winner: MapHelpers.get_key(world, :winner),
      elimination_log: MapHelpers.get_key(world, :elimination_log),
      jury: MapHelpers.get_key(world, :jury),
      jury_votes: MapHelpers.get_key(world, :jury_votes)
    })
  end
end
