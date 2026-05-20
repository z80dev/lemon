defmodule LemonCore.Doctor.CronDiagnostics do
  @moduledoc """
  Redacted diagnostics for cron jobs and scheduled-run history.
  """

  @default_limit 20

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    jobs = store_entries(:cron_jobs)
    runs = store_entries(:cron_runs)
    audit_events = store_entries(:cron_audit_events)

    %{
      job_count: length(jobs),
      enabled_count: Enum.count(jobs, &truthy?(get_value(&1.data, :enabled))),
      disabled_count: Enum.count(jobs, &(not truthy?(get_value(&1.data, :enabled)))),
      run_count: length(runs),
      active_run_count: Enum.count(runs, &(run_status(&1.data) in ["pending", "running"])),
      failed_run_count: Enum.count(runs, &(run_status(&1.data) in ["failed", "timeout"])),
      next_run_at_ms: min_present(Enum.map(jobs, &integer_value(&1.data, :next_run_at_ms))),
      last_run_at_ms: max_present(Enum.map(runs, &integer_value(&1.data, :started_at_ms))),
      status_counts: runs |> Enum.map(&run_status(&1.data)) |> Enum.frequencies(),
      trigger_counts:
        runs |> Enum.map(&string_value(&1.data, :triggered_by)) |> Enum.frequencies(),
      audit_event_count: length(audit_events),
      audit_action_counts:
        audit_events
        |> Enum.map(&string_value(&1.data, :action))
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies(),
      recent_jobs:
        jobs
        |> Enum.sort_by(&timestamp_sort(&1.data, [:updated_at_ms, :created_at_ms]), :desc)
        |> Enum.take(limit)
        |> Enum.map(&format_job/1),
      recent_runs:
        runs
        |> Enum.sort_by(&timestamp_sort(&1.data, [:started_at_ms, :completed_at_ms]), :desc)
        |> Enum.take(limit)
        |> Enum.map(&format_run/1),
      recent_audit_events:
        audit_events
        |> Enum.sort_by(&timestamp_sort(&1.data, [:ts_ms]), :desc)
        |> Enum.take(limit)
        |> Enum.map(&format_audit_event/1),
      cleanup: %{
        includes_prompts: false,
        includes_commands: false,
        includes_outputs: false,
        includes_errors: false,
        includes_raw_session_ids: false,
        includes_raw_agent_ids: false,
        includes_raw_memory_paths: false,
        includes_meta_values: false,
        includes_raw_audit_ids: false
      }
    }
  rescue
    _ ->
      empty_status()
  catch
    _, _ -> empty_status()
  end

  defp store_entries(table) do
    table
    |> LemonCore.Store.list()
    |> Enum.map(fn {id, data} -> %{id: to_string(id), data: normalize_map(data)} end)
  end

  defp format_job(%{id: id, data: job}) do
    prompt = string_value(job, :prompt)
    command = string_value(job, :command)
    memory_file = string_value(job, :memory_file)
    name = string_value(job, :name)

    %{
      id_hash: hash(id),
      name_hash: hash(name),
      name_chars: char_count(name),
      schedule_hash: hash(string_value(job, :schedule)),
      schedule_present: present?(string_value(job, :schedule)),
      mode: job_mode(job),
      enabled: truthy?(get_value(job, :enabled)),
      timezone: safe_timezone(string_value(job, :timezone)),
      jitter_sec: integer_value(job, :jitter_sec) || 0,
      timeout_ms: integer_value(job, :timeout_ms),
      max_retries: integer_value(job, :max_retries) || 0,
      retry_backoff_ms: integer_value(job, :retry_backoff_ms) || 30_000,
      agent_id_hash: hash(string_value(job, :agent_id)),
      session_key_hash: hash(string_value(job, :session_key)),
      prompt_hash: hash(prompt),
      prompt_chars: char_count(prompt),
      command_hash: hash(command),
      command_chars: char_count(command),
      cwd_hash: hash(string_value(job, :cwd)),
      env_keys: meta_keys(get_value(job, :env)),
      memory_file_hash: hash(memory_file),
      memory_file_present: present?(memory_file),
      created_at_ms: integer_value(job, :created_at_ms),
      updated_at_ms: integer_value(job, :updated_at_ms),
      last_run_at_ms: integer_value(job, :last_run_at_ms),
      next_run_at_ms: integer_value(job, :next_run_at_ms),
      meta_keys: meta_keys(get_value(job, :meta))
    }
  end

  defp format_run(%{id: id, data: run}) do
    output = string_value(run, :output)
    error = string_value(run, :error)
    meta = normalize_map(get_value(run, :meta))

    %{
      id_hash: hash(id),
      job_id_hash: hash(string_value(run, :job_id)),
      router_run_id_hash: hash(string_value(run, :run_id)),
      status: run_status(run),
      triggered_by: string_value(run, :triggered_by),
      retry_attempt: integer_value(meta, :retry_attempt) || 0,
      retry_of_hash: hash(string_value(meta, :retry_of)),
      retry_root_id_hash: hash(string_value(meta, :retry_root_id)),
      started_at_ms: integer_value(run, :started_at_ms),
      completed_at_ms: integer_value(run, :completed_at_ms),
      duration_ms: integer_value(run, :duration_ms),
      suppressed: truthy?(get_value(run, :suppressed)),
      output_present: present?(output),
      output_hash: hash(output),
      output_chars: char_count(output),
      error_present: present?(error),
      error_hash: hash(error),
      error_chars: char_count(error),
      agent_id_hash: hash(string_value(meta, :agent_id)),
      session_key_hash: hash(string_value(meta, :session_key)),
      meta_keys: meta_keys(meta)
    }
  end

  defp format_audit_event(%{id: id, data: event}) do
    %{
      id_hash: hash(id),
      action: string_value(event, :action),
      ts_ms: integer_value(event, :ts_ms),
      job_id_hash: hash(string_value(event, :job_id)),
      run_id_hash: hash(string_value(event, :run_id)),
      router_run_id_hash: hash(string_value(event, :router_run_id)),
      source: string_value(event, :source),
      status: string_value(event, :status),
      triggered_by: string_value(event, :triggered_by),
      reason_hash: hash(string_value(event, :reason)),
      reason_chars: char_count(string_value(event, :reason)),
      changed_fields: string_list(get_value(event, :changed_fields))
    }
  end

  defp empty_status do
    %{
      job_count: 0,
      enabled_count: 0,
      disabled_count: 0,
      run_count: 0,
      active_run_count: 0,
      failed_run_count: 0,
      next_run_at_ms: nil,
      last_run_at_ms: nil,
      status_counts: %{},
      trigger_counts: %{},
      audit_event_count: 0,
      audit_action_counts: %{},
      recent_jobs: [],
      recent_runs: [],
      recent_audit_events: [],
      cleanup: %{
        includes_prompts: false,
        includes_commands: false,
        includes_outputs: false,
        includes_errors: false,
        includes_raw_session_ids: false,
        includes_raw_agent_ids: false,
        includes_raw_memory_paths: false,
        includes_meta_values: false,
        includes_raw_audit_ids: false
      }
    }
  end

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}

  defp get_value(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, to_string(key)) -> Map.get(map, to_string(key))
      Map.has_key?(map, camelize(key)) -> Map.get(map, camelize(key))
      true -> nil
    end
  end

  defp get_value(_, _), do: nil

  defp string_value(map, key) do
    case get_value(map, key) do
      value when is_atom(value) -> Atom.to_string(value)
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      value when is_boolean(value) -> to_string(value)
      _ -> nil
    end
  end

  defp integer_value(map, key) do
    case get_value(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp run_status(run) do
    case string_value(run, :status) do
      status when status in ["pending", "running", "completed", "failed", "timeout", "aborted"] ->
        status

      _ ->
        "unknown"
    end
  end

  defp job_mode(job) do
    if present?(string_value(job, :command)), do: "command", else: "agent"
  end

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp string_list(_), do: []

  defp truthy?(value), do: value in [true, "true", "TRUE", "1", 1]

  defp present?(value), do: is_binary(value) and value != ""

  defp char_count(value) when is_binary(value), do: String.length(value)
  defp char_count(_), do: 0

  defp timestamp_sort(map, keys) do
    keys
    |> Enum.map(&integer_value(map, &1))
    |> Enum.find(0, &is_integer/1)
  end

  defp min_present(values) do
    values
    |> Enum.filter(&is_integer/1)
    |> Enum.min(fn -> nil end)
  end

  defp max_present(values) do
    values
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> nil end)
  end

  defp safe_timezone(nil), do: nil
  defp safe_timezone(timezone) when byte_size(timezone) <= 64, do: timezone
  defp safe_timezone(_), do: nil

  defp meta_keys(meta) when is_map(meta) do
    meta
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp meta_keys(_), do: []

  defp camelize(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> String.split("_")
    |> case do
      [first | rest] -> first <> Enum.map_join(rest, &String.capitalize/1)
      [] -> ""
    end
  end

  defp hash(nil), do: nil
  defp hash(""), do: nil

  defp hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
