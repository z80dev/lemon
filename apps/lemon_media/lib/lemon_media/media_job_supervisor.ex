defmodule LemonMedia.MediaJobSupervisor do
  @moduledoc """
  Dynamic supervisor for BEAM-native media job workers.
  """

  use DynamicSupervisor

  alias LemonMedia.MediaJobWorker
  alias LemonMedia.MediaJobs

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
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
        counts = DynamicSupervisor.count_children(__MODULE__)

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
         {:ok, pid} <- DynamicSupervisor.start_child(__MODULE__, child_spec(worker_attrs, opts)) do
      {:ok, pid, queued_job}
    end
  end

  defp child_spec(attrs, opts) do
    %{
      id: MediaJobWorker,
      start: {MediaJobWorker, :start_link, [[attrs: attrs, opts: opts]]},
      restart: :temporary
    }
  end

  defp record_opts(opts) do
    opts
    |> Keyword.take([:project_dir, :dir, :artifacts_dir])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
end
