defmodule LemonSim.Examples.Skirmish.GameLog do
  @moduledoc false

  alias LemonCore.MapHelpers

  @doc """
  Opens a JSONL log file for writing. Returns the IO device handle.
  """
  @spec start(String.t()) :: File.io_device()
  def start(path) when is_binary(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.open!(path, [:write, :utf8])
  end

  @doc """
  Closes the log file. No-op if `log` is nil.
  """
  @spec stop(File.io_device() | nil) :: :ok
  def stop(nil), do: :ok
  def stop(log), do: File.close(log)

  @doc """
  Writes the initial game state as step 0.
  No-op if `log` is nil.
  """
  @spec log_init(File.io_device() | nil, map()) :: :ok
  def log_init(nil, _world), do: :ok

  def log_init(log, world) do
    entry = %{
      type: "init",
      step: 0,
      world: world,
      timestamp: timestamp()
    }

    write_entry(log, entry)
  end

  @doc """
  Writes a step snapshot after each turn.
  No-op if `log` is nil.
  """
  @spec log_step(File.io_device() | nil, non_neg_integer(), map()) :: :ok
  def log_step(nil, _step, _state), do: :ok

  def log_step(log, step, world) when is_map(world) do
    entry = %{
      type: "step",
      step: step,
      round: MapHelpers.get_key(world, :round),
      active_actor: MapHelpers.get_key(world, :active_actor_id),
      active_class: get_active_class(world),
      world: world,
      timestamp: timestamp()
    }

    write_entry(log, entry)
  end

  @doc """
  Writes the final game over entry.
  No-op if `log` is nil.
  """
  @spec log_game_over(File.io_device() | nil, non_neg_integer(), map()) :: :ok
  def log_game_over(nil, _step, _state), do: :ok

  def log_game_over(log, step, world) when is_map(world) do
    entry = %{
      type: "game_over",
      step: step,
      winner: MapHelpers.get_key(world, :winner),
      world: world,
      timestamp: timestamp()
    }

    write_entry(log, entry)
  end

  @doc """
  Returns a default log path for the given simulation ID and ensures
  the parent directory exists.
  """
  @spec default_log_path(String.t()) :: String.t()
  def default_log_path(sim_id) when is_binary(sim_id) do
    dir = "priv/game_logs"
    File.mkdir_p!(dir)
    Path.join(dir, "#{sim_id}.jsonl")
  end

  @doc """
  Reads a JSONL file and returns a list of decoded maps.
  """
  @spec read_log(String.t()) :: [map()]
  def read_log(path) when is_binary(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  # -- Private helpers -------------------------------------------------------

  defp write_entry(log, entry) do
    IO.puts(log, Jason.encode!(entry))
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601()
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
