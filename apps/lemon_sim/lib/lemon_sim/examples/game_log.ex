defmodule LemonSim.Examples.GameLog do
  @moduledoc """
  Shared JSONL lifecycle and entry encoding for example game logs.

  Scenario loggers own their domain-specific metadata and public APIs. This
  module owns the common file handling, entry envelope, event normalization,
  timestamping, and recursive conversion of JSON-unsafe tuples and map sets.
  """

  @type log :: File.io_device() | nil

  @spec start(String.t()) :: File.io_device()
  def start(path) when is_binary(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.open!(path, [:write, :utf8])
  end

  @spec stop(log()) :: :ok
  def stop(nil), do: :ok
  def stop(log), do: File.close(log)

  @spec log_init(log(), map()) :: :ok
  def log_init(nil, _world), do: :ok

  def log_init(log, world) do
    write_entry(log, %{type: "init", step: 0, world: world, events: []})
  end

  @spec log_step(log(), non_neg_integer(), map(), term(), map()) :: :ok
  def log_step(nil, _step, _world, _events, _metadata), do: :ok

  def log_step(log, step, world, events, metadata) when is_map(metadata) do
    entry =
      Map.merge(
        %{type: "step", step: step, world: world, events: normalize_events(events)},
        metadata
      )

    write_entry(log, entry)
  end

  @spec log_terminal(log(), String.t(), non_neg_integer(), map(), map()) :: :ok
  def log_terminal(nil, _type, _step, _world, _metadata), do: :ok

  def log_terminal(log, type, step, world, metadata)
      when is_binary(type) and is_map(metadata) do
    entry =
      Map.merge(
        %{type: type, step: step, world: world, events: []},
        metadata
      )

    write_entry(log, entry)
  end

  @spec default_log_path(String.t()) :: String.t()
  def default_log_path(sim_id) when is_binary(sim_id) do
    dir = "priv/game_logs"
    File.mkdir_p!(dir)
    Path.join(dir, "#{sim_id}.jsonl")
  end

  @spec read_log(String.t()) :: [map()]
  def read_log(path) when is_binary(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  @doc false
  @spec write_entry(log(), map()) :: :ok
  def write_entry(nil, _entry), do: :ok

  def write_entry(log, entry) when is_map(entry) do
    encoded =
      entry
      |> Map.put(:timestamp, DateTime.utc_now() |> DateTime.to_iso8601())
      |> sanitize_for_json()
      |> Jason.encode!()

    IO.puts(log, encoded)
  end

  @doc false
  @spec normalize_events(term()) :: [map()]
  def normalize_events(events) when is_list(events) do
    events
    |> Enum.map(fn
      %{kind: kind, payload: payload} -> %{kind: kind, payload: payload}
      %{"kind" => kind, "payload" => payload} -> %{kind: kind, payload: payload}
      other when is_map(other) -> other
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  def normalize_events(_events), do: []

  defp sanitize_for_json(%MapSet{} = set) do
    set |> MapSet.to_list() |> sanitize_for_json()
  end

  defp sanitize_for_json(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> sanitize_for_json()
  end

  defp sanitize_for_json(list) when is_list(list) do
    Enum.map(list, &sanitize_for_json/1)
  end

  defp sanitize_for_json(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {key, sanitize_for_json(value)} end)
  end

  defp sanitize_for_json(other), do: other
end
