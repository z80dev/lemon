defmodule LemonAutomation.Tools.Cron do
  @moduledoc """
  LemonAgent tool for managing Lemon internal cron/scheduled jobs.

  Supports actions to list, add, update, pause, resume, abort, remove, and trigger cron
  jobs, as well as viewing run history. Delegates to
  `LemonAutomation.CronManager` for persistence and scheduling. The global
  `pause_all`/`resume_all` hold is operator-only (CLI, control plane) and is
  refused here.

  Results are delivered to the originating Telegram/Discord chat or, for jobs
  created from any other session (TUI, web, CLI), to the paired owner chat.
  `deliverTo` overrides the target; `"none"` opts out of ordinary result delivery.
  Failure/recovery alerts still fall back to the owner chat.

  ## Registration

  `LemonAutomation.Application` registers this module under `:cron` with
  `LemonAgent.ToolRegistry` once the cron scheduler is up, so the coding agent
  offers it to every session without the platform naming this app. Like any
  registered tool it goes through the session's tool policy and approval
  wrapping. `tool/2` reads `:session_key`, `:agent_id`, `:tool_policy` and
  `:execution_context` from the session's tool options; calls return an error
  result, never raise, while `LemonAutomation.CronManager` is not running.

  ## Ownership and launcher authority

  `add` records the calling session's principal (exactly its trusted session
  key; a collision-free `legacy:<sha256>` of the exact id for clients whose ids
  are not canonical Lemon session keys, never the agent's main session) and
  effective tool policy on the job (`LemonAutomation.CronAuthority`). Every
  other action reaches only jobs that principal owns: other sessions' jobs and
  operator-created jobs read as not found. `update` intersects the job's
  recorded policy with the caller's, and `run` executes within the triggering
  session's policy as well, so a job scheduled, rewritten or triggered from a
  chat never runs with more authority than that chat: its channel policy,
  group approval floor and session denials still apply at run time. A session
  without an identity reaches nothing. Delivery routing for non-canonical ids
  still falls back to the agent's main session; that never grants ownership.

  A job's cross-run memory is the Lemon-managed file
  `LemonAutomation.CronMemory.memory_file/1`; `memoryFile` is refused.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonAutomation.{CronAuthority, CronJob, CronManager, CronMemory, CronStore}

  @actions ~w(status list add update pause resume abort remove run runs)
  @default_limit 100
  @memory_file_keys ~w(memoryFile memory_file)
  @memory_file_refusal "memoryFile cannot be set: each job's cross-run memory is the " <>
                         "Lemon-managed file cron_memory/<job id>.md in the Lemon state directory."

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    session_key = normalize_string(Keyword.get(opts, :session_key))
    agent_id = normalize_string(Keyword.get(opts, :agent_id))

    caller = %{
      session_key: session_key,
      agent_id: agent_id,
      principal: principal(session_key),
      authority_opts: Keyword.take(opts, [:tool_policy, :execution_context])
    }

    %AgentTool{
      name: "cron",
      label: "Cron",
      description:
        "Manage the Lemon cron jobs this conversation scheduled: status, list, add, update, pause, resume, abort, remove, run, and runs. Prompt jobs run native coding sessions in cwd (defaults to the current repository) with at most this conversation's tool authority. Pause disables future runs of one job. Abort stops a specific active cron run. Add/update accepts 5-field cron, recurring shorthands like 'every 30m', and one-shots like 'in 30m' or '2027-01-15T09:00' in the job timezone. Lifecycle actions accept an id or an unambiguous case-insensitive exact name. Each job keeps a Lemon-managed memory file. Results reach the user's paired chat automatically; deliverTo='none' opts out of ordinary results, not rate-limited failure/recovery alerts.",
      parameters: tool_schema(),
      execute: &execute(&1, inherit_cwd(&2, cwd), &3, &4, caller)
    }
  end

  def execute(_tool_call_id, params, _signal, _on_update, caller) when is_map(params) do
    action = normalize_string(fetch_param(params, "action"))

    with :ok <- ensure_scheduler_started(),
         :ok <- require_principal(caller),
         {:ok, {title, payload}} <- dispatch(action, params, caller) do
      success_result(title, payload)
    else
      {:error, message} ->
        error_result(message)
    end
  end

  def execute(_tool_call_id, _params, _signal, _on_update, _caller) do
    error_result("Invalid parameters (expected object).")
  end

  # The principal that owns jobs this session adds and the only one whose jobs
  # it reaches: exactly its trusted session key. A session id that is not a
  # canonical Lemon session key (e.g. a legacy TUI `tui-<timestamp>`) owns a
  # collision-free `legacy:<sha256>` principal of that exact id; it is never
  # promoted to the agent's main session (only delivery falls back there, see
  # `resolve_session_key/3`). A session without any identity reaches nothing.
  defp principal(nil), do: nil

  defp principal(session_key) do
    if valid_session_key?(session_key),
      do: session_key,
      else: "legacy:" <> Base.encode16(:crypto.hash(:sha256, session_key), case: :lower)
  end

  defp session_opts(caller), do: [session_key: caller.principal] ++ caller.authority_opts

  defp require_principal(%{principal: principal}) when is_binary(principal), do: :ok
  defp require_principal(_caller), do: {:error, "cron requires a trusted session identity"}

  defp inherit_cwd(params, cwd) when is_map(params) do
    if fetch_param(params, "action") == "add" do
      case nested_map(params, "job") do
        nil -> Map.put_new(params, "cwd", fetch_param(params, "cwd") || cwd)
        job -> Map.put(params, "job", Map.put_new(job, "cwd", fetch_param(job, "cwd") || cwd))
      end
    else
      params
    end
  end

  defp inherit_cwd(params, _cwd), do: params

  defp tool_schema do
    %{
      "type" => "object",
      "properties" => %{
        "failing" => %{
          "type" => "boolean",
          "description" => "Only jobs with a nonzero failure streak (list)."
        },
        "action" => %{
          "type" => "string",
          "enum" => @actions,
          "description" =>
            "Cron action: status, list, add, update, pause, resume, abort, remove, run, or runs."
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
        "runId" => %{
          "type" => "string",
          "description" => "Cron run id for abort."
        },
        "cronRunId" => %{
          "type" => "string",
          "description" => "Alias for runId for abort."
        },
        "name" => %{
          "type" => "string",
          "description" =>
            "Job name on add; case-insensitive exact selector when id/jobId is absent. For update by name, put changes (including a new name) in patch."
        },
        "schedule" => %{
          "type" => "string",
          "description" =>
            "5-field cron or recurring shorthand ('every 30m', 'daily at 9am'); or a one-shot delay 'in 30m', 'in 2h', 'in 1d', or local ISO timestamp 'YYYY-MM-DDTHH:MM[:SS]' in the job timezone. One-shots must be in the future and retire after running."
        },
        "prompt" => %{
          "type" => "string",
          "description" =>
            "Prompt text to run when the job fires. A successful final reply that trims to exactly [SILENT] is recorded but not delivered; merely containing the marker does not suppress output, and failures are never suppressed."
        },
        "cwd" => %{
          "type" => "string",
          "description" =>
            "Target repository directory (add/update). Defaults to the current tool working directory on add."
        },
        "model" => %{
          "type" => "string",
          "description" =>
            "Optional provider:model pin for the native coding session (add/update)."
        },
        "enabled" => %{
          "type" => "boolean",
          "description" => "Whether the job is enabled (add/update)."
        },
        "timezone" => %{
          "type" => "string",
          "description" =>
            "'UTC' (default), 'local' (the server's wall-clock time), or an IANA zone such as 'America/New_York'. Local ISO timestamps are interpreted in this zone and pinned to an absolute instant."
        },
        "deliverTo" => %{
          "type" => "string",
          "description" =>
            "Where ordinary results are sent (add/update). Omit for the default: the originating chat, else the user's paired chat. 'none' disables ordinary results; failure/recovery alerts still fall back to the owner. 'telegram:<chat_id>[:<topic_id>]' or 'discord:<channel_id>[:<thread_id>]' picks a chat; 'auto' restores the default."
        },
        "once" => %{
          "type" => "boolean",
          "description" =>
            "One-shot job (add/update): runs at the next scheduled time, then is removed. Automatically true for relative delays and ISO timestamps; optional for date-pinned cron expressions."
        },
        "jitterSec" => %{
          "type" => "integer",
          "description" => "Optional jitter spread in seconds."
        },
        "timeoutMs" => %{
          "type" => "integer",
          "description" => "Optional timeout in milliseconds (default: 300000)."
        },
        "maxRetries" => %{
          "type" => "integer",
          "description" =>
            "Scheduled-run retry count after confirmed failure (default: 0). Unknown submission or completion outcomes never retry automatically."
        },
        "retryBackoffMs" => %{
          "type" => "integer",
          "description" => "Delay before retry runs in milliseconds (default: 30000)."
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

  defp dispatch("status", _params, caller) do
    with {:ok, jobs} <- owned_jobs(caller),
         {:ok, pause} <- cron_call(:pause_status, []) do
      payload =
        %{
          "enabled" => true,
          "jobCount" => length(jobs),
          "activeJobs" => Enum.count(jobs, &truthy?(Map.get(&1, :enabled))),
          "failingJobs" => Enum.count(jobs, &(CronJob.failure_streak(&1) > 0)),
          "nextRunAtMs" => next_run_ms(jobs)
        }
        |> Map.merge(pause_payload(pause))

      {:ok, {"Cron status", payload}}
    end
  end

  defp dispatch("list", params, caller) do
    include_disabled = parse_bool(fetch_param(params, "includeDisabled"), true)
    agent_id = normalize_string(fetch_param(params, "agentId") || fetch_param(params, "agent_id"))

    with {:ok, jobs} <- owned_jobs(caller) do
      payload =
        jobs
        |> maybe_filter_enabled(include_disabled)
        |> maybe_filter_agent(agent_id)
        |> maybe_filter_failing(parse_bool(fetch_param(params, "failing"), false))
        |> Enum.map(&format_job/1)
        |> then(&%{"jobs" => &1})

      {:ok, {"Cron jobs", payload}}
    end
  end

  defp dispatch("add", params, %{session_key: session_key, agent_id: default_agent_id} = caller) do
    source = nested_map(params, "job") || params

    schedule = normalize_string(fetch_param(source, "schedule"))
    prompt = normalize_string(fetch_param(source, "prompt") || fetch_param(source, "message"))
    name = normalize_string(fetch_param(source, "name")) || default_name(prompt)
    agent_id = resolve_agent_id(source, session_key, default_agent_id)
    target_session_key = resolve_session_key(source, session_key, agent_id)

    cond do
      memory_file_param?([source]) ->
        {:error, @memory_file_refusal}

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
            cwd: normalize_string(fetch_param(source, "cwd")),
            model: normalize_string(fetch_param(source, "model")),
            deliver_to: fetch_param(source, "deliverTo") || fetch_param(source, "deliver_to"),
            once: parse_bool(fetch_param(source, "once"), false),
            enabled: parse_bool(fetch_param(source, "enabled"), true),
            timezone: normalize_string(fetch_param(source, "timezone")) || "UTC"
          }
          |> Map.merge(numeric_params(source))
          |> maybe_put(:meta, if(is_map(meta), do: meta, else: nil))
          |> Map.put(
            :authority,
            CronAuthority.from_session(caller.principal, caller.authority_opts)
          )

        case cron_call(:add, [add_params]) do
          {:ok, {:ok, job}} ->
            payload = format_job(job)
            {:ok, {"Cron job added", payload}}

          {:ok, {:error, {:missing_keys, keys}}} ->
            {:error, "Missing required fields: #{inspect(keys)}"}

          {:ok, {:error, {:invalid_schedule, reason}}} ->
            {:error, "Invalid schedule: #{reason}"}

          {:ok, {:error, {:invalid_target, reason}}} ->
            {:error, "Invalid job: #{invalid_target_message(reason)}"}

          {:ok, {:error, reason}} ->
            {:error, "Failed to add cron job: #{inspect(reason)}"}

          {:error, _} = error ->
            error
        end
    end
  end

  defp dispatch("update", params, caller) do
    patch_source =
      nested_map(params, "patch") ||
        if(resolve_job_id(params),
          do: params,
          else: params |> Map.delete("name") |> Map.delete(:name)
        )

    patch =
      %{}
      |> maybe_put(:name, normalize_string(fetch_param(patch_source, "name")))
      |> maybe_put(:schedule, normalize_string(fetch_param(patch_source, "schedule")))
      |> maybe_put(:cwd, normalize_string(fetch_param(patch_source, "cwd")))
      |> maybe_put(:model, normalize_string(fetch_param(patch_source, "model")))
      |> maybe_put(
        :prompt,
        normalize_string(
          fetch_param(patch_source, "prompt") || fetch_param(patch_source, "message")
        )
      )
      |> maybe_put(:timezone, normalize_string(fetch_param(patch_source, "timezone")))
      |> maybe_put(
        :deliver_to,
        normalize_string(
          fetch_param(patch_source, "deliverTo") || fetch_param(patch_source, "deliver_to")
        )
      )
      |> maybe_put(:once, parse_bool_or_nil(fetch_param(patch_source, "once")))
      |> maybe_put(:enabled, parse_bool_or_nil(fetch_param(patch_source, "enabled")))
      |> Map.merge(numeric_params(patch_source))
      |> maybe_put(
        :meta,
        if(is_map(fetch_param(patch_source, "meta")),
          do: fetch_param(patch_source, "meta"),
          else: nil
        )
      )

    with false <- memory_file_param?([params, patch_source]),
         {:ok, job_id} <- require_job_id(params, caller),
         true <- map_size(patch) > 0 do
      case cron_call(:update_from_session, [job_id, patch, session_opts(caller)]) do
        {:ok, {:ok, job}} ->
          payload = %{
            "id" => Map.get(job, :id),
            "updated" => true,
            "nextRunAtMs" => Map.get(job, :next_run_at_ms)
          }

          {:ok, {"Cron job updated", payload}}

        {:ok, {:error, :not_found}} ->
          {:error, "Cron job not found: #{job_id}"}

        {:ok, {:error, {:invalid_target, reason}}} ->
          {:error, "Invalid job: #{invalid_target_message(reason)}"}

        {:ok, {:error, reason}} ->
          {:error, "Failed to update cron job: #{inspect(reason)}"}

        {:error, _} = error ->
          error
      end
    else
      true -> {:error, @memory_file_refusal}
      false -> {:error, "No update fields were provided"}
      error -> error
    end
  end

  defp dispatch("remove", params, caller) do
    with {:ok, job_id} <- require_job_id(params, caller) do
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

  defp dispatch("pause", params, caller) do
    update_enabled(params, caller, false, "paused", "Cron job paused")
  end

  defp dispatch("resume", params, caller) do
    update_enabled(params, caller, true, "resumed", "Cron job resumed")
  end

  # The global pause holds back every principal's jobs, and resume skips their
  # missed runs: operator surfaces only.
  defp dispatch(action, _params, _caller) when action in ["pause_all", "resume_all"] do
    {:error,
     "#{action} is operator-only: use `lemon cron pause --all` / `lemon cron resume --all` " <>
       "or the control plane's cron.pause / cron.resume with all: true."}
  end

  defp dispatch("abort", params, caller) do
    with {:ok, run_id} <- require_run_id(params),
         :ok <- require_owned_run(run_id, caller) do
      case cron_call(:abort_run, [run_id]) do
        {:ok, {:ok, run}} ->
          payload = %{
            "aborted" => true,
            "runId" => Map.get(run, :id),
            "jobId" => Map.get(run, :job_id),
            "status" => run |> Map.get(:status) |> to_string(),
            "routerRunId" => Map.get(run, :run_id)
          }

          {:ok, {"Cron run aborted", payload}}

        {:ok, {:error, :outcome_unknown}} ->
          {:ok,
           {"Cron abort outcome unknown",
            %{
              "runId" => run_id,
              "aborted" => false,
              "outcomeUnknown" => true,
              "retrySafe" => false
            }}}

        {:ok, {:error, :not_found}} ->
          {:error, "Cron run not found: #{run_id}"}

        {:ok, {:error, :not_active}} ->
          {:error, "Cron run is not active: #{run_id}"}

        {:ok, {:error, reason}} ->
          {:error, "Failed to abort cron run: #{inspect(reason)}"}

        {:error, _} = error ->
          error
      end
    end
  end

  defp dispatch("run", params, caller) do
    with {:ok, job_id} <- require_job_id(params, caller) do
      case cron_call(:run_now_from_session, [job_id, session_opts(caller)]) do
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

  defp dispatch("runs", params, caller) do
    with {:ok, job_id} <- require_job_id(params, caller) do
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

  defp dispatch(nil, _params, _caller),
    do: {:error, "action is required"}

  defp dispatch(action, _params, _caller),
    do: {:error, "Unknown action '#{action}'. Supported: #{Enum.join(@actions, ", ")}"}

  defp update_enabled(params, caller, enabled, result_key, title) do
    with {:ok, job_id} <- require_job_id(params, caller) do
      case cron_call(:update, [job_id, %{enabled: enabled}]) do
        {:ok, {:ok, job}} ->
          payload = %{
            "id" => Map.get(job, :id),
            result_key => true,
            "enabled" => Map.get(job, :enabled),
            "nextRunAtMs" => Map.get(job, :next_run_at_ms)
          }

          {:ok, {title, payload}}

        {:ok, {:error, :not_found}} ->
          {:error, "Cron job not found: #{job_id}"}

        {:ok, {:error, reason}} ->
          {:error, "Failed to update cron job: #{inspect(reason)}"}

        {:error, _} = error ->
          error
      end
    end
  end

  defp ensure_scheduler_started do
    if is_pid(Process.whereis(CronManager)) do
      :ok
    else
      {:error, "Cron scheduler is unavailable (LemonAutomation.CronManager not started)."}
    end
  end

  defp cron_call(function, args) do
    {:ok, apply(CronManager, function, args)}
  catch
    :exit, {:noproc, _} ->
      {:error, "Cron scheduler is not running."}

    :exit, reason ->
      {:error, "Cron scheduler call failed: #{inspect(reason)}"}
  end

  # Jobs whose recorded owner is this session's principal; every other job,
  # including operator-created ones, is invisible to the session.
  defp owned_jobs(caller) do
    with {:ok, jobs} when is_list(jobs) <- cron_call(:list, []) do
      {:ok,
       Enum.filter(jobs, &CronAuthority.owned_by?(Map.get(&1, :authority), caller.principal))}
    end
  end

  # Owner is immutable once recorded, so a check here cannot be invalidated
  # before the mutation that follows it.
  defp require_job_id(params, caller) do
    with {:ok, jobs} <- owned_jobs(caller) do
      case resolve_job_id(params) do
        nil ->
          resolve_job_name(normalize_string(fetch_param(params, "name")), jobs)

        job_id ->
          if Enum.any?(jobs, &(&1.id == job_id)),
            do: {:ok, job_id},
            else: {:error, "Cron job not found: #{job_id}"}
      end
    end
  end

  defp require_owned_run(run_id, caller) do
    with {:ok, jobs} <- owned_jobs(caller) do
      job_id = Map.get(CronStore.get_run(run_id) || %{}, :job_id)

      if is_binary(job_id) and Enum.any?(jobs, &(&1.id == job_id)),
        do: :ok,
        else: {:error, "Cron run not found: #{run_id}"}
    end
  end

  defp require_run_id(params) do
    case resolve_run_id(params) do
      nil -> {:error, "runId (or cronRunId) is required"}
      run_id -> {:ok, run_id}
    end
  end

  defp resolve_job_id(params) do
    normalize_string(fetch_param(params, "id")) || normalize_string(fetch_param(params, "jobId"))
  end

  defp resolve_job_name(nil, _jobs), do: {:error, "id (or jobId) is required"}

  defp resolve_job_name(name, jobs) do
    normalized_name = String.downcase(name)
    matches = Enum.filter(jobs, &(String.downcase(&1.name) == normalized_name))

    case matches do
      [job] ->
        {:ok, job.id}

      [] ->
        {:error, "Cron job not found: #{name}. Candidates: #{job_candidates(jobs)}"}

      matches ->
        {:error,
         "Ambiguous cron job name #{inspect(name)}. Candidates: #{job_candidates(matches)}"}
    end
  end

  defp job_candidates(jobs) do
    case Enum.sort_by(jobs, &{String.downcase(&1.name), &1.id}) do
      [] -> "(none)"
      jobs -> Enum.map_join(jobs, ", ", &"#{inspect(&1.name)} (#{&1.id})")
    end
  end

  defp resolve_run_id(params) do
    normalize_string(fetch_param(params, "runId")) ||
      normalize_string(fetch_param(params, "cronRunId"))
  end

  defp resolve_agent_id(source, session_key, default_agent_id) do
    normalize_string(fetch_param(source, "agentId") || fetch_param(source, "agent_id")) ||
      default_agent_id ||
      LemonCore.SessionKey.agent_id(session_key || "") ||
      "default"
  end

  defp resolve_session_key(source, session_key, agent_id) do
    # Prefer the running session's key over the AI-provided one: it always
    # carries the correct channel/thread routing, while an AI-supplied
    # sessionKey may omit the thread_id and route output to the wrong
    # Telegram chat/topic. Clients whose session ids are not Lemon session keys
    # (e.g. the TUI's `tui-<timestamp>`) fall back to the agent's main session;
    # delivery then targets the paired owner chat.
    explicit =
      normalize_string(fetch_param(source, "sessionKey") || fetch_param(source, "session_key"))

    cond do
      valid_session_key?(session_key) -> session_key
      is_binary(explicit) -> explicit
      true -> LemonCore.SessionKey.main(agent_id)
    end
  end

  defp valid_session_key?(session_key) when is_binary(session_key),
    do: LemonCore.SessionKey.valid?(session_key)

  defp valid_session_key?(_session_key), do: false

  defp default_name(prompt) do
    trimmed = normalize_string(prompt) || "job"
    base = String.slice(trimmed, 0, 32)
    "Cron #{base}"
  end

  defp maybe_filter_failing(jobs, false), do: jobs

  defp maybe_filter_failing(jobs, true),
    do: Enum.filter(jobs, &(CronJob.failure_streak(&1) > 0))

  defp maybe_filter_enabled(jobs, true), do: jobs
  defp maybe_filter_enabled(jobs, false), do: Enum.filter(jobs, &truthy?(Map.get(&1, :enabled)))

  defp maybe_filter_agent(jobs, nil), do: jobs

  defp maybe_filter_agent(jobs, agent_id),
    do: Enum.filter(jobs, &(Map.get(&1, :agent_id) == agent_id))

  # An unreadable pause marker is unknown, not "not paused".
  defp pause_payload({:ok, %{paused: paused, paused_at_ms: paused_at_ms} = status}),
    do: %{
      "paused" => paused,
      "pausedAtMs" => paused_at_ms,
      "restorationPending" => Map.get(status, :restoration_pending)
    }

  defp pause_payload(_unknown),
    do: %{"paused" => nil, "pausedAtMs" => nil, "restorationPending" => nil}

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
      "cwd" => Map.get(job, :cwd),
      "model" => Map.get(job, :model),
      "memoryFile" => CronMemory.memory_file(job),
      "deliverTo" => Map.get(job, :deliver_to),
      "once" => Map.get(job, :once) == true,
      "timezone" => Map.get(job, :timezone) || "UTC",
      "jitterSec" => Map.get(job, :jitter_sec) || 0,
      "timeoutMs" => Map.get(job, :timeout_ms),
      "maxRetries" => Map.get(job, :max_retries) || 0,
      "retryBackoffMs" => Map.get(job, :retry_backoff_ms) || 30_000,
      "createdAtMs" => Map.get(job, :created_at_ms),
      "updatedAtMs" => Map.get(job, :updated_at_ms),
      "lastRunAtMs" => Map.get(job, :last_run_at_ms),
      "failureStreak" => CronJob.failure_streak(job),
      "lastStatus" => job |> CronJob.last_status() |> status_string(),
      "nextRunAtMs" => Map.get(job, :next_run_at_ms)
    }
  end

  defp status_string(nil), do: nil
  defp status_string(status), do: to_string(status)

  defp format_run(run) do
    %{
      "id" => Map.get(run, :id),
      "jobId" => Map.get(run, :job_id),
      "routerRunId" => Map.get(run, :run_id),
      "sessionKey" => meta_value(run, :router_session_key),
      "outcomeUnknown" => meta_value(run, :outcome_unknown) == true,
      "reconciling" => meta_value(run, :outcome_unknown) == true,
      "abortRequested" => meta_value(run, :abort_requested) == true,
      "status" => run |> Map.get(:status) |> to_string(),
      "triggeredBy" => run |> Map.get(:triggered_by) |> to_string(),
      "retryAttempt" => retry_attempt(run),
      "retryOf" => meta_value(run, :retry_of),
      "retryRootId" => meta_value(run, :retry_root_id),
      "startedAtMs" => Map.get(run, :started_at_ms),
      "completedAtMs" => Map.get(run, :completed_at_ms),
      "output" => truncate(Map.get(run, :output), 500),
      "error" => Map.get(run, :error),
      "suppressed" => Map.get(run, :suppressed) || false
    }
  end

  defp retry_attempt(run) do
    case meta_value(run, :retry_attempt) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  defp meta_value(run, key) do
    meta = Map.get(run, :meta) || %{}
    Map.get(meta, key) || Map.get(meta, to_string(key))
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
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
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

  @numeric_param_keys [
    {:jitter_sec, "jitterSec", "jitter_sec"},
    {:timeout_ms, "timeoutMs", "timeout_ms"},
    {:max_retries, "maxRetries", "max_retries"},
    {:retry_backoff_ms, "retryBackoffMs", "retry_backoff_ms"}
  ]

  # Numeric job fields pass through unchanged except for integer strings, so
  # CronManager rejects a non-integer or out-of-range value with the shared
  # `CronJob.numeric_bounds/0` message instead of the tool silently defaulting.
  defp numeric_params(source) do
    for {field, camel, snake} <- @numeric_param_keys,
        value = fetch_param(source, camel) || fetch_param(source, snake),
        not is_nil(value),
        into: %{},
        do: {field, numeric_value(value)}
  end

  defp numeric_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp numeric_value(value), do: value

  defp parse_positive_integer(value, default) do
    case parse_integer(value) do
      int when is_integer(int) and int > 0 -> int
      _ -> default
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

  defp memory_file_param?(sources),
    do: Enum.any?(sources, fn source -> Enum.any?(@memory_file_keys, &has_param?(source, &1)) end)

  defp has_param?(source, key), do: not is_nil(fetch_param(source, key))

  defp invalid_target_message({:callback_origin_not_allowed, origin}),
    do: "callback_origin_not_allowed: " <> origin

  defp invalid_target_message(reason)
       when reason in [:callback_requires_https, :invalid_callback_url],
       do: Atom.to_string(reason)

  defp invalid_target_message(reason) when is_binary(reason), do: reason
  defp truthy?(value), do: value not in [false, nil]
end
