defmodule CodingAgent.Session.Jobs do
  @moduledoc """
  Session-scoped, read-mostly view of background processes for operator clients.

  A native session owns the processes its `bash` tool starts with
  `run_in_background`; the owner recorded in `CodingAgent.ProcessStore` is the
  native session id. A routing key resolves to its live root session plus the
  live task children that share the key, and a job is visible only when its
  owner is one of those sessions. Anything else reports `:not_found`, so another
  session's jobs are never disclosed.

  Reads never advance the agent's `bash_output` cursor: output is a bounded,
  redacted tail taken straight from the store. Cancellation is limited to jobs
  the root session itself owns and delegates to `CodingAgent.ProcessManager.kill/2`,
  which cancels queued launches and signals started ones. An unconfirmed kill
  surfaces as `:outcome_unknown` and is never retried here.
  """

  alias CodingAgent.{BashExecutor, ProcessManager, ProcessStore, Session, TaskStore}
  alias LemonCore.Redact

  @max_jobs 100
  @max_command_bytes 2_048
  @max_cwd_bytes 1_024
  @max_name_bytes 128
  @default_tail_bytes 16_384
  @max_tail_bytes 65_536
  @max_tail_lines 400
  @active ~w(queued starting running killing)a
  @statuses ~w(queued starting running killing completed error killed lost rejected expired canceled)a

  @type owners :: %{root_id: String.t() | nil, agents: [map()]}

  @doc "Bounded job summaries for a session and its live subagents."
  @spec list(String.t()) :: {:ok, map()} | {:error, :unavailable}
  def list(session_key) when is_binary(session_key) do
    with {:ok, owners} <- owners(session_key),
         {:ok, records} <- records(owners) do
      sorted = Enum.sort_by(records, fn {id, record} -> {-sort_time(record), id} end)
      jobs = sorted |> Enum.take(@max_jobs) |> Enum.map(fn {id, record} -> summary(id, record) end)
      owning = jobs |> Enum.map(& &1.owner_id) |> MapSet.new()

      {:ok,
       %{
         root_id: owners.root_id,
         now_ms: System.system_time(:millisecond),
         jobs: jobs,
         agents: Enum.filter(owners.agents, &(&1.id in owning)) |> with_ancestors(owners.agents),
         total: length(records),
         truncated: length(records) > @max_jobs
       }}
    end
  end

  def list(_session_key), do: {:error, :unavailable}

  @doc """
  One job's facts and a redacted output tail of at most `:tail_bytes` bytes.
  Does not consume the output the agent has yet to read.
  """
  @spec inspect_job(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | :unavailable}
  def inspect_job(session_key, job_id, opts \\ [])

  def inspect_job(session_key, job_id, opts) when is_binary(session_key) do
    tail = opts |> Keyword.get(:tail_bytes, @default_tail_bytes) |> clamp(0, @max_tail_bytes)

    with {:ok, owners} <- owners(session_key),
         {:ok, record, logs} <- fetch_owned(owners, job_id, :any) do
      {:ok, detail(job_id, record, logs, tail)}
    end
  end

  def inspect_job(_session_key, _job_id, _opts), do: {:error, :unavailable}

  @doc """
  Cancel a job the root session owns. Returns `{:ok, summary}` once the owner
  accepted the request, `{:error, :already_terminal}` for a settled job, and
  `{:error, :outcome_unknown}` when termination could not be confirmed.
  """
  @spec cancel(String.t(), String.t()) ::
          {:ok, map()}
          | {:error, :not_found | :already_terminal | :outcome_unknown | :unavailable}
  def cancel(session_key, job_id) when is_binary(session_key) do
    with {:ok, owners} <- owners(session_key),
         {:ok, _record, _logs} <- fetch_owned(owners, job_id, :root) do
      case ProcessManager.kill(job_id, :sigterm) do
        :ok ->
          case ProcessStore.get(job_id) do
            {:ok, record, _logs} -> {:ok, summary(job_id, record)}
            {:error, :not_found} -> {:error, :unavailable}
          end

        {:error, :process_not_running} ->
          {:error, :already_terminal}

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, {:outcome_unknown, _id}} ->
          {:error, :outcome_unknown}

        _ ->
          {:error, :unavailable}
      end
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def cancel(_session_key, _job_id), do: {:error, :unavailable}

  @doc """
  Resolve the native session ids that own a routing key's jobs: the single live
  root and its live task children. A key with no live root owns nothing.
  Ambiguous or unreadable registrations fail closed.
  """
  @spec owners(String.t()) :: {:ok, owners()} | {:error, :unavailable}
  def owners(session_key) do
    sessions = registered(session_key)

    sessions
    |> Enum.reduce_while({:ok, [], []}, fn {id, pid}, {:ok, roots, children} ->
      case session_state(pid) do
        {:ok, %{session_key: ^session_key, session_manager: %{header: %{id: ^id}}} = state} ->
          if state.task_child == true,
            do: {:cont, {:ok, roots, [{id, state} | children]}},
            else: {:cont, {:ok, [id | roots], children}}

        {:ok, _other} ->
          {:cont, {:ok, roots, children}}

        :error ->
          {:halt, {:error, :unavailable}}
      end
    end)
    |> case do
      {:ok, [], _children} ->
        {:ok, %{root_id: nil, agents: []}}

      {:ok, [root], children} ->
        tasks = tasks_by_run(session_key)
        agents = children |> Enum.map(&agent(&1, root, tasks)) |> Enum.sort_by(& &1.id)
        {:ok, %{root_id: root, agents: agents}}

      _ambiguous_or_unavailable ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp registered(session_key) do
    if Process.whereis(CodingAgent.SessionRegistry) do
      Registry.select(CodingAgent.SessionRegistry, [
        {{:"$1", :"$2", %{session_key: session_key}}, [], [{{:"$1", :"$2"}}]}
      ])
    else
      []
    end
  end

  defp session_state(pid) do
    {:ok, Session.get_state(pid)}
  catch
    :exit, _ -> :error
  end

  defp tasks_by_run(session_key) do
    TaskStore.list(:all)
    |> Enum.reduce(%{}, fn {_id, record}, acc ->
      run_id = Map.get(record, :run_id)

      if is_binary(run_id) and Map.get(record, :session_key) == session_key,
        do: Map.put(acc, run_id, record),
        else: acc
    end)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp agent({id, state}, root, tasks) do
    record = Map.get(tasks, state.run_id, %{})
    parent = Map.get(record, :parent_session_id)

    %{
      id: id,
      parent_id: if(is_binary(parent) and parent != id, do: parent, else: root),
      name: record |> task_name() |> bound(@max_name_bytes)
    }
  end

  defp task_name(record) do
    Enum.find_value([:name, :description, :role], fn key ->
      case Map.get(record, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  # A listed agent's ancestors are listed too, so clients can place it in a tree.
  defp with_ancestors(listed, all) do
    by_id = Map.new(all, &{&1.id, &1})

    listed
    |> Enum.flat_map(&ancestry(&1, by_id, MapSet.new()))
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
  end

  defp ancestry(agent, by_id, seen) do
    parent = Map.get(by_id, agent.parent_id)

    if parent && not MapSet.member?(seen, parent.id),
      do: [agent | ancestry(parent, by_id, MapSet.put(seen, agent.id))],
      else: [agent]
  end

  defp records(%{root_id: nil}), do: {:ok, []}

  defp records(owners) do
    ids = MapSet.new([owners.root_id | Enum.map(owners.agents, & &1.id)])

    {:ok,
     ProcessStore.list(:all)
     |> Enum.filter(fn {_id, record} -> MapSet.member?(ids, Map.get(record, :owner)) end)}
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp fetch_owned(owners, job_id, scope) when is_binary(job_id) do
    permitted =
      case scope do
        :root -> [owners.root_id]
        :any -> [owners.root_id | Enum.map(owners.agents, & &1.id)]
      end

    with true <- Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, job_id),
         {:ok, record, logs} <- ProcessStore.get(job_id),
         owner when is_binary(owner) <- Map.get(record, :owner),
         true <- owner in permitted do
      {:ok, record, logs}
    else
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp fetch_owned(_owners, _job_id, _scope), do: {:error, :not_found}

  defp summary(id, record) do
    status = status(record)

    %{
      id: id,
      status: status,
      owner_id: Map.get(record, :owner),
      command: record |> Map.get(:command) |> redacted(@max_command_bytes),
      started_ms: millis(Map.get(record, :started_at) || Map.get(record, :inserted_at)),
      ended_ms: if(status in @active, do: nil, else: millis(Map.get(record, :completed_at))),
      exit_code: integer(Map.get(record, :exit_code)),
      launch: label(Map.get(record, :launch_classification))
    }
  end

  defp detail(id, record, logs, tail_bytes) do
    {output, cut} = tail(logs, tail_bytes)
    stats = Map.get(record, :output) || %{}
    status = status(record)

    summary(id, record)
    |> Map.merge(%{
      cwd: record |> Map.get(:cwd) |> redacted(@max_cwd_bytes),
      backend: label(Map.get(record, :backend)),
      pids: pids(record, status),
      output: output,
      output_truncated: cut or Map.get(stats, :discarded_bytes, 0) > 0,
      output_bytes: integer(Map.get(stats, :received_bytes))
    })
  end

  defp tail(_logs, 0), do: {"", false}

  defp tail(logs, max_bytes) do
    {text, truncated, _info} =
      logs
      |> Enum.join("\n")
      |> BashExecutor.sanitize_output()
      |> Redact.text()
      |> BashExecutor.truncate_tail(max_bytes: max_bytes, max_lines: @max_tail_lines)

    {text, truncated}
  end

  defp pids(record, status) when status in [:running, :killing] do
    case Map.get(record, :os_pid) do
      pid when is_integer(pid) and pid > 0 -> [pid]
      _ -> []
    end
  end

  defp pids(_record, _status), do: []

  defp status(record) do
    case Map.get(record, :status) do
      status when status in @statuses -> status
      _ -> :unknown
    end
  end

  defp sort_time(record),
    do: Map.get(record, :inserted_at) || Map.get(record, :started_at) || 0

  defp millis(seconds) when is_integer(seconds) and seconds >= 0, do: seconds * 1000
  defp millis(_), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: nil

  defp label(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp label(_), do: nil

  defp redacted(value, limit) when is_binary(value),
    do: value |> Redact.text() |> bound(limit)

  defp redacted(_value, _limit), do: nil

  defp bound(value, limit) when is_binary(value) do
    if byte_size(value) <= limit do
      value
    else
      value |> binary_part(0, limit) |> trim_partial_utf8()
    end
  end

  defp bound(_value, _limit), do: nil

  defp trim_partial_utf8(binary) do
    if String.valid?(binary),
      do: binary,
      else: binary |> binary_part(0, byte_size(binary) - 1) |> trim_partial_utf8()
  end

  defp clamp(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)
  defp clamp(_value, _min, max), do: max
end
