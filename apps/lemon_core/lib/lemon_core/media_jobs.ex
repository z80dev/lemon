defmodule LemonCore.MediaJobs do
  @moduledoc """
  Redacted metadata store for generated media jobs and artifacts.
  """

  @default_limit 20
  @default_retention_days 30
  @default_max_jobs 500
  @default_max_artifacts 250
  @types [:media, :image, :video, :audio, :tts, :stt, :vision, :browser]
  @statuses [:queued, :running, :completed, :failed, :cancelled]

  @known_fields [
    :job_id,
    :type,
    :status,
    :provider,
    :model,
    :channel,
    :artifact,
    :prompt_hash,
    :prompt_chars,
    :error_hash,
    :error_kind,
    :created_at,
    :updated_at
  ]

  @spec default_dir(String.t()) :: String.t()
  def default_dir(project_dir \\ File.cwd!()) do
    Path.expand(Path.join([project_dir, ".lemon", "media-jobs"]))
  end

  @spec default_artifacts_dir(String.t()) :: String.t()
  def default_artifacts_dir(project_dir \\ File.cwd!()) do
    Path.expand(Path.join([project_dir, ".lemon", "media-artifacts"]))
  end

  @spec record(map() | keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def record(attrs, opts \\ []) when is_map(attrs) or is_list(attrs) do
    attrs = attrs_map(attrs)
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    dir = opts |> Keyword.get(:dir, default_dir(project_dir)) |> Path.expand()
    now = attrs |> get_attr(:created_at, DateTime.utc_now() |> DateTime.to_iso8601())
    job_id = attrs |> get_attr(:job_id, generated_job_id(now)) |> normalize_id()

    job =
      %{
        job_id: job_id,
        type: attrs |> get_attr(:type, :media) |> normalize_type(),
        status: attrs |> get_attr(:status, :queued) |> normalize_status(),
        provider: redacted_label(get_attr(attrs, :provider)),
        model: redacted_label(get_attr(attrs, :model)),
        channel: redacted_label(get_attr(attrs, :channel)),
        artifact: artifact_metadata(attrs),
        prompt_hash: hashed_optional(get_attr(attrs, :prompt)),
        prompt_chars: char_count(get_attr(attrs, :prompt)),
        error_hash: hashed_optional(get_attr(attrs, :error)),
        error_kind: redacted_label(get_attr(attrs, :error_kind)),
        created_at: now,
        updated_at: get_attr(attrs, :updated_at, now)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(job_path(dir, job_id), Jason.encode!(job, pretty: true)) do
      {:ok, job}
    end
  end

  @spec recent(keyword()) :: [map()]
  def recent(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    dir = opts |> Keyword.get(:dir, default_dir(project_dir)) |> Path.expand()
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()

    dir
    |> jobs()
    |> Enum.sort_by(& &1.created_at_unix, :desc)
    |> Enum.take(limit)
    |> Enum.map(&Map.delete(&1, :created_at_unix))
  end

  @spec summary(keyword()) :: map()
  def summary(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    dir = opts |> Keyword.get(:dir, default_dir(project_dir)) |> Path.expand()

    artifacts_dir =
      opts |> Keyword.get(:artifacts_dir, default_artifacts_dir(project_dir)) |> Path.expand()

    jobs = jobs(dir)
    artifacts = artifact_files(artifacts_dir)

    %{
      dir: dir,
      artifacts_dir: artifacts_dir,
      exists: File.dir?(dir),
      count: length(jobs),
      status_counts: count_by(jobs, :status),
      type_counts: count_by(jobs, :type),
      artifact_count: length(artifacts),
      artifact_total_bytes: Enum.reduce(artifacts, 0, &(&1.bytes + &2)),
      oldest_created_at: created_boundary(jobs, :oldest),
      newest_created_at: created_boundary(jobs, :newest),
      cleanup: cleanup_policy()
    }
  end

  @spec cleanup(keyword()) :: map()
  def cleanup(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    dir = opts |> Keyword.get(:dir, default_dir(project_dir)) |> Path.expand()

    artifacts_dir =
      opts |> Keyword.get(:artifacts_dir, default_artifacts_dir(project_dir)) |> Path.expand()

    max_age_seconds =
      opts |> Keyword.get(:max_age_seconds, default_max_age_seconds()) |> normalize_age()

    max_jobs = opts |> Keyword.get(:max_jobs, @default_max_jobs) |> normalize_max_items()

    max_artifacts =
      opts |> Keyword.get(:max_artifacts, @default_max_artifacts) |> normalize_max_items()

    now = opts |> Keyword.get(:now, System.system_time(:second)) |> normalize_now()

    deleted_jobs = prune_files(job_files(dir), max_age_seconds, max_jobs, now)

    deleted_artifacts =
      prune_files(artifact_files(artifacts_dir), max_age_seconds, max_artifacts, now)

    %{
      dir: dir,
      artifacts_dir: artifacts_dir,
      deleted_jobs_count: length(deleted_jobs),
      deleted_artifacts_count: length(deleted_artifacts),
      deleted_artifact_bytes: Enum.reduce(deleted_artifacts, 0, &(&1.bytes + &2)),
      cleanup: cleanup_policy(max_age_seconds, max_jobs, max_artifacts)
    }
  end

  defp jobs(dir) do
    dir
    |> job_files()
    |> Enum.flat_map(fn %{path: path, modified_at_unix: fallback_unix} ->
      case File.read(path) do
        {:ok, content} ->
          [decode_job(content, fallback_unix)]

        {:error, _reason} ->
          []
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_job(content, fallback_unix) do
    with {:ok, decoded} <- Jason.decode(content),
         job when map_size(job) > 0 <- atomize_job(decoded) do
      Map.put(job, :created_at_unix, timestamp_unix(job[:created_at], fallback_unix))
    else
      _ -> nil
    end
  end

  defp atomize_job(decoded) do
    @known_fields
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.fetch(decoded, Atom.to_string(key)) do
        {:ok, value} -> Map.put(acc, key, decode_value(key, value))
        :error -> acc
      end
    end)
  end

  defp decode_value(:type, value), do: normalize_type(value)
  defp decode_value(:status, value), do: normalize_status(value)
  defp decode_value(:artifact, value) when is_map(value), do: atomize_artifact(value)
  defp decode_value(_key, value), do: value

  defp atomize_artifact(value) do
    [:name, :path_hash, :mime_type, :bytes, :exists]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.fetch(value, Atom.to_string(key)) do
        {:ok, artifact_value} -> Map.put(acc, key, artifact_value)
        :error -> acc
      end
    end)
  end

  defp job_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&file_info(dir, &1))
        |> Enum.reject(&is_nil/1)

      {:error, _reason} ->
        []
    end
  end

  defp artifact_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.map(&file_info(dir, &1))
        |> Enum.reject(&is_nil/1)

      {:error, _reason} ->
        []
    end
  end

  defp file_info(dir, name) do
    path = Path.join(dir, name)

    with true <- File.regular?(path),
         {:ok, stat} <- File.stat(path, time: :posix) do
      %{
        name: name,
        path: path,
        bytes: stat.size,
        modified_at_unix: stat.mtime
      }
    else
      _ -> nil
    end
  end

  defp prune_files(files, max_age_seconds, max_files, now) do
    cutoff = now - max_age_seconds

    by_age =
      files
      |> Enum.filter(&(&1.modified_at_unix < cutoff))
      |> MapSet.new()

    by_count =
      files
      |> Enum.sort_by(& &1.modified_at_unix, :desc)
      |> Enum.drop(max_files)
      |> MapSet.new()

    by_age
    |> MapSet.union(by_count)
    |> Enum.filter(&delete_file/1)
  end

  defp delete_file(%{path: path}) do
    case File.rm(path) do
      :ok -> true
      {:error, :enoent} -> true
      {:error, _reason} -> false
    end
  end

  defp artifact_metadata(attrs) do
    path = get_attr(attrs, :artifact_path)
    name = get_attr(attrs, :artifact_name) || maybe_basename(path)
    bytes = get_attr(attrs, :bytes) || artifact_bytes(path)

    if is_nil(path) and is_nil(name) and is_nil(bytes) and is_nil(get_attr(attrs, :mime_type)) do
      nil
    else
      %{
        name: redacted_label(name),
        path_hash: hashed_optional(path),
        mime_type: redacted_label(get_attr(attrs, :mime_type)),
        bytes: normalize_bytes(bytes),
        exists: artifact_exists?(path)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end

  defp artifact_bytes(nil), do: nil

  defp artifact_bytes(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      {:error, _reason} -> nil
    end
  end

  defp artifact_bytes(_path), do: nil

  defp artifact_exists?(nil), do: nil
  defp artifact_exists?(path) when is_binary(path), do: File.regular?(path)
  defp artifact_exists?(_path), do: nil

  defp maybe_basename(path) when is_binary(path), do: Path.basename(path)
  defp maybe_basename(_path), do: nil

  defp count_by(jobs, key) do
    jobs
    |> Enum.group_by(&Map.get(&1, key))
    |> Map.new(fn {value, grouped} -> {value, length(grouped)} end)
  end

  defp created_boundary([], _boundary), do: nil

  defp created_boundary(jobs, :oldest) do
    jobs
    |> Enum.min_by(& &1.created_at_unix)
    |> Map.get(:created_at)
  end

  defp created_boundary(jobs, :newest) do
    jobs
    |> Enum.max_by(& &1.created_at_unix)
    |> Map.get(:created_at)
  end

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)

  defp get_attr(attrs, key, default \\ nil) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) || default
  end

  defp job_path(dir, job_id), do: Path.join(dir, "#{job_id}.json")

  defp generated_job_id(now) do
    entropy = "#{now}:#{System.unique_integer([:positive])}"
    "media_" <> hash(entropy, 12)
  end

  defp normalize_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
    |> String.slice(0, 80)
    |> case do
      "" -> generated_job_id(DateTime.utc_now() |> DateTime.to_iso8601())
      id -> id
    end
  end

  defp normalize_type(type), do: normalize_atom(type, @types, :media)
  defp normalize_status(status), do: normalize_atom(status, @statuses, :queued)

  defp normalize_atom(value, allowed, default) when is_atom(value) do
    if value in allowed, do: value, else: default
  end

  defp normalize_atom(value, allowed, default) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> case do
      "" -> default
      normalized -> Enum.find(allowed, default, &(Atom.to_string(&1) == normalized))
    end
  end

  defp normalize_atom(_value, _allowed, default), do: default

  defp redacted_label(nil), do: nil

  defp redacted_label(value) do
    value
    |> to_string()
    |> String.slice(0, 120)
  end

  defp hashed_optional(nil), do: nil
  defp hashed_optional(value), do: hash(to_string(value), 16)

  defp hash(value, size) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> String.slice(0, size)
  end

  defp char_count(nil), do: nil
  defp char_count(value), do: value |> to_string() |> String.length()

  defp normalize_bytes(nil), do: nil
  defp normalize_bytes(bytes) when is_integer(bytes), do: max(bytes, 0)

  defp normalize_bytes(bytes) when is_binary(bytes) do
    case Integer.parse(bytes) do
      {int, ""} -> normalize_bytes(int)
      _ -> nil
    end
  end

  defp normalize_bytes(_bytes), do: nil

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(0) |> min(100)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, ""} -> normalize_limit(int)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_limit), do: @default_limit

  defp normalize_age(age) when is_integer(age), do: max(age, 0)

  defp normalize_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {int, ""} -> normalize_age(int)
      _ -> default_max_age_seconds()
    end
  end

  defp normalize_age(_age), do: default_max_age_seconds()

  defp normalize_max_items(count) when is_integer(count), do: count |> max(0) |> min(10_000)

  defp normalize_max_items(count) when is_binary(count) do
    case Integer.parse(count) do
      {int, ""} -> normalize_max_items(int)
      _ -> @default_max_jobs
    end
  end

  defp normalize_max_items(_count), do: @default_max_jobs

  defp normalize_now(now) when is_integer(now), do: now
  defp normalize_now(_now), do: System.system_time(:second)

  defp timestamp_unix(nil, fallback), do: fallback

  defp timestamp_unix(value, fallback) do
    case DateTime.from_iso8601(to_string(value)) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      {:error, _reason} -> fallback
    end
  end

  defp default_max_age_seconds, do: @default_retention_days * 24 * 60 * 60

  defp cleanup_policy(
         max_age_seconds \\ default_max_age_seconds(),
         max_jobs \\ @default_max_jobs,
         max_artifacts \\ @default_max_artifacts
       ) do
    days = div(max_age_seconds, 24 * 60 * 60)

    %{
      managed: true,
      policy: "managed: #{days}d or #{max_jobs} jobs / #{max_artifacts} artifacts",
      max_age_days: days,
      max_jobs: max_jobs,
      max_artifacts: max_artifacts,
      safe_to_delete: true,
      embeds_artifact_bytes_in_support_bundle: false,
      includes_raw_paths: false,
      includes_prompts: false,
      includes_provider_responses: false,
      includes_channel_message_bodies: false
    }
  end
end
