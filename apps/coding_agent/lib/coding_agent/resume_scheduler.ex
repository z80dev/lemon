defmodule CodingAgent.ResumeScheduler do
  @moduledoc """
  Schedules automatic resume of runs that are paused due to rate limits.

  This module provides a lightweight scheduling mechanism that:
  1. Polls for pauses that are ready to resume
  2. Triggers resume via RunGraph
  3. Integrates with the existing cron infrastructure

  ## Usage

      # Start the scheduler (typically done in application startup)
      CodingAgent.ResumeScheduler.start_link([])

      # Or check and resume pauses manually
      CodingAgent.ResumeScheduler.check_and_resume()

  ## Configuration

      config :coding_agent, :rate_limit_resume,
        enabled: true,
        check_interval_ms: 30_000,  # Check every 30 seconds
        max_concurrent_resumes: 5   # Limit concurrent resume operations
  """

  use GenServer
  require Logger

  alias CodingAgent.{RateLimitPause, RunGraph}

  @default_check_interval_ms 30_000
  @default_max_concurrent_resumes 5

  # Client API

  @doc """
  Starts the ResumeScheduler GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks for pauses ready to resume and triggers their resumption.
  Returns the number of runs resumed.
  """
  @spec check_and_resume() :: {:ok, non_neg_integer()} | {:error, term()}
  def check_and_resume do
    GenServer.call(__MODULE__, :check_and_resume)
  end

  @doc """
  Returns statistics about the scheduler.
  """
  @spec stats() :: %{
    checks_performed: non_neg_integer(),
    runs_resumed: non_neg_integer(),
    last_check_at: DateTime.t() | nil
  }
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Manually trigger a resume for a specific pause.
  """
  @spec resume_pause(String.t()) :: {:ok, map()} | {:error, term()}
  def resume_pause(pause_id) do
    GenServer.call(__MODULE__, {:resume_pause, pause_id})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    # Check if auto-resume is enabled via config
    if RateLimitPause.enabled?() do
      check_interval = Keyword.get(opts, :check_interval_ms, default_check_interval())
      max_concurrent = Keyword.get(opts, :max_concurrent_resumes, default_max_concurrent())

      state = %{
        check_interval_ms: check_interval,
        max_concurrent_resumes: max_concurrent,
        checks_performed: 0,
        runs_resumed: 0,
        last_check_at: nil,
        timer_ref: nil
      }

      # Schedule first check
      timer_ref = schedule_check(check_interval)
      state = %{state | timer_ref: timer_ref}

      Logger.info("[ResumeScheduler] Started with #{check_interval}ms interval")
      {:ok, state}
    else
      Logger.info("[ResumeScheduler] Auto-resume is disabled via config. Running in standby mode.")
      {:ok, %{disabled: true}}
    end
  end

  @impl true
  def handle_call(:check_and_resume, _from, %{disabled: true} = state) do
    {:reply, {:error, :disabled}, state}
  end

  def handle_call(:check_and_resume, _from, state) do
    {count, new_state} = do_check_and_resume(state)
    {:reply, {:ok, count}, new_state}
  end

  @impl true
  def handle_call(:stats, _from, %{disabled: true} = state) do
    {:reply, %{disabled: true, checks_performed: 0, runs_resumed: 0, last_check_at: nil}, state}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      checks_performed: state.checks_performed,
      runs_resumed: state.runs_resumed,
      last_check_at: state.last_check_at
    }
    {:reply, stats, state}
  end

  @impl true
  def handle_call({:resume_pause, _pause_id}, _from, %{disabled: true} = state) do
    {:reply, {:error, :disabled}, state}
  end

  def handle_call({:resume_pause, pause_id}, _from, state) do
    result = do_resume_pause(pause_id)
    new_state =
      case result do
        {:ok, _} -> %{state | runs_resumed: state.runs_resumed + 1}
        _ -> state
      end
    {:reply, result, new_state}
  end

  @impl true
  def handle_info(:check, %{disabled: true} = state) do
    # Ignore check messages when disabled
    {:noreply, state}
  end

  def handle_info(:check, state) do
    {_count, new_state} = do_check_and_resume(state)
    timer_ref = schedule_check(new_state.check_interval_ms)
    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  @impl true
  def terminate(_reason, %{disabled: true}) do
    :ok
  end

  def terminate(_reason, state) do
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end
    :ok
  end

  # Private Functions

  defp do_check_and_resume(state) do
    # Get all stats to find pending pauses across all sessions
    stats = RateLimitPause.stats()

    if stats.pending_pauses > 0 do
      # We need to find pauses ready to resume
      # Since RateLimitPause doesn't have a global list function,
      # we'll check if any pauses are ready by using the ETS table directly
      ready_pauses = find_ready_pauses(state.max_concurrent_resumes)

      resumed_count =
        Enum.reduce(ready_pauses, 0, fn pause, count ->
          case do_resume_pause(pause.id) do
            {:ok, _} -> count + 1
            {:error, reason} ->
              Logger.warning("[ResumeScheduler] Failed to resume pause #{pause.id}: #{inspect(reason)}")
              count
          end
        end)

      new_state = %{
        state
        | checks_performed: state.checks_performed + 1,
          runs_resumed: state.runs_resumed + resumed_count,
          last_check_at: DateTime.utc_now()
      }

      if resumed_count > 0 do
        Logger.info("[ResumeScheduler] Resumed #{resumed_count} run(s) from rate limit pause")
      end

      {resumed_count, new_state}
    else
      new_state = %{
        state
        | checks_performed: state.checks_performed + 1,
          last_check_at: DateTime.utc_now()
      }

      {0, new_state}
    end
  end

  defp find_ready_pauses(limit) do
    # Access the ETS table directly to find pauses ready to resume
    table = :coding_agent_rate_limit_pauses

    if :ets.whereis(table) != :undefined do
      table
      |> :ets.tab2list()
      |> Enum.filter(fn
        {id, pause} when is_binary(id) ->
          pause.status == :paused and
            DateTime.compare(DateTime.utc_now(), pause.resume_at) != :lt

        _ ->
          false
      end)
      |> Enum.map(fn {_, pause} -> pause end)
      |> Enum.sort_by(& &1.resume_at, DateTime)
      |> Enum.take(limit)
    else
      []
    end
  end

  defp do_resume_pause(pause_id) do
    with {:ok, pause} <- RateLimitPause.get(pause_id),
         true <- RateLimitPause.ready_to_resume?(pause_id),
         {:ok, resumed_pause} <- RateLimitPause.resume(pause_id) do
      # Attempt to resume the run via RunGraph
      # Note: If run lookup fails, the pause is still marked as resumed
      # The caller can handle the run resumption separately if needed
      case resume_run(pause.session_id) do
        {:ok, run} -> {:ok, %{pause: resumed_pause, run: run}}
        {:error, :run_lookup_not_implemented} -> {:ok, %{pause: resumed_pause, run: nil}}
        {:error, reason} -> {:ok, %{pause: resumed_pause, run: nil, error: reason}}
      end
    else
      false -> {:error, :not_ready}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resume_run(session_id) do
    # Find the run for this session that is in paused_for_limit state
    # and resume it
    case find_paused_run(session_id) do
      {:ok, run_id} ->
        case RunGraph.resume_from_limit(run_id) do
          {:ok, run} -> {:ok, run}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_paused_run(session_id) do
    # This is a simplified implementation - in practice, you might want to
    # track the run_id directly in the pause record
    # For now, we'll return an error indicating we need the run_id
    # The actual implementation would query RunGraph for runs in paused_for_limit
    # state for this session
    {:error, :run_lookup_not_implemented}
  end

  defp schedule_check(interval_ms) do
    Process.send_after(self(), :check, interval_ms)
  end

  defp default_check_interval do
    Application.get_env(:coding_agent, :rate_limit_resume_check_interval_ms, @default_check_interval_ms)
  end

  defp default_max_concurrent do
    Application.get_env(:coding_agent, :rate_limit_resume_max_concurrent, @default_max_concurrent_resumes)
  end
end
