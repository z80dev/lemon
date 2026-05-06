defmodule LemonSkills.Usage do
  @moduledoc """
  Persistent skill usage and curation metadata.

  Usage data is stored outside `SKILL.md` so agent-authored telemetry and
  curation state do not churn the skill instructions themselves.
  """

  alias LemonSkills.Config

  @states ~w(active stale archived pinned)
  @lock_retries 50
  @lock_sleep_ms 10
  @default_stale_after_days 30
  @default_archive_after_days 90

  @type scope :: :global | :project

  @doc """
  Return the usage metadata for a skill.
  """
  @spec get(String.t(), keyword()) :: map()
  def get(key, opts \\ []) when is_binary(key) do
    case resolve_usage_file(opts) do
      {:ok, path} ->
        path
        |> read_usage()
        |> get_in(["skills", key])
        |> normalize_record()

      :skip ->
        normalize_record(nil)
    end
  end

  @doc """
  Return a lifecycle report for all skills in the usage sidecar.

  The report is intentionally sidecar-backed: it summarizes skills that have
  usage/write telemetry, including agent-authored skills that are candidates
  for curation.
  """
  @spec report(keyword()) :: [map()]
  def report(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    stale_after_days = positive_integer(opts, :stale_after_days, @default_stale_after_days)
    archive_after_days = positive_integer(opts, :archive_after_days, @default_archive_after_days)

    case resolve_usage_file(opts) do
      {:ok, path} ->
        path
        |> read_usage()
        |> Map.get("skills", %{})
        |> Enum.map(fn {key, record} ->
          report_row(key, normalize_record(record), now, stale_after_days, archive_after_days)
        end)
        |> Enum.sort_by(fn row -> {candidate_rank(row), row.name} end)

      :skip ->
        []
    end
  end

  @doc """
  Record a successful `read_skill` load.
  """
  @spec record_load(map()) :: :ok | {:error, term()}
  def record_load(metadata) when is_map(metadata) do
    key = Map.get(metadata, :key)

    if present?(key) and ok_result?(Map.get(metadata, :result)) do
      update_skill(key, usage_opts(metadata), fn record ->
        now = now_iso8601()

        record
        |> ensure_state()
        |> increment("load_count")
        |> Map.put("last_loaded_at", now)
        |> maybe_put("last_view", Map.get(metadata, :view))
        |> maybe_put("last_tool_call_id", Map.get(metadata, :tool_call_id))
        |> maybe_put("last_session_key", Map.get(metadata, :session_key))
        |> maybe_put("last_run_id", Map.get(metadata, :run_id))
        |> maybe_put("source", Map.get(metadata, :source))
        |> maybe_put("path", Map.get(metadata, :path))
      end)
    else
      :ok
    end
  end

  @doc """
  Record a `skill_manage` write attempt.
  """
  @spec record_write(map()) :: :ok | {:error, term()}
  def record_write(metadata) when is_map(metadata) do
    key = Map.get(metadata, :name)

    if present?(key) do
      update_skill(key, usage_opts(metadata), fn record ->
        now = now_iso8601()
        action = Map.get(metadata, :action)

        record
        |> ensure_state()
        |> maybe_increment_write(Map.get(metadata, :result))
        |> maybe_increment_error(Map.get(metadata, :result))
        |> Map.put("last_write_at", now)
        |> maybe_put_created(action, metadata, now)
        |> maybe_put("last_action", action)
        |> maybe_put("last_writer_agent_id", Map.get(metadata, :agent_id))
        |> maybe_put("last_session_key", Map.get(metadata, :session_key))
        |> maybe_put("last_run_id", Map.get(metadata, :run_id))
        |> maybe_put("last_tool_call_id", Map.get(metadata, :tool_call_id))
        |> maybe_put("path", Map.get(metadata, :path))
        |> maybe_put("file_path", Map.get(metadata, :file_path))
      end)
    else
      :ok
    end
  end

  @doc """
  Set a lifecycle state for a skill.
  """
  @spec set_state(String.t(), String.t() | atom(), keyword()) :: :ok | {:error, term()}
  def set_state(key, state, opts \\ []) when is_binary(key) do
    state = state |> to_string()

    if state in @states do
      update_skill(key, opts, fn record ->
        now = now_iso8601()

        record
        |> ensure_state()
        |> Map.put("lifecycle_state", state)
        |> Map.put("state_updated_at", now)
        |> maybe_put("state_updated_by_agent_id", Keyword.get(opts, :agent_id))
      end)
    else
      {:error, "invalid lifecycle state: #{state}"}
    end
  end

  @doc """
  Return true when the skill is pinned in usage metadata.
  """
  @spec pinned?(String.t(), keyword()) :: boolean()
  def pinned?(key, opts \\ []) when is_binary(key) do
    get(key, opts)["lifecycle_state"] == "pinned"
  end

  @doc """
  Return true when the skill is archived in usage metadata.
  """
  @spec archived?(String.t(), keyword()) :: boolean()
  def archived?(key, opts \\ []) when is_binary(key) do
    get(key, opts)["lifecycle_state"] == "archived"
  end

  @doc """
  Return the sidecar path used for the given options.
  """
  @spec usage_file(keyword() | map()) :: String.t() | nil
  def usage_file(opts) when is_map(opts), do: usage_file(Map.to_list(opts))

  def usage_file(opts) when is_list(opts) do
    case resolve_usage_file(opts) do
      {:ok, path} -> path
      :skip -> nil
    end
  end

  defp resolve_usage_file(opts) when is_map(opts), do: resolve_usage_file(Map.to_list(opts))

  defp resolve_usage_file(opts) when is_list(opts) do
    case Keyword.get(opts, :scope, :global) do
      scope when scope in [:project, "project"] ->
        case Keyword.get(opts, :cwd) do
          cwd when is_binary(cwd) and cwd != "" -> {:ok, Config.project_usage_file(cwd)}
          _ -> :skip
        end

      _ ->
        {:ok, Config.global_usage_file()}
    end
  end

  defp update_skill(key, opts, fun) do
    case resolve_usage_file(opts) do
      {:ok, path} ->
        with_file_lock(path, fn ->
          usage = read_usage(path)
          skills = Map.get(usage, "skills", %{})
          record = skills |> Map.get(key, %{}) |> normalize_record() |> fun.()
          updated = Map.put(usage, "skills", Map.put(skills, key, record))
          write_usage(path, updated)
        end)

      :skip ->
        :ok
    end
  end

  defp usage_opts(metadata) do
    [
      scope: normalize_scope(Map.get(metadata, :scope) || Map.get(metadata, :source)),
      cwd: Map.get(metadata, :cwd)
    ]
  end

  defp normalize_scope("project"), do: :project
  defp normalize_scope(:project), do: :project
  defp normalize_scope(_), do: :global

  defp report_row(key, record, now, stale_after_days, archive_after_days) do
    last_activity_at = last_activity_at(record)
    idle_days = idle_days(last_activity_at, now)
    lifecycle_state = Map.get(record, "lifecycle_state", "active")
    agent_authored? = Map.get(record, "created_by") == "agent"
    protected? = lifecycle_state in ["pinned", "archived"]

    stale_candidate? =
      agent_authored? and not protected? and is_integer(idle_days) and
        idle_days >= stale_after_days

    archive_candidate? =
      agent_authored? and not protected? and is_integer(idle_days) and
        idle_days >= archive_after_days

    %{
      name: key,
      lifecycle_state: lifecycle_state,
      agent_authored: agent_authored?,
      load_count: integer_field(record, "load_count"),
      write_count: integer_field(record, "write_count"),
      write_error_count: integer_field(record, "write_error_count"),
      created_at: Map.get(record, "created_at"),
      last_loaded_at: Map.get(record, "last_loaded_at"),
      last_write_at: Map.get(record, "last_write_at"),
      last_activity_at: last_activity_at,
      idle_days: idle_days,
      stale_candidate: stale_candidate?,
      archive_candidate: archive_candidate?
    }
  end

  defp candidate_rank(%{archive_candidate: true}), do: 0
  defp candidate_rank(%{stale_candidate: true}), do: 1
  defp candidate_rank(_), do: 2

  defp last_activity_at(record) do
    ["last_loaded_at", "last_write_at", "created_at"]
    |> Enum.map(&Map.get(record, &1))
    |> Enum.filter(&is_binary/1)
    |> Enum.max_by(&timestamp_sort_value/1, fn -> nil end)
  end

  defp timestamp_sort_value(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> 0
    end
  end

  defp idle_days(nil, _now), do: nil

  defp idle_days(timestamp, now) do
    with {:ok, timestamp, _} <- DateTime.from_iso8601(timestamp) do
      max(DateTime.diff(now, timestamp, :day), 0)
    else
      _ -> nil
    end
  end

  defp integer_field(record, key) do
    case Map.get(record, key, 0) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  defp positive_integer(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp read_usage(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{} = data} -> data
          _ -> empty_usage()
        end

      _ ->
        empty_usage()
    end
  end

  defp write_usage(path, data) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, content} <- Jason.encode(data, pretty: true),
         :ok <- atomic_write(path, content) do
      :ok
    end
  end

  defp with_file_lock(path, fun) do
    lock_path = path <> ".lock"

    with :ok <- File.mkdir_p(Path.dirname(lock_path)) do
      acquire_lock(to_charlist(lock_path), fun, @lock_retries)
    end
  end

  defp acquire_lock(_lock_path, _fun, 0), do: {:error, :lock_timeout}

  defp acquire_lock(lock_path, fun, retries) do
    case :file.open(lock_path, [:write, :exclusive]) do
      {:ok, fd} ->
        try do
          fun.()
        after
          :file.close(fd)
          :file.delete(lock_path)
        end

      {:error, :eexist} ->
        Process.sleep(@lock_sleep_ms)
        acquire_lock(lock_path, fun, retries - 1)

      {:error, reason} ->
        {:error, {:lock_failed, reason}}
    end
  end

  defp atomic_write(path, content) do
    tmp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.tmp.#{System.unique_integer([:positive])}"
      )

    result =
      with :ok <- File.write(tmp, content),
           :ok <- File.rename(tmp, path) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  defp empty_usage, do: %{"version" => 1, "skills" => %{}}
  defp normalize_record(nil), do: ensure_state(%{})
  defp normalize_record(record) when is_map(record), do: ensure_state(record)
  defp normalize_record(_), do: ensure_state(%{})

  defp ensure_state(record) do
    Map.put_new(record, "lifecycle_state", "active")
  end

  defp increment(record, key) do
    Map.update(record, key, 1, fn
      value when is_integer(value) -> value + 1
      _ -> 1
    end)
  end

  defp maybe_increment_write(record, "ok"), do: increment(record, "write_count")
  defp maybe_increment_write(record, :ok), do: increment(record, "write_count")
  defp maybe_increment_write(record, _), do: record

  defp maybe_increment_error(record, "error"), do: increment(record, "write_error_count")
  defp maybe_increment_error(record, :error), do: increment(record, "write_error_count")
  defp maybe_increment_error(record, _), do: record

  defp maybe_put_created(record, action, %{result: result} = metadata, now)
       when action in ["create", :create] do
    if ok_result?(result) do
      put_created(record, metadata, now)
    else
      record
    end
  end

  defp maybe_put_created(record, action, metadata, now) when action in ["create", :create] do
    put_created(record, metadata, now)
  end

  defp maybe_put_created(record, _action, _metadata, _now), do: record

  defp put_created(record, metadata, now) do
    record
    |> Map.put_new("created_at", now)
    |> Map.put_new("created_by", "agent")
    |> maybe_put_new("created_by_agent_id", Map.get(metadata, :agent_id))
  end

  defp maybe_put(record, _key, nil), do: record
  defp maybe_put(record, _key, ""), do: record
  defp maybe_put(record, key, value), do: Map.put(record, key, value)

  defp maybe_put_new(record, _key, nil), do: record
  defp maybe_put_new(record, _key, ""), do: record
  defp maybe_put_new(record, key, value), do: Map.put_new(record, key, value)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp ok_result?(value), do: value in [:ok, "ok"]
  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
