defmodule LemonControlPlane.Methods.ProcessJobsSupport do
  @moduledoc false

  alias LemonControlPlane.Methods.NativeSessions
  alias LemonCore.{AgentRuntime, Redact}

  @max_jobs 100
  @max_agents 100
  @max_id_bytes 128
  @max_command_bytes 2_048
  @max_cwd_bytes 1_024
  @max_name_bytes 128
  @max_output_bytes 65_536
  @max_pids 16
  @statuses ~w(queued starting running killing completed error killed lost rejected expired canceled unknown)

  def default_tail_bytes, do: 16_384
  def max_tail_bytes, do: @max_output_bytes

  def key(params), do: NativeSessions.string(params || %{}, "sessionKey", 1024)

  def job_id(params) do
    case NativeSessions.string(params || %{}, "jobId", @max_id_bytes) do
      {:ok, id} ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id),
          do: {:ok, id},
          else: NativeSessions.invalid("jobId must contain only letters, digits, - and _")

      error ->
        error
    end
  end

  def call(function, args), do: AgentRuntime.call(function, args, {:error, :unavailable})

  # A mutation whose provider call raised or exited may already have taken effect.
  def call_mutation(function, args) do
    provider = AgentRuntime.provider()

    if provider && Code.ensure_loaded?(provider) &&
         function_exported?(provider, function, length(args)),
       do: AgentRuntime.call(function, args, {:error, :outcome_unknown}),
       else: {:error, :unavailable}
  end

  def project_list(key, %{} = result) do
    jobs = fetch(result, :jobs)
    agents = fetch(result, :agents)
    root = identifier(fetch(result, :root_id))

    if is_list(jobs) and is_list(agents) and Enum.all?(jobs, &is_map/1) and
         Enum.all?(agents, &is_map/1) do
      projected =
        jobs |> Enum.take(@max_jobs) |> Enum.map(&project_job/1) |> Enum.reject(&is_nil/1)

      listed = agents |> Enum.take(@max_agents) |> Enum.map(&project_agent/1)
      total = integer(fetch(result, :total)) || length(jobs)

      {:ok,
       %{
         "sessionKey" => key,
         "live" => not is_nil(root),
         "rootId" => root,
         "at" => integer(fetch(result, :now_ms)),
         "jobs" => projected,
         "agents" => Enum.reject(listed, &is_nil/1),
         "total" => max(total, length(projected)),
         "truncated" => fetch(result, :truncated) == true or length(jobs) > @max_jobs
       }}
    else
      {:error, :invalid_runtime_response}
    end
  end

  def project_list(_key, _result), do: {:error, :invalid_runtime_response}

  def project_detail(key, %{} = result) do
    case project_job(result) do
      nil ->
        {:error, :invalid_runtime_response}

      job ->
        {:ok,
         %{
           "sessionKey" => key,
           "job" =>
             Map.merge(job, %{
               "cwd" => text(fetch(result, :cwd), @max_cwd_bytes),
               "backend" => label(fetch(result, :backend)),
               "pids" => pids(fetch(result, :pids)),
               "output" => output(fetch(result, :output)),
               "outputTruncated" => fetch(result, :output_truncated) == true,
               "outputBytes" => integer(fetch(result, :output_bytes))
             })
         }}
    end
  end

  def project_detail(_key, _result), do: {:error, :invalid_runtime_response}

  def project_cancel(key, job_id, %{} = result) do
    case project_job(result) do
      %{"id" => ^job_id} = job ->
        {:ok, %{"sessionKey" => key, "jobId" => job_id, "cancelled" => true, "job" => job}}

      _ ->
        {:error, :invalid_runtime_response}
    end
  end

  def project_cancel(_key, _job_id, _result), do: {:error, :invalid_runtime_response}

  def failure(:not_found),
    do: {:error, {:not_found, "Background job not found", %{"reason" => "not_found"}}}

  def failure(:already_terminal) do
    {:error, {:conflict, "Background job is already finished", %{"reason" => "already_terminal"}}}
  end

  def failure(:outcome_unknown) do
    {:error,
     {:unavailable, "Cancellation outcome is unknown; reconcile before retrying",
      %{"reason" => "outcome_unknown", "retrySafe" => false}}}
  end

  def failure(_reason) do
    {:error, {:unavailable, "Background job runtime unavailable", %{"reason" => "unavailable"}}}
  end

  defp project_job(job) do
    with id when is_binary(id) <- identifier(fetch(job, :id)),
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id) do
      %{
        "id" => id,
        "status" => status(fetch(job, :status)),
        "ownerId" => identifier(fetch(job, :owner_id)),
        "command" => text(fetch(job, :command), @max_command_bytes),
        "startedAt" => integer(fetch(job, :started_ms)),
        "endedAt" => integer(fetch(job, :ended_ms)),
        "exitCode" => integer(fetch(job, :exit_code)),
        "launch" => label(fetch(job, :launch))
      }
    else
      _ -> nil
    end
  end

  defp project_agent(agent) do
    case identifier(fetch(agent, :id)) do
      id when is_binary(id) ->
        %{
          "id" => id,
          "parentId" => identifier(fetch(agent, :parent_id)),
          "name" => text(fetch(agent, :name), @max_name_bytes)
        }

      _ ->
        nil
    end
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp identifier(value) when is_binary(value) do
    if byte_size(value) in 1..@max_id_bytes and String.valid?(value) and
         not Regex.match?(~r/[\x00-\x1f\x7f]/, value),
       do: value
  end

  defp identifier(_), do: nil

  defp status(value) when is_atom(value) and not is_nil(value), do: status(Atom.to_string(value))
  defp status(value) when value in @statuses, do: value
  defp status(_), do: "unknown"

  defp label(value) when is_atom(value) and not is_nil(value), do: label(Atom.to_string(value))

  defp label(value) when is_binary(value) do
    if byte_size(value) <= 32 and Regex.match?(~r/\A[a-z0-9_]+\z/, value), do: value
  end

  defp label(_), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: nil

  defp pids(value) when is_list(value) do
    value |> Enum.filter(&(is_integer(&1) and &1 > 0)) |> Enum.take(@max_pids)
  end

  defp pids(_), do: []

  defp text(value, limit) when is_binary(value) do
    if String.valid?(value), do: value |> Redact.text() |> clip(limit)
  end

  defp text(_, _), do: nil

  defp output(value) when is_binary(value) do
    if String.valid?(value), do: value |> Redact.text() |> tail(@max_output_bytes), else: ""
  end

  defp output(_), do: ""

  defp clip(value, limit) when byte_size(value) <= limit, do: value

  defp clip(value, limit) do
    value |> binary_part(0, limit) |> trim_end()
  end

  defp tail(value, limit) when byte_size(value) <= limit, do: value

  defp tail(value, limit) do
    value |> binary_part(byte_size(value) - limit, limit) |> trim_start()
  end

  defp trim_end(binary) do
    if String.valid?(binary),
      do: binary,
      else: binary |> binary_part(0, byte_size(binary) - 1) |> trim_end()
  end

  defp trim_start(binary) do
    if String.valid?(binary),
      do: binary,
      else: binary |> binary_part(1, byte_size(binary) - 1) |> trim_start()
  end
