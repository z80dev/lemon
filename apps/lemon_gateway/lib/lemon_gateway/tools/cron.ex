defmodule LemonGateway.Tools.Cron do
  @moduledoc """
  AgentCore tool for managing Lemon internal cron/scheduled jobs.

  Supports actions to list, add, update, remove, and trigger cron jobs, as well
  as viewing run history. Delegates to `LemonAutomation.CronManager` for
  persistence and scheduling.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @actions ~w(status list add update remove run runs)
  @default_timeout_ms 300_000
  @default_limit 100

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session_key = normalize_string(Keyword.get(opts, :session_key))
    agent_id = normalize_string(Keyword.get(opts, :agent_id))

    %AgentTool{
      name: "cron",
      label: "Cron",
      description:
        "Manage Lemon internal cron jobs (not OS crontab): status, list, add, update, remove, run, and runs.",
      parameters: tool_schema(),
      execute: &execute(&1, &2, &3, &4, session_key, agent_id)
    }
  end

  def execute(_tool_call_id, params, _signal, _on_update, session_key, default_agent_id)
      when is_map(params) do
    action = normalize_string(fetch_param(params, "action"))

    with :ok <- ensure_scheduler_started(),
         {:ok, {title, payload}} <- dispatch(action, params, session_key, default_agent_id) do
      success_result(title, payload)
    else
      {:error, message} ->
        error_result(message)
    end
  end

  def execute(_tool_call_id, _params, _signal, _on_update, _session_key, _default_agent_id) do
    error_result("Invalid parameters (expected object).")
  end

  defp tool_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => @actions,
          "description" => "Cron action: status, list, add, update, remove, run, or runs."
        },
        "includeDisabled" => %{
          "type" => "boolean",
          "description" => "For list: include disabled jobs (default: true)."
        },
        "id" => %{
          "type" => "string",
          "description" => "Job id (update/remove/run/runs)."
        },
        "jobId" => %{
          "type" => "string",
          "description" => "Alias for id (update/remove/run/runs)."
        },
        "name" => %{
          "type" => "string",
          "description" => "Job name (add/update)."
        },
        "schedule" => %{
          "type" => "string",
          "description" => "Cron expression with 5 fields, for example: '0 9 * * *'."
        },
        "prompt" => %{
          "type" => "string",
          "description" => "Prompt text to run when the job fires."
        },
        "enabled" => %{
          "type" => "boolean",
          "description" => "Whether the job is enabled (add/update)."
        },
        "timezone" => %{
          "type" => "string",
          "description" => "Timezone for schedule (default: UTC)."
        },
        "jitterSec" => %{
          "type" => "integer",
          "description" => "Optional jitter spread in seconds."
        },
        "timeoutMs" => %{
          "type" => "integer",
          "description" => "Optional timeout in milliseconds (default: 300000)."
        },
        "agentId" => %{
          "type" => "string",
          "description" =>
            "Optional agent id for add. Defaults to current session agent id when available."
        },
        "sessionKey" => %{
          "type" => "string",
          "description" =>
            "Optional session key for add. Defaults to current session key when available."
        },
        "limit" => %{
          "type" => "integer",
          "description" => "For runs: max number of run records (default: 100)."
        },
        "meta" => %{
          "type" => "object",
          "description" => "Optional metadata map for add/update.",
          "additionalProperties" => true
        },
        "job" => %{
          "type" => "object",
          "description" => "Optional wrapper object for add fields.",
          "additionalProperties" => true
        },
        "patch" => %{
          "type" => "object",
          "description" => "Optional wrapper object for update fields.",
          "additionalProperties" => true
        }
      },
      "required" => ["action"]
    }
  end

  defp dispatch("status", _params, _session_key, _default_agent_id) do
    with {:ok, jobs} <- cron_call(:list, []) do
      payload = %{
        "enabled" => true,
        "jobCount" => length(jobs),
        "activeJobs" => Enum.count(jobs, &truthy?(Map.get(&1, :enabled))),
        "nextRunAtMs" => next_run_ms(jobs)
      }

      {:ok, {"Cron status", payload}}
    end
  end

  defp dispatch("list", params, _session_key, _default_agent_id) do
    include_disabled = parse_bool(fetch_param(params, "includeDisabled"), true)
    agent_id = normalize_string(fetch_param(params, "agentId") || fetch_param(params, "agent_id"))

    with {:ok, jobs} <- cron_call(:list, []) do
      payload =
        jobs
        |> maybe_filter_enabled(include_disabled)
        |> maybe_filter_agent(agent_id)
        |> Enum.map(&format_job/1)
        |> then(&%{"jobs" => &1})

      {:ok, {"Cron jobs", payload}}
    end
  end

  defp dispatch("add", params, session_key, default_agent_id) do
    source = nested_map(params, "job") || params

    schedule = normalize_string(fetch_param(source, "schedule"))
    prompt = normalize_string(fetch_param(source, "prompt") || fetch_param(source, "message"))
    name = normalize_string(fetch_param(source, "name")) || default_name(prompt)
    agent_id = resolve_agent_id(source, session_key, default_agent_id)
    target_session_key = resolve_session_key(source, session_key, agent_id)

    cond do
      is_nil(schedule) ->
        {:error, "schedule is required for action=add"}

      is_nil(prompt) ->
        {:error, "prompt is required for action=add"}

      not LemonCore.SessionKey.valid?(target_session_key) ->
        {:error, "sessionKey must be a valid Lemon session key"}

      true ->
        meta = fetch_param(source, "meta")

        add_params =
          %{
            name: name,
            schedule: schedule,
            agent_id: agent_id,
            session_key: target_session_key,
            prompt: prompt,
            enabled: parse_bool(fetch_param(source, "enabled"), true),
            timezone: normalize_string(fetch_param(source, "timezone")) || "UTC",
            jitter_sec:
              parse_non_negative_integer(
                fetch_param(source, "jitterSec") || fetch_param(source, "jitter_sec"),
                0
              ),
            timeout_ms:
              parse_positive_integer(
                fetch_param(source, "timeoutMs") || fetch_param(source, "timeout_ms"),
                @default_timeout_ms
              )
          }
          |> maybe_put(:meta, if(is_map(meta), do: meta, else: nil))

        case cron_call(:add, [add_params]) do
          {:ok, {:ok, job}} ->
            payload = format_job(job)
            {:ok, {"Cron job added", payload}}

          {:ok, {:error, {:missing_keys, keys}}} ->
            {:error, "Missing required fields: #{inspect(keys)}"}

          {:ok, {:error, {:invalid_schedule, reason}}} ->
            {:error, "Invalid schedule: #{reason}"}

          {:ok, {:error, reason}} ->
            {:error, "Failed to add cron job: #{inspect(reason)}"}

          {:error, _} = error ->
            error
        end
    end
  end

  defp dispatch("update", params, _session_key, _default_agent_id) do
    job_id = resolve_job_id(params)
    patch_source = nested_map(params, "patch") || params

    patch =
      %{}
      |> maybe_put(:name, normalize_string(fetch_param(patch_source, "name")))
      |> maybe_put(:schedule, normalize_string(fetch_param(patch_source, "schedule")))
      |> maybe_put(
        :prompt,
        normalize_string(
          fetch_param(patch_source, "prompt") || fetch_param(patch_source, "message")
        )
      )
      |> maybe_put(:timezone, normalize_string(fetch_param(patch_source, "timezone")))
      |> maybe_put(:enabled, parse_bool_or_nil(fetch_param(patch_source, "enabled")))
      |> maybe_put(
        :jitter_sec,
        parse_non_negative_integer_or_nil(
          fetch_param(patch_source, "jitterSec") || fetch_param(patch_source, "jitter_sec")
        )
      )
      |> maybe_put(
        :timeout_ms,
        parse_positive_integer_or_nil(
          fetch_param(patch_source, "timeoutMs") || fetch_param(patch_source, "timeout_ms")
        )
      )
      |> maybe_put(
        :meta,
        if(is_map(fetch_param(patch_source, "meta")),
          do: fetch_param(patch_source, "meta"),
          else: nil
        )
      )

    cond do
      is_nil(job_id) ->
        {:error, "id (or jobId) is required for action=update"}

      map_size(patch) == 0 ->
        {:error, "No update fields were provided"}

      true ->
        case cron_call(:update, [job_id, patch]) do
          {:ok, {:ok, job}} ->
            payload = %{
              "id" => Map.get(job, :id),
              "updated" => true,
              "nextRunAtMs" => Map.get(job, :next_run_at_ms)
            }

            {:ok, {"Cron job updated", payload}}

          {:ok, {:error, :not_found}} ->
            {:error, "Cron job not found: #{job_id}"}

          {:ok, {:error, reason}} ->
            {:error, "Failed to update cron job: #{inspect(reason)}"}

          {:error, _} = error ->
            error
        end
    end
  end

  defp dispatch("remove", params, _session_key, _default_agent_id) do
    with {:ok, job_id} <- require_job_id(params) do
      case cron_call(:remove, [job_id]) do
        {:ok, :ok} ->
          {:ok, {"Cron job removed", %{"removed" => true, "id" => job_id}}}

        {:ok, {:error, :not_found}} ->
          {:error, "Cron job not found: #{job_id}"}

        {:ok, {:error, reason}} ->
          {:error, "Failed to remove cron job: #{inspect(reason)}"}

        {:error, _} = error ->
          error
      end
    end
  end

  defp dispatch("run", params, _session_key, _default_agent_id) do
    with {:ok, job_id} <- require_job_id(params) do
      case cron_call(:run_now, [job_id]) do
        {:ok, {:ok, run}} ->
          payload = %{"triggered" => true, "jobId" => job_id, "runId" => Map.get(run, :id)}
          {:ok, {"Cron job triggered", payload}}

        {:ok, {:error, :not_found}} ->
          {:error, "Cron job not found: #{job_id}"}

        {:ok, {:error, reason}} ->
          {:error, "Failed to run cron job: #{inspect(reason)}"}

        {:error, _} = error ->
          error
      end
    end
  end

  defp dispatch("runs", params, _session_key, _default_agent_id) do
    with {:ok, job_id} <- require_job_id(params) do
      limit = parse_positive_integer(fetch_param(params, "limit"), @default_limit)

      case cron_call(:runs, [job_id, [limit: limit]]) do
        {:ok, runs} when is_list(runs) ->
          payload = %{"jobId" => job_id, "runs" => Enum.map(runs, &format_run/1)}
          {:ok, {"Cron run history", payload}}

        {:ok, other} ->
          {:error, "Unexpected cron.runs response: #{inspect(other)}"}

        {:error, _} = error ->
          error
      end
    end
  end

  defp dispatch(nil, _params, _session_key, _default_agent_id),
    do: {:error, "action is required"}

  defp dispatch(action, _params, _session_key, _default_agent_id),
    do: {:error, "Unknown action '#{action}'. Supported: #{Enum.join(@actions, ", ")}"}

  defp ensure_scheduler_started do
    manager = cron_manager()

    cond do
      is_pid(Process.whereis(manager)) ->
        :ok

      true ->
        case Application.ensure_all_started(:lemon_automation) do
          {:ok, _} ->
            if is_pid(Process.whereis(manager)) do
              :ok
            else
              {:error, "Cron scheduler is unavailable (LemonAutomation.CronManager not started)."}
            end

          {:error, {app, reason}} ->
            {:error, "Failed to start #{app}: #{inspect(reason)}"}
        end
    end
  rescue
    e ->
      {:error, "Failed to start cron scheduler: #{Exception.message(e)}"}
  end

  defp cron_call(function, args) do
    manager = cron_manager()

    if Code.ensure_loaded?(manager) and function_exported?(manager, function, length(args)) do
      try do
        {:ok, apply(manager, function, args)}
      catch
        :exit, {:noproc, _} ->
          {:error, "Cron scheduler is not running."}

        :exit, reason ->
          {:error, "Cron scheduler call failed: #{inspect(reason)}"}
      end
    else
      {:error, "Cron scheduler is unavailable."}
    end
  end

  defp cron_manager, do: Module.concat([LemonAutomation, CronManager])

  defp require_job_id(params) do
    case resolve_job_id(params) do
      nil -> {:error, "id (or jobId) is required"}
      job_id -> {:ok, job_id}
    end
  end

  defp resolve_job_id(params) do
    normalize_string(fetch_param(params, "id")) || normalize_string(fetch_param(params, "jobId"))
  end

  defp resolve_agent_id(source, session_key, default_agent_id) do
    normalize_string(fetch_param(source, "agentId") || fetch_param(source, "agent_id")) ||
      default_agent_id ||
      LemonCore.SessionKey.agent_id(session_key || "") ||
      "default"
  end

  defp resolve_session_key(source, session_key, agent_id) do
    normalize_string(fetch_param(source, "sessionKey") || fetch_param(source, "session_key")) ||
      session_key ||
      LemonCore.SessionKey.main(agent_id)
  end

  defp default_name(prompt) do
    trimmed = normalize_string(prompt) || "job"
    base = String.slice(trimmed, 0, 32)
    "Cron #{base}"
  end

  defp maybe_filter_enabled(jobs, true), do: jobs
  defp maybe_filter_enabled(jobs, false), do: Enum.filter(jobs, &truthy?(Map.get(&1, :enabled)))

  defp maybe_filter_agent(jobs, nil), do: jobs

  defp maybe_filter_agent(jobs, agent_id),
    do: Enum.filter(jobs, &(Map.get(&1, :agent_id) == agent_id))

  defp next_run_ms(jobs) do
    jobs
    |> Enum.filter(&truthy?(Map.get(&1, :enabled)))
    |> Enum.map(&Map.get(&1, :next_run_at_ms))
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp format_job(job) do
    %{
      "id" => Map.get(job, :id),
      "name" => Map.get(job, :name),
      "schedule" => Map.get(job, :schedule),
      "enabled" => Map.get(job, :enabled),
      "agentId" => Map.get(job, :agent_id),
      "sessionKey" => Map.get(job, :session_key),
      "prompt" => Map.get(job, :prompt),
      "timezone" => Map.get(job, :timezone) || "UTC",
      "jitterSec" => Map.get(job, :jitter_sec) || 0,
      "timeoutMs" => Map.get(job, :timeout_ms),
      "createdAtMs" => Map.get(job, :created_at_ms),
      "updatedAtMs" => Map.get(job, :updated_at_ms),
      "lastRunAtMs" => Map.get(job, :last_run_at_ms),
      "nextRunAtMs" => Map.get(job, :next_run_at_ms)
    }
  end

  defp format_run(run) do
    %{
      "id" => Map.get(run, :id),
      "jobId" => Map.get(run, :job_id),
      "status" => run |> Map.get(:status) |> to_string(),
      "triggeredBy" => run |> Map.get(:triggered_by) |> to_string(),
      "startedAtMs" => Map.get(run, :started_at_ms),
      "completedAtMs" => Map.get(run, :completed_at_ms),
      "output" => truncate(Map.get(run, :output), 500),
      "error" => Map.get(run, :error),
      "suppressed" => Map.get(run, :suppressed) || false
    }
  end

  defp truncate(nil, _max), do: nil
  defp truncate(text, max) when is_binary(text) and byte_size(text) <= max, do: text
  defp truncate(text, max) when is_binary(text), do: String.slice(text, 0, max) <> "..."
  defp truncate(other, _max), do: to_string(other)

  defp success_result(title, payload) do
    body = Jason.encode!(payload, pretty: true)

    %AgentToolResult{
      content: [%TextContent{type: :text, text: "#{title}\n#{body}"}],
      details: payload
    }
  end

  defp error_result(message) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: message}],
      details: %{error: true, message: message}
    }
  end

  defp fetch_param(params, key) when is_map(params) and is_binary(key) do
    case Map.fetch(params, key) do
      {:ok, value} ->
        value

      :error ->
        case to_existing_atom(key) do
          nil -> nil
          atom_key -> Map.get(params, atom_key)
        end
    end
  end

  defp fetch_param(_params, _key), do: nil

  defp nested_map(params, key) do
    case fetch_param(params, key) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp to_existing_atom(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_string(_), do: nil

  defp parse_bool(value, _default) when is_boolean(value), do: value
  defp parse_bool(nil, default), do: default

  defp parse_bool(value, default) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "1" -> true
      "true" -> true
      "yes" -> true
      "on" -> true
      "0" -> false
      "false" -> false
      "no" -> false
      "off" -> false
      _ -> default
    end
  end

  defp parse_bool(_value, default), do: default

  defp parse_bool_or_nil(nil), do: nil
  defp parse_bool_or_nil(value), do: parse_bool(value, nil)

  defp parse_non_negative_integer(value, default) do
    case parse_integer(value) do
      int when is_integer(int) and int >= 0 -> int
      _ -> default
    end
  end

  defp parse_non_negative_integer_or_nil(value) do
    case parse_integer(value) do
      int when is_integer(int) and int >= 0 -> int
      _ -> nil
    end
  end

  defp parse_positive_integer(value, default) do
    case parse_integer(value) do
      int when is_integer(int) and int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_integer_or_nil(value) do
    case parse_integer(value) do
      int when is_integer(int) and int > 0 -> int
      _ -> nil
    end
  end

  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(value) when is_float(value), do: trunc(value)

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp truthy?(value), do: value not in [false, nil]
end
