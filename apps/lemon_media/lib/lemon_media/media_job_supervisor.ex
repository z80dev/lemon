defmodule LemonMedia.MediaJobSupervisor do
  @moduledoc """
  Runs one media job per caller under a bounded task supervisor.

  `run_job/2` is synchronous: the caller waits for the job against one
  monotonic deadline and an optional abort predicate. A job never outlives
  its caller: on timeout, abort, or caller exit the job process is killed
  (which cancels any in-flight provider request) and the job record ends
  `:cancelled`. A job that dies on its own ends `:failed`.
  """

  alias LemonMedia.MediaJobs
  alias LemonMedia.MediaJobWorker

  @poll_ms 100

  @type outcome ::
          {:ok, map()}
          | {:error, {:failed, map()}}
          | {:error, {:cancelled, :timeout | :aborted, map()}}
          | {:error, term()}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    %{start: {module, function, args}} = child_spec(opts)
    apply(module, function, args)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts
    |> Keyword.put(:name, __MODULE__)
    |> LemonCore.TaskSupervisor.child_spec()
    |> Supervisor.child_spec(id: __MODULE__)
  end

  @doc """
  Reports whether the job supervisor is running and how many jobs are active.
  """
  @spec status() :: map()
  def status do
    case Process.whereis(__MODULE__) do
      nil ->
        %{running: false, active_jobs: 0}

      _pid ->
        counts = Supervisor.count_children(__MODULE__)
        %{running: true, active_jobs: Map.get(counts, :active, 0)}
    end
  catch
    :exit, _reason -> %{running: false, active_jobs: 0}
  end

  @doc """
  Records a queued job, runs `opts[:runner]` in a supervised task and waits.

  Options: `:timeout_ms` (required, the whole wait budget), `:aborted?`
  (0-arity predicate polled while waiting), `:runner` (1-arity function given
  the running job attrs), and record options `:project_dir`, `:dir`,
  `:artifacts_dir`.
  """
  @spec run_job(map() | keyword(), keyword()) :: outcome()
  def run_job(attrs, opts) when is_map(attrs) or is_list(attrs) do
    attrs = attrs_map(attrs)
    record_opts = record_opts(opts)
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    aborted? = Keyword.get(opts, :aborted?, fn -> false end)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    with {:ok, queued_job} <- MediaJobs.record(Map.put(attrs, :status, :queued), record_opts) do
      worker_attrs = Map.put(attrs, :job_id, queued_job.job_id)
      caller = self()

      case LemonCore.TaskSupervisor.async_nolink(__MODULE__, fn ->
             watch_caller(caller, worker_attrs, record_opts)
             MediaJobWorker.run(attrs: worker_attrs, opts: opts)
           end) do
        {:ok, task} ->
          await(task, deadline, aborted?, worker_attrs, record_opts)

        {:error, reason}
        when reason in [:task_capacity_reached, :task_supervisor_unavailable] ->
          _ = record_terminal(worker_attrs, record_opts, :failed, reason)
          {:error, reason}
      end
    end
  end

  defp await(task, deadline, aborted?, attrs, record_opts) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        cancel(task, :timeout, attrs, record_opts)

      aborted?.() ->
        cancel(task, :aborted, attrs, record_opts)

      true ->
        case Task.yield(task, min(remaining, @poll_ms)) do
          nil -> await(task, deadline, aborted?, attrs, record_opts)
          {:ok, result} -> result
          {:exit, _reason} -> exited(attrs, record_opts)
        end
    end
  end

  defp cancel(task, reason, attrs, record_opts) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        exited(attrs, record_opts)

      nil ->
        {:ok, job} = record_terminal(attrs, record_opts, :cancelled, reason)
        {:error, {:cancelled, reason, job}}
    end
  end

  defp exited(attrs, record_opts) do
    {:ok, job} = record_terminal(attrs, record_opts, :failed, :job_exited)
    {:error, {:failed, job}}
  end

  # Kills the job and records it cancelled when the waiting caller dies, so an
  # aborted tool call cannot leave a provider request running.
  defp watch_caller(caller, attrs, record_opts) do
    job = self()

    spawn(fn ->
      caller_ref = Process.monitor(caller)
      job_ref = Process.monitor(job)

      receive do
        {:DOWN, ^caller_ref, :process, _pid, _reason} ->
          Process.exit(job, :kill)
          receive do: ({:DOWN, ^job_ref, :process, _pid, _reason} -> :ok)
          record_terminal(attrs, record_opts, :cancelled, :caller_exited)

        {:DOWN, ^job_ref, :process, _pid, _reason} ->
          :ok
      end
    end)
  end

  defp record_terminal(attrs, record_opts, status, reason) do
    kind = Atom.to_string(reason)

    attrs
    |> Map.merge(%{status: status, error: kind, error_kind: kind})
    |> MediaJobs.record(record_opts)
  end

  defp record_opts(opts) do
    opts
    |> Keyword.take([:project_dir, :dir, :artifacts_dir])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
end
