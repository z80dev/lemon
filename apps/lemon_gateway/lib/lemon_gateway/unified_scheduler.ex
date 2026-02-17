defmodule LemonGateway.UnifiedScheduler do
  @moduledoc """
  Unified lane-aware scheduler for LemonGateway.

  This module integrates LaneQueue into LemonGateway to provide unified scheduling
  for all work types: main agent runs, subagent tasks, and background processes.

  ## Lanes

  - `:main` - Top-level user jobs (main agent runs)
  - `:subagent` - Task tool subagent runs
  - `:background_exec` - Background OS processes

  ## Features

  - Global fairness through lane caps
  - Per-thread serialization via ThreadWorker
  - Backpressure when lanes are saturated
  - Backward compatible with existing Scheduler API

  ## Configuration

  Configure lane caps in `config/config.exs`:

      config :lemon_gateway, :lane_caps,
        main: 4,
        subagent: 8,
        background_exec: 2
  """

  use GenServer
  require Logger

  alias LemonGateway.Types.Job

  @type lane :: :main | :subagent | :background_exec | atom()
  @task_supervisor LemonGateway.TaskSupervisor

  # Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Submit a job for execution in the specified lane.

  This is the unified entry point for all work types. The job will be
  routed through the appropriate lane queue and scheduled according to
  lane caps and global fairness policies.

  ## Options

  - `:lane` - The lane to use (default: :main)
  - `:async` - If true, returns immediately with {:ok, job_id}
  - `:timeout_ms` - Timeout for synchronous execution (default: :infinity)

  ## Examples

      # Submit main agent run
      UnifiedScheduler.submit(job, lane: :main)

      # Submit subagent task asynchronously
      UnifiedScheduler.submit(job, lane: :subagent, async: true)
  """
  @spec submit(Job.t(), keyword()) :: {:ok, term()} | {:ok, String.t()} | {:error, term()}
  def submit(%Job{} = job, opts \\ []) do
    lane = Keyword.get(opts, :lane, :main)
    async? = Keyword.get(opts, :async, false)
    timeout = Keyword.get(opts, :timeout_ms, :infinity)

    if async? do
      GenServer.call(__MODULE__, {:submit_async, job, lane}, timeout)
    else
      GenServer.call(__MODULE__, {:submit_sync, job, lane}, timeout)
    end
  end

  @doc """
  Run a function in the specified lane.

  This is a lower-level API for scheduling arbitrary work.

  ## Examples

      UnifiedScheduler.run_in_lane(:subagent, fn ->
        # Do work
        result
      end)
  """
  @spec run_in_lane(lane(), (-> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def run_in_lane(lane, fun, opts \\ []) when is_function(fun, 0) do
    _timeout = Keyword.get(opts, :timeout_ms, :infinity)
    meta = Keyword.get(opts, :meta, %{})

    # Use CodingAgent.LaneQueue for the actual scheduling
    CodingAgent.LaneQueue.run(CodingAgent.LaneQueue, lane, fun, meta)
  rescue
    e ->
      Logger.error("Failed to run in lane #{lane}: #{inspect(e)}")
      {:error, :lane_queue_unavailable}
  end

  @doc """
  Get current queue depths for all lanes.
  """
  @spec lane_stats() :: map()
  def lane_stats do
    GenServer.call(__MODULE__, :lane_stats)
  end

  @doc """
  Check if a lane has capacity available.
  """
  @spec lane_available?(lane()) :: boolean()
  def lane_available?(lane) do
    GenServer.call(__MODULE__, {:lane_available, lane})
  end

  @doc """
  Get the configured caps for all lanes.
  """
  @spec lane_caps() :: map()
  def lane_caps do
    Application.get_env(:lemon_gateway, :lane_caps, %{
      main: 4,
      subagent: 8,
      background_exec: 2
    })
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    # Get lane caps from config or use defaults
    lane_caps =
      Keyword.get(opts, :lane_caps) ||
        Application.get_env(:lemon_gateway, :lane_caps, %{
          main: 4,
          subagent: 8,
          background_exec: 2
        })

    # Track job metadata
    state = %{
      lane_caps: lane_caps,
      job_counter: 0,
      pending_jobs: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:submit_sync, job, lane}, from, state) do
    job_id = generate_job_id(state)

    # Schedule the job through LaneQueue
    _ =
      start_background_task(fn ->
        result =
          run_in_lane(
            lane,
            fn ->
              execute_job(job)
            end,
            meta: %{job_id: job_id, lane: lane}
          )

        GenServer.reply(from, result)
      end)

    {:noreply, %{state | job_counter: state.job_counter + 1}}
  end

  def handle_call({:submit_async, job, lane}, _from, state) do
    job_id = generate_job_id(state)

    # Schedule the job asynchronously
    _ =
      start_background_task(fn ->
        run_in_lane(
          lane,
          fn ->
            execute_job(job)
          end,
          meta: %{job_id: job_id, lane: lane}
        )
      end)

    {:reply, {:ok, job_id}, %{state | job_counter: state.job_counter + 1}}
  end

  def handle_call(:lane_stats, _from, state) do
    # Get stats from LaneQueue if available
    stats =
      try do
        # This would need to be exposed by LaneQueue
        %{}
      rescue
        _ -> %{}
      end

    {:reply, stats, state}
  end

  def handle_call({:lane_available, lane}, _from, state) do
    # Check if lane has capacity
    _cap = Map.get(state.lane_caps, lane, 1)

    # For now, assume available if we can submit
    # In a full implementation, we'd query LaneQueue state
    available = true

    {:reply, available, state}
  end

  # Private Functions

  defp execute_job(job) do
    # Delegate to the existing ThreadWorker/Scheduler infrastructure
    # This maintains backward compatibility
    LemonGateway.Scheduler.submit(job)
    :ok
  rescue
    e ->
      Logger.error("Failed to execute job: #{inspect(e)}")
      {:error, :execution_failed}
  end

  defp generate_job_id(state) do
    "job_#{state.job_counter}_#{System.unique_integer([:positive])}"
  end

  defp start_background_task(fun) when is_function(fun, 0) do
    case Task.Supervisor.start_child(@task_supervisor, fun) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:noproc, _}} ->
        Task.start(fun)

      {:error, :noproc} ->
        Task.start(fun)

      {:error, reason} ->
        Logger.warning(
          "[UnifiedScheduler] Failed to start supervised task: #{inspect(reason)}; falling back to Task.start/1"
        )

        Task.start(fun)
    end
  end
end
