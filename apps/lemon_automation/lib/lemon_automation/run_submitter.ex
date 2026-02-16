defmodule LemonAutomation.RunSubmitter do
  @moduledoc false

  alias LemonAutomation.{CronJob, CronRun, RunCompletionWaiter}

  @default_timeout_ms 300_000

  @spec submit(CronJob.t(), CronRun.t(), keyword()) ::
          {:ok, binary()} | {:error, binary()} | :timeout
  def submit(%CronJob{} = job, %CronRun{} = run, opts \\ []) do
    timeout_ms = job.timeout_ms || @default_timeout_ms
    router_mod = Keyword.get(opts, :router_mod, LemonRouter)
    waiter_mod = Keyword.get(opts, :waiter_mod, RunCompletionWaiter)
    wait_opts = Keyword.get(opts, :wait_opts, [])

    params = build_params(job, run)

    try do
      case router_mod.submit(params) do
        {:ok, run_id} ->
          waiter_mod.wait(run_id, timeout_ms, wait_opts)

        {:error, reason} ->
          {:error, inspect(reason)}

        other ->
          {:error, "Unexpected submit result: #{inspect(other)}"}
      end
    rescue
      e ->
        {:error, Exception.message(e)}
    catch
      :exit, reason ->
        {:error, "Exit: #{inspect(reason)}"}
    end
  end

  @doc false
  @spec build_params(CronJob.t(), CronRun.t()) :: map()
  def build_params(%CronJob{} = job, %CronRun{} = run) do
    %{
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
  end
end
