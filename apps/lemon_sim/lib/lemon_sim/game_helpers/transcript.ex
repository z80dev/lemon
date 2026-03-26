defmodule LemonSim.GameHelpers.Transcript do
  @moduledoc """
  Shared JSONL transcript logging for LemonSim games.

  Handles the full transcript lifecycle: start, per-step logging,
  result logging, and game-over summary.
  """

  import LemonSim.GameHelpers

  @doc """
  Opens a transcript log file and writes the game_start entry.

  ## Options
    * `:extra` - additional fields to merge into the game_start entry
  """
  def start(path, world, model_assignments, opts \\ []) do
    path |> Path.dirname() |> File.mkdir_p!()
    log = File.open!(path, [:write, :utf8])

    players = get(world, :players, %{})
    extra = Keyword.get(opts, :extra, %{})

    player_info =
      Enum.into(players, %{}, fn {id, p} ->
        {model, _key} = Map.get(model_assignments, id, {nil, nil})
        model_name = if model, do: "#{model.provider}/#{model.id}", else: "unknown"

        {id, %{role: get(p, :role), model: model_name, name: get(p, :name)}}
      end)

    world_summary = sanitize_for_json(world)

    entry =
      Map.merge(
        %{
          type: "game_start",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          player_count: map_size(players),
          players: player_info,
          world: world_summary
        },
        extra
      )

    IO.puts(log, encode_safe(entry))
    log
  end

  @doc """
  Logs a turn_start entry with the current actor and model.
  """
  def log_step(log, turn, world, model_assignments) do
    actor_id = get(world, :active_actor_id)
    {model, _key} = Map.get(model_assignments, actor_id, {nil, nil})
    model_name = if model, do: "#{model.provider}/#{model.id}", else: "unknown"

    entry = %{
      type: "turn_start",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      step: turn,
      phase: get(world, :phase),
      round: get(world, :round, get(world, :day_number, get(world, :episode, 1))),
      active_player: actor_id,
      model: model_name
    }

    IO.puts(log, encode_safe(entry))
  end

  @doc """
  Logs a prebuilt transcript entry.
  """
  def log_entry(log, entry) when is_map(entry) do
    IO.puts(log, encode_safe(entry))
  end

  @doc """
  Logs a turn_result entry. Accepts an optional `detail_fn` that extracts
  game-specific detail from the world state.
  """
  def log_result(log, turn, world, detail_fn \\ &default_detail/1) do
    detail = detail_fn.(world)

    entry = %{
      type: "turn_result",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      step: turn,
      phase: get(world, :phase),
      round: get(world, :round, get(world, :day_number, get(world, :episode, 1))),
      detail: detail,
      status: get(world, :status)
    }

    IO.puts(log, encode_safe(entry))
  end

  @doc """
  Logs the game_over entry with final player statuses and models.

  ## Options
    * `:extra` - additional fields to merge into the game_over entry
  """
  def log_game_over(log, world, model_assignments, opts \\ []) do
    players = get(world, :players, %{})
    extra = Keyword.get(opts, :extra, %{})

    final_players =
      Enum.into(players, %{}, fn {id, p} ->
        {model, _key} = Map.get(model_assignments, id, {nil, nil})
        model_name = if model, do: "#{model.provider}/#{model.id}", else: "unknown"

        {id,
         %{role: get(p, :role), status: get(p, :status), model: model_name, name: get(p, :name)}}
      end)

    entry =
      Map.merge(
        %{
          type: "game_over",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          winner: get(world, :winner),
          players: final_players
        },
        extra
      )

    IO.puts(log, encode_safe(entry))
  end

  defp default_detail(_world), do: %{}

  @doc false
  def sanitize_for_json(value, max_depth \\ 5)

  def sanitize_for_json(value, _depth) when is_struct(value) do
    value |> Map.from_struct() |> sanitize_for_json(0)
  end

  def sanitize_for_json(value, depth) when is_map(value) and depth > 0 do
    Map.new(value, fn {k, v} -> {k, sanitize_for_json(v, depth - 1)} end)
  end

  def sanitize_for_json(value, depth) when is_list(value) and depth > 0 do
    Enum.map(value, &sanitize_for_json(&1, depth - 1))
  end

  def sanitize_for_json(value, _depth), do: value

  defp encode_safe(data) do
    data |> sanitize_for_json() |> Jason.encode!()
  end
end
