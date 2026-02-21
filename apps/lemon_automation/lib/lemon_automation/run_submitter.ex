defmodule LemonAutomation.RunSubmitter do
  @moduledoc false

  alias LemonAutomation.{CronJob, CronRun, RunCompletionWaiter}
  alias LemonCore.Bus

  @default_timeout_ms 300_000

  @spec submit(CronJob.t(), CronRun.t(), keyword()) ::
          {:ok, binary()} | {:error, binary()} | :timeout
  def submit(%CronJob{} = job, %CronRun{} = run, opts \\ []) do
    timeout_ms = job.timeout_ms || @default_timeout_ms
    router_mod = Keyword.get(opts, :router_mod, LemonRouter)
    waiter_mod = Keyword.get(opts, :waiter_mod, RunCompletionWaiter)
    wait_opts = Keyword.get(opts, :wait_opts, [])

    # Pre-generate run_id and subscribe to bus BEFORE submitting to avoid
    # race condition where run completes before we subscribe
    run_id = LemonCore.Id.run_id()
    topic = Bus.run_topic(run_id)
    Bus.subscribe(topic)

    params = build_params(job, run, run_id)

    try do
      case router_mod.submit(params) do
        {:ok, ^run_id} ->
          # Already subscribed above, just wait for completion
          waiter_mod.wait_already_subscribed(run_id, timeout_ms, wait_opts)

        {:ok, other_run_id} ->
          # Router used a different run_id than expected
          Bus.unsubscribe(topic)
          waiter_mod.wait(other_run_id, timeout_ms, wait_opts)

        {:error, reason} ->
          Bus.unsubscribe(topic)
          {:error, inspect(reason)}

        other ->
          Bus.unsubscribe(topic)
          {:error, "Unexpected submit result: #{inspect(other)}"}
      end
    rescue
      e ->
        Bus.unsubscribe(topic)
        {:error, Exception.message(e)}
    catch
      :exit, reason ->
        Bus.unsubscribe(topic)
        {:error, "Exit: #{inspect(reason)}"}
    end
  end

  @doc false
  @spec build_params(CronJob.t(), CronRun.t(), binary()) :: map()
  def build_params(%CronJob{} = job, %CronRun{} = run, run_id \\ nil) do
    params = %{
      origin: :cron,
      session_key: job.session_key,
      prompt: job.prompt,
      agent_id: job.agent_id,
      meta: %{
        cron_job_id: job.id,
        cron_run_id: run.id,
        triggered_by: run.triggered_by
      }
    }

    # Include run_id if provided so router uses it instead of generating new one
    if run_id do
      Map.put(params, :run_id, run_id)
    else
      params
    end
  end
end
