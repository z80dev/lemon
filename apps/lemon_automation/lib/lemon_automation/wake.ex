defmodule LemonAutomation.Wake do
  @moduledoc """
  Wake functionality to trigger immediate cron job execution.

  Wake allows triggering any cron job to run immediately, bypassing
  the normal schedule. This is useful for:

  - Testing job configurations
  - Manual intervention during incidents
  - On-demand automation triggers
  - Integration with external systems

  ## Usage

      # Trigger a job by ID
      {:ok, run} = Wake.trigger("cron_abc123")

      # Trigger with custom context
      {:ok, run} = Wake.trigger("cron_abc123", context: %{reason: "manual test"})

      # Trigger multiple jobs
      results = Wake.trigger_many(["cron_abc", "cron_xyz"])

  ## Events

  Wake operations emit `:cron_run_started` events with `triggered_by: :wake`
  to distinguish them from scheduled runs.
  """

  alias LemonAutomation.{CronJob, CronRun, CronStore, CronManager, Events}

  require Logger

  @doc """
  Trigger a cron job to run immediately.

  Returns `{:ok, run}` with the created CronRun, or an error tuple.

  ## Options

  - `:context` - Additional context map to include in run metadata
  - `:skip_if_running` - Don't trigger if job already has an active run (default: false)
  """
  @spec trigger(binary(), keyword()) :: {:ok, CronRun.t()} | {:error, term()}
  def trigger(job_id, opts \\ []) do
    skip_if_running = Keyword.get(opts, :skip_if_running, false)
    context = Keyword.get(opts, :context, %{})

    with {:ok, job} <- get_job(job_id),
         :ok <- check_enabled(job),
         :ok <- check_not_running(job_id, skip_if_running) do
      run = execute_wake(job, context)
      Logger.info("[Wake] Triggered job #{job_id} (#{job.name})")
      {:ok, run}
    end
  end

  @doc """
  Trigger multiple cron jobs to run immediately.

  Returns a map of job_id => result for each job.
  """
  @spec trigger_many([binary()], keyword()) :: %{binary() => {:ok, CronRun.t()} | {:error, term()}}
  def trigger_many(job_ids, opts \\ []) when is_list(job_ids) do
    job_ids
    |> Enum.map(fn job_id -> {job_id, trigger(job_id, opts)} end)
    |> Map.new()
  end

  @doc """
  Trigger all enabled jobs matching a pattern in their name.

  ## Examples

      # Trigger all heartbeat jobs
      Wake.trigger_matching("heartbeat")

      # Trigger all daily report jobs
      Wake.trigger_matching("daily")
  """
  @spec trigger_matching(binary(), keyword()) :: %{binary() => {:ok, CronRun.t()} | {:error, term()}}
  def trigger_matching(pattern, opts \\ []) when is_binary(pattern) do
    pattern_downcase = String.downcase(pattern)

    CronStore.list_enabled_jobs()
    |> Enum.filter(fn job ->
      String.contains?(String.downcase(job.name), pattern_downcase)
    end)
    |> Enum.map(& &1.id)
    |> trigger_many(opts)
  end

  @doc """
  Trigger all enabled jobs for a specific agent.
  """
  @spec trigger_for_agent(binary(), keyword()) :: %{binary() => {:ok, CronRun.t()} | {:error, term()}}
  def trigger_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    CronStore.list_enabled_jobs()
    |> Enum.filter(fn job -> job.agent_id == agent_id end)
    |> Enum.map(& &1.id)
    |> trigger_many(opts)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_job(job_id) do
    case CronStore.get_job(job_id) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  end

  defp check_enabled(%CronJob{enabled: false}), do: {:error, :job_disabled}
  defp check_enabled(_job), do: :ok

  defp check_not_running(_job_id, false), do: :ok

  defp check_not_running(job_id, true) do
    case CronStore.active_runs(job_id) do
      [] -> :ok
      _runs -> {:error, :already_running}
    end
  end

  defp execute_wake(job, context) do
    run = CronRun.new(job.id, :wake)

    # Add wake context to metadata
    run =
      if map_size(context) > 0 do
        %{run | meta: Map.merge(run.meta || %{}, %{wake_context: context})}
      else
        run
      end

    CronStore.put_run(run)

    # Start the run
    run = CronRun.start(run)
    CronStore.put_run(run)
    Events.emit_run_started(run, job)

    # Use CronManager for actual execution to avoid code duplication
    # This is a fire-and-forget - the run completion will be handled by CronManager
    Task.start(fn ->
      result = submit_to_router(job, run)
      send(CronManager, {:run_complete, run.id, result})
    end)

    run
  end

  defp submit_to_router(job, run) do
    params = %{
      session_key: job.session_key,
      prompt: job.prompt,
      agent_id: job.agent_id,
      meta: %{
        cron_job_id: job.id,
        cron_run_id: run.id,
        triggered_by: :wake
      }
    }

    try do
      case LemonRouter.submit(params) do
        {:ok, result} ->
          output = extract_output(result)
          {:ok, output}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    rescue
      e ->
        {:error, Exception.message(e)}
    catch
      :exit, reason ->
        {:error, "Exit: #{inspect(reason)}"}
    end
  end

  defp extract_output(result) when is_map(result) do
    cond do
      is_binary(result[:output]) -> result[:output]
      is_binary(result["output"]) -> result["output"]
      is_binary(result[:response]) -> result[:response]
      is_binary(result["response"]) -> result["response"]
      true -> inspect(result)
    end
    |> String.slice(0, 1000)
  end

  defp extract_output(result), do: inspect(result) |> String.slice(0, 1000)
end
