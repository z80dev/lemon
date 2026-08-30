defmodule LemonSim.Examples.Skirmish.GameLog do
  @moduledoc false

  alias LemonCore.MapHelpers
  alias LemonSim.Examples.GameLog, as: SharedGameLog

  defdelegate start(path), to: SharedGameLog
  defdelegate stop(log), to: SharedGameLog
  defdelegate default_log_path(sim_id), to: SharedGameLog
  defdelegate read_log(path), to: SharedGameLog

  def log_init(nil, _world), do: :ok

  def log_init(log, world) do
    SharedGameLog.write_entry(log, %{type: "init", step: 0, world: world})
  end

  def log_step(nil, _step, _world), do: :ok

  def log_step(log, step, world) when is_map(world) do
    SharedGameLog.write_entry(log, %{
      type: "step",
      step: step,
      round: MapHelpers.get_key(world, :round),
      active_actor: MapHelpers.get_key(world, :active_actor_id),
      active_class: get_active_class(world),
      world: world
    })
  end

  def log_game_over(nil, _step, _world), do: :ok

  def log_game_over(log, step, world) when is_map(world) do
    SharedGameLog.write_entry(log, %{
      type: "game_over",
      step: step,
      winner: MapHelpers.get_key(world, :winner),
      world: world
    })
  end

  defp get_active_class(world) do
    actor_id = MapHelpers.get_key(world, :active_actor_id)
    units = MapHelpers.get_key(world, :units) || %{}

    case Map.get(units, actor_id) do
      unit when is_map(unit) -> MapHelpers.get_key(unit, :class)
      _ -> nil
    end
  end
end
