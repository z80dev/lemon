defmodule LemonSim.Examples.SupplyChain.GameLog do
  @moduledoc false

  alias LemonCore.MapHelpers

  @doc """
  Opens a JSONL log file for writing.
  """
  @spec start(String.t()) :: File.io_device()
  def start(path) when is_binary(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.open!(path, [:write, :utf8])
  end

  @doc """
  Closes the log file.
  """
  @spec stop(File.io_device() | nil) :: :ok
  def stop(nil), do: :ok
  def stop(log), do: File.close(log)

  @doc """
  Writes the initial game state as step 0.
  """
  @spec log_init(File.io_device() | nil, map()) :: :ok
  def log_init(nil, _world), do: :ok

  def log_init(log, world) do
    entry = %{
      type: "init",
      step: 0,
      world: world,
      events: [],
      timestamp: timestamp()
    }

    write_entry(log, entry)
  end

  @doc """
  Writes a step snapshot after each turn.
  """
  @spec log_step(File.io_device() | nil, non_neg_integer(), map(), [map()]) :: :ok
  def log_step(log, step, world, events \\ [])
  def log_step(nil, _step, _world, _events), do: :ok

  def log_step(log, step, world, events) do
    entry = %{
      type: "step",
      step: step,
      round: MapHelpers.get_key(world, :round),
      phase: MapHelpers.get_key(world, :phase),
      active_actor: MapHelpers.get_key(world, :active_actor_id),
      world: world,
      events: normalize_events(events),
      timestamp: timestamp()
    }

    write_entry(log, entry)
  end

  @doc """
  Writes the final game over entry.
  """
  @spec log_game_over(File.io_device() | nil, non_neg_integer(), map()) :: :ok
  def log_game_over(nil, _step, _world), do: :ok

  def log_game_over(log, step, world) do
    entry = %{
      type: "game_over",
      step: step,
      winner: MapHelpers.get_key(world, :winner),
      round: MapHelpers.get_key(world, :round),
      world: world,
      events: [],
      timestamp: timestamp()
    }

    write_entry(log, entry)
  end

  @doc """
  Returns a default log path for the given simulation ID.
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

  # -- Private helpers --

  defp write_entry(log, entry) do
    IO.puts(log, entry |> sanitize_for_json() |> Jason.encode!())
  end

  defp sanitize_for_json(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> sanitize_for_json()
  end

  defp sanitize_for_json(list) when is_list(list) do
    Enum.map(list, &sanitize_for_json/1)
  end

  defp sanitize_for_json(%MapSet{} = ms) do
    ms |> MapSet.to_list() |> sanitize_for_json()
  end

  defp sanitize_for_json(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {k, sanitize_for_json(v)} end)
  end

  defp sanitize_for_json(other), do: other

  defp timestamp do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp normalize_events(events) when is_list(events) do
    events
    |> Enum.map(fn
      %{kind: kind, payload: payload} -> %{kind: kind, payload: payload}
      %{"kind" => kind, "payload" => payload} -> %{kind: kind, payload: payload}
      other when is_map(other) -> other
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_events(_), do: []
end
