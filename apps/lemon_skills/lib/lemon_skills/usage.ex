defmodule LemonSkills.Usage do
  @moduledoc """
  Persistent skill usage and curation metadata.

  Usage data is stored outside `SKILL.md` so agent-authored telemetry and
  curation state do not churn the skill instructions themselves.
  """

  alias LemonSkills.Config

  @states ~w(active stale archived pinned)

  @type scope :: :global | :project

  @doc """
  Return the usage metadata for a skill.
  """
  @spec get(String.t(), keyword()) :: map()
  def get(key, opts \\ []) when is_binary(key) do
    opts
    |> usage_file()
    |> read_usage()
    |> get_in(["skills", key])
    |> normalize_record()
  end

  @doc """
  Record a successful `read_skill` load.
  """
  @spec record_load(map()) :: :ok | {:error, term()}
  def record_load(metadata) when is_map(metadata) do
    key = Map.get(metadata, :key)

    if present?(key) do
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
  @spec usage_file(keyword() | map()) :: String.t()
  def usage_file(opts) when is_map(opts), do: usage_file(Map.to_list(opts))

  def usage_file(opts) when is_list(opts) do
    case Keyword.get(opts, :scope, :global) do
      :project -> Config.project_usage_file(Keyword.fetch!(opts, :cwd))
      "project" -> Config.project_usage_file(Keyword.fetch!(opts, :cwd))
      _ -> Config.global_usage_file()
    end
  end

  defp update_skill(key, opts, fun) do
    path = usage_file(opts)
    usage = read_usage(path)
    skills = Map.get(usage, "skills", %{})
    record = skills |> Map.get(key, %{}) |> normalize_record() |> fun.()
    updated = Map.put(usage, "skills", Map.put(skills, key, record))
    write_usage(path, updated)
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
         {:ok, content} <- Jason.encode(data, pretty: true) do
      File.write(path, content)
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

  defp maybe_put_created(record, action, metadata, now) when action in ["create", :create] do
    record
    |> Map.put_new("created_at", now)
    |> Map.put_new("created_by", "agent")
    |> maybe_put_new("created_by_agent_id", Map.get(metadata, :agent_id))
  end

  defp maybe_put_created(record, _action, _metadata, _now), do: record

  defp maybe_put(record, _key, nil), do: record
  defp maybe_put(record, _key, ""), do: record
  defp maybe_put(record, key, value), do: Map.put(record, key, value)

  defp maybe_put_new(record, _key, nil), do: record
  defp maybe_put_new(record, _key, ""), do: record
  defp maybe_put_new(record, key, value), do: Map.put_new(record, key, value)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
