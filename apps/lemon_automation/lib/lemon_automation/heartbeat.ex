defmodule LemonAutomation.Heartbeat do
  @moduledoc """
  Lemon's one heartbeat mechanism: a heartbeat is an ordinary cron job whose
  `meta` carries `heartbeat: true`.

  It runs like every cron job - in an isolated sub-session of its session key -
  and its result is delivered by `LemonAutomation.CronDelivery` (by default to
  the paired owner chat). The only heartbeat-specific rule is suppression: a
  completed run whose output trims to exactly `HEARTBEAT_OK` means "nothing
  needs the user's attention", so it is marked suppressed, kept in run history,
  and not delivered. Any other outcome is delivered and emits
  `:heartbeat_alert`.

  Heartbeat schedules are cron schedules, so intervals must be cron-exact
  (`every 30m`, `every 2h`, `daily at 8am`, ...).
  """

  alias LemonAutomation.{CronJob, CronRun, Events}

  @ok_response "HEARTBEAT_OK"

  @doc "True when the cron job is a heartbeat (`meta.heartbeat == true`, atom or string key)."
  @spec heartbeat?(CronJob.t() | nil) :: boolean()
  def heartbeat?(%CronJob{meta: meta}) when is_map(meta),
    do: Map.get(meta, :heartbeat) == true or Map.get(meta, "heartbeat") == true

  def heartbeat?(_job), do: false

  @doc "True when a heartbeat reply means \"all clear\" (exactly `HEARTBEAT_OK`, trimmed)."
  @spec healthy_response?(term()) :: boolean()
  def healthy_response?(response) when is_binary(response),
    do: String.trim(response) == @ok_response

  def healthy_response?(_response), do: false

  @doc """
  Delivery policy for a terminal run. Completed prompt jobs may reply with
  exactly `[SILENT]` (trimmed) to suppress delivery. Heartbeats additionally
  recognize `HEARTBEAT_OK`. Failures are never suppressed here.
  """
  @spec apply_policy(CronJob.t() | nil, CronRun.t()) :: {CronRun.t(), boolean()}
  def apply_policy(%CronJob{} = job, %CronRun{} = run) do
    cond do
      silent_prompt?(job, run) ->
        run = CronRun.suppress(run)
        if heartbeat?(job), do: Events.emit_heartbeat_suppressed(run, job)
        {run, false}

      not heartbeat?(job) ->
        {run, true}

      run.status == :completed and healthy_response?(run.output) ->
        run = CronRun.suppress(run)
        Events.emit_heartbeat_suppressed(run, job)
        {run, false}

      true ->
        Events.emit_heartbeat_alert(run, job, run.output)
        {run, true}
    end
  end

  def apply_policy(_job, %CronRun{} = run), do: {run, true}

  defp silent_prompt?(job, %CronRun{status: :completed, output: output})
       when is_binary(output),
       do: CronJob.execution_mode(job) == :agent and String.trim(output) == "[SILENT]"

  defp silent_prompt?(_job, _run), do: false
end
