defmodule LemonMedia.MediaJobSupervisor do
  @moduledoc """
  Task supervisor facade for BEAM-native media jobs.
  """

  alias LemonMedia.MediaJobWorker
  alias LemonMedia.MediaJobs

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_opts \\ []) do
    Task.Supervisor.start_link(name: __MODULE__)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: :infinity,
      type: :supervisor
    }
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
         worker_attrs <- Map.put(attrs, :job_id, queued_job.job_id),
         {:ok, pid} <- start_task(worker_attrs, opts) do
      {:ok, pid, queued_job}
    end
  end

  defp start_task(attrs, opts) do
    Task.Supervisor.start_child(
      __MODULE__,
      MediaJobWorker,
      :run,
      [[attrs: attrs, opts: opts]],
      restart: :temporary,
      shutdown: 5_000
    )
  end

  defp record_opts(opts) do
    opts
    |> Keyword.take([:project_dir, :dir, :artifacts_dir])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
end