end

defmodule LemonControlPlane.Methods.ProcessJobsList do
  @moduledoc """
  Lists the background processes a session and its live subagents own.

  The runtime scopes by native session owner; a session with no live owner
  reports `live: false` and no jobs. Commands are redacted and bounded, and the
  list is capped at 100 newest jobs with `total`/`truncated` reporting the rest.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.ProcessJobsSupport, as: Support

  @impl true
  def name, do: "process.jobs.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key} <- Support.key(params) do
      case Support.call(:session_jobs, [key]) do
        {:ok, result} ->
          case Support.project_list(key, result) do
            {:ok, payload} -> {:ok, payload}
            {:error, reason} -> Support.failure(reason)
          end

        {:error, reason} ->
          Support.failure(reason)

        _ ->
          Support.failure(:unavailable)
      end
    end
  end
end

defmodule LemonControlPlane.Methods.ProcessJobsInspect do
  @moduledoc """
  Returns one session-scoped background process with a redacted output tail.

  Reading never consumes output the owning agent has yet to read. `tailBytes`
  bounds the tail (default 16 KiB, at most 64 KiB); a job outside the session's
  owners is reported as not found.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.NativeSessions
  alias LemonControlPlane.Methods.ProcessJobsSupport, as: Support

  @impl true
  def name, do: "process.jobs.inspect"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key} <- Support.key(params),
         {:ok, job_id} <- Support.job_id(params),
         {:ok, tail} <-
           NativeSessions.integer(
             params,
             "tailBytes",
             Support.default_tail_bytes(),
             0,
             Support.max_tail_bytes()
           ) do
      case Support.call(:session_job, [key, job_id, [tail_bytes: tail]]) do
        {:ok, result} ->
          case Support.project_detail(key, result) do
            {:ok, payload} -> {:ok, payload}
            {:error, reason} -> Support.failure(reason)
          end

        {:error, reason} ->
          Support.failure(reason)

        _ ->
          Support.failure(:unavailable)
      end
    end
  end
end

defmodule LemonControlPlane.Methods.ProcessJobsCancel do
  @moduledoc """
  Cancels a background process the session itself owns.

  Cancellation is bound to the exact session and job. A settled job conflicts;
  an unconfirmed termination is reported as `outcome_unknown` with
  `retrySafe: false` and is never retried by the control plane.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.ProcessJobsSupport, as: Support

  @impl true
  def name, do: "process.jobs.cancel"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key} <- Support.key(params),
         {:ok, job_id} <- Support.job_id(params) do
      case Support.call_mutation(:session_job_cancel, [key, job_id]) do
        {:ok, result} ->
          case Support.project_cancel(key, job_id, result) do
            {:ok, payload} -> {:ok, payload}
            {:error, _reason} -> Support.failure(:outcome_unknown)
          end

        {:error, reason} ->
          Support.failure(reason)

        _ ->
          Support.failure(:outcome_unknown)
      end
    end
  end
end
