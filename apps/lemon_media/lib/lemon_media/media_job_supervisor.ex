defmodule LemonMedia.MediaJobSupervisor do
  @moduledoc """
  Task supervisor facade for BEAM-native media jobs.
  """

  alias LemonMedia.MediaJobWorker
  alias LemonMedia.MediaJobs

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

  @spec status() :: map()
  def status do
    case Process.whereis(__MODULE__) do
      nil ->
        %{
          supervised: true,
          running: false,
          active_jobs: 0,
          workers: 0,
          supervisors: 0
        }

      _pid ->
        counts = Supervisor.count_children(__MODULE__)

        %{
          supervised: true,
          running: true,
          active_jobs: Map.get(counts, :active, 0),
          workers: Map.get(counts, :workers, 0),
          supervisors: Map.get(counts, :supervisors, 0)
        }
    end
  rescue
    error ->
      %{
        supervised: true,
        running: false,
        active_jobs: 0,
        workers: 0,
        supervisors: 0,
        error: Exception.message(error)
      }
  end

  @spec start_job(map() | keyword(), keyword()) :: {:ok, pid(), map()} | {:error, term()}
  def start_job(attrs, opts \\ []) when is_map(attrs) or is_list(attrs) do
    attrs = attrs_map(attrs)
    record_opts = record_opts(opts)
    queued_attrs = Map.put(attrs, :status, :queued)

    with {:ok, queued_job} <- MediaJobs.record(queued_attrs, record_opts),
         worker_attrs <- Map.put(attrs, :job_id, queued_job.job_id) do
      case start_task(worker_attrs, opts) do
        {:ok, pid} ->
          {:ok, pid, queued_job}

        {:error, reason}
        when reason in [:task_capacity_reached, :task_supervisor_unavailable] ->
          record_start_failure(worker_attrs, record_opts, reason)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp start_task(attrs, opts) do
    LemonCore.TaskSupervisor.start_child(
      __MODULE__,
      fn -> MediaJobWorker.run(attrs: attrs, opts: opts) end,
      restart: :temporary,
      shutdown: 5_000
    )
  end

  defp record_start_failure(attrs, record_opts, reason) do
    failed_attrs =
      attrs
      |> Map.put(:status, :failed)
      |> Map.put(:error, Atom.to_string(reason))
      |> Map.put(:error_kind, Atom.to_string(reason))

    with {:ok, failed_job} <- MediaJobs.record(failed_attrs, record_opts) do
      _ = publish_start_failure(failed_job)
      {:error, reason}
    end
  end

  defp publish_start_failure(job) do
    Phoenix.PubSub.broadcast(LemonCore.PubSub, "media_jobs", {:media_job, :failed, job})
  rescue
    _ -> :ok
  end

  defp record_opts(opts) do
    opts
    |> Keyword.take([:project_dir, :dir, :artifacts_dir])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
end
