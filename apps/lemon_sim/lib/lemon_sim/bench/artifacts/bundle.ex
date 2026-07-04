defmodule LemonSim.Bench.Artifacts.Bundle do
  @moduledoc false

  alias LemonSim.Bench.Artifacts.AtomicFile
  alias LemonSim.Bench.Scorecard.Registry
  alias LemonSim.LLM.Usage

  @deterministic_artifact_timestamp "1970-01-01T00:00:00Z"

  def write_scorecard_bundle(state, events, actions, opts) do
    scenario_id = Keyword.fetch!(opts, :scenario_id)
    artifact_dir = Keyword.fetch!(opts, :artifact_dir)
    version = Keyword.get(opts, :version, "1.0.0")

    File.mkdir_p!(artifact_dir)

    {:ok, scorecard} = Registry.scorecard(scenario_id, state.world)
    scorecard = put_if_missing(scorecard, :sim_id, state.sim_id)
    usage = usage_artifact(state, opts)

    paths = %{
      final_world: Path.join(artifact_dir, "final_world.json"),
      events: Path.join(artifact_dir, "events.jsonl"),
      actions: Path.join(artifact_dir, "actions.jsonl"),
      scorecard: Path.join(artifact_dir, "scorecard.json"),
      usage: Path.join(artifact_dir, "usage.json"),
      hashes: Path.join(artifact_dir, "hashes.json"),
      manifest: Path.join(artifact_dir, "manifest.json")
    }

    contents = %{
      paths.final_world => encode_json(state.world),
      paths.events => jsonl(events),
      paths.actions => jsonl(actions),
      paths.scorecard => encode_json(scorecard),
      paths.usage => Usage.encode_artifact(usage)
    }

    hashes =
      write_bundle!(artifact_dir, contents, paths.hashes, paths.manifest, fn hashes ->
        manifest_artifact(state, scenario_id, version, hashes, opts)
      end)

    {:ok, Map.put(paths, :hashes_artifact, hashes)}
  end

  def write_contents!(contents) when is_map(contents) do
    Enum.each(contents, fn {path, content} -> AtomicFile.write!(path, content) end)
  end

  def write_bundle!(
        artifact_dir,
        contents,
        hashes_path,
        manifest_path,
        manifest_fun,
        extra \\ %{}
      )
      when is_map(contents) and is_function(manifest_fun, 1) do
    write_contents!(contents)
    write_metadata!(artifact_dir, contents, hashes_path, manifest_path, manifest_fun, extra)
  end

  def write_metadata!(
        artifact_dir,
        contents,
        hashes_path,
        manifest_path,
        manifest_fun,
        extra \\ %{}
      )
      when is_map(contents) and is_function(manifest_fun, 1) do
    hashes = hashes_artifact(artifact_dir, contents, extra)

    AtomicFile.write!(hashes_path, Jason.encode!(hashes, pretty: true))
    AtomicFile.write!(manifest_path, Jason.encode!(manifest_fun.(hashes), pretty: true))

    hashes
  end

  def hashes_artifact(artifact_dir, contents, extra \\ %{}) do
    files =
      contents
      |> Enum.map(fn {path, content} ->
        {Path.relative_to(path, artifact_dir), sha256(content)}
      end)
      |> Map.new()

    Map.merge(%{schema_version: "lemon_sim.hashes.v1", files: files}, extra)
  end

  def manifest_artifact(state, scenario_id, version, hashes, opts) do
    now = artifact_timestamp(opts)

    %{
      schema_version: "lemon_sim.run.v1",
      sim: %{
        id: scenario_id,
        version: version,
        ruleset_hash: Keyword.get(opts, :ruleset_hash),
        seed: get(state.world, :seed)
      },
      agent: model_artifact(Keyword.get(opts, :model)),
      runtime: %{
        lemon_commit: git_commit(),
        elixir: System.version(),
        otp: :erlang.system_info(:otp_release) |> to_string(),
        started_at: Keyword.get(opts, :started_at, now),
        finished_at: Keyword.get(opts, :finished_at, now)
      },
      integrity: %{
        events_sha256: get_in(hashes, [:files, "events.jsonl"]),
        scorecard_sha256: get_in(hashes, [:files, "scorecard.json"]),
        usage_sha256: get_in(hashes, [:files, "usage.json"])
      }
    }
    |> jsonable()
  end

  def encode_json(value), do: Jason.encode!(jsonable(value), pretty: true)

  def jsonl(entries) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, index} -> Jason.encode!(jsonable_artifact_entry(entry, index)) end)
    |> Enum.join("\n")
    |> then(fn
      "" -> ""
      content -> content <> "\n"
    end)
  end

  def jsonable_artifact_entry(%{ts_ms: _} = entry, index) do
    entry
    |> jsonable()
    |> Map.put("ts_ms", index)
  end

  def jsonable_artifact_entry(%{"ts_ms" => _} = entry, index) do
    entry
    |> jsonable()
    |> Map.put("ts_ms", index)
  end

  def jsonable_artifact_entry(entry, _index), do: jsonable(entry)

  def jsonable(%MapSet{} = value), do: value |> MapSet.to_list() |> jsonable()
  def jsonable(%_{} = value), do: value |> Map.from_struct() |> jsonable()

  def jsonable(%{} = value) do
    Enum.reduce(value, %{}, fn {key, val}, acc ->
      string_key = to_string(key)

      if is_atom(key) or not Map.has_key?(acc, string_key) do
        Map.put(acc, string_key, jsonable(val))
      else
        acc
      end
    end)
  end

  def jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  def jsonable(value), do: value

  def artifact_timestamp(opts) do
    cond do
      is_binary(Keyword.get(opts, :artifact_timestamp)) ->
        Keyword.fetch!(opts, :artifact_timestamp)

      Keyword.get(opts, :deterministic_artifacts?, false) ->
        @deterministic_artifact_timestamp

      true ->
        DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  def git_commit do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {commit, 0} -> String.trim(commit)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def model_artifact(nil), do: nil

  def model_artifact(model) do
    %{
      provider: get(model, :provider),
      id: get(model, :id, get(model, :name)),
      name: get(model, :name)
    }
  end

  def sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  def get(map, key, default \\ nil)

  def get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  def get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  def get(_map, _key, default), do: default

  defp put_if_missing(map, key, value) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) and not is_nil(Map.get(map, key)) -> map
      Map.has_key?(map, string_key) and not is_nil(Map.get(map, string_key)) -> map
      true -> Map.put(map, key, value)
    end
  end

  defp usage_artifact(state, opts) do
    case Keyword.get(opts, :usage) do
      nil -> Usage.artifact(Keyword.get(opts, :usage_collector), state.sim_id)
      usage -> usage
    end
  end
end
