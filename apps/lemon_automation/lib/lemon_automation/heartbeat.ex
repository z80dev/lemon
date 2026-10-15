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

  ## Daily brief

  `[automation] daily_brief = "HH:MM"` (written by `lemon setup` when the user
  opts in) keeps one heartbeat job, `cron_daily_brief`, in sync at boot:
  it runs every day at that server-local time and asks the agent for a short
  morning brief (or `HEARTBEAT_OK` when there is nothing worth saying).
  Removing the key removes the job.
  """

  alias LemonAutomation.{CronJob, CronManager, CronRun, Events}
  alias LemonCore.Config.Automation
  alias LemonCore.Config.Modular
  alias LemonCore.SessionKey

  require Logger

  @ok_response "HEARTBEAT_OK"
  @daily_brief_id "cron_daily_brief"
  @daily_brief_agent "default"

  @daily_brief_prompt """
  Daily brief for the user. If HEARTBEAT.md exists in your workspace, follow its checklist first. \
  Then write a short morning brief (a few bullets): today's reminders and scheduled jobs (cron tool, \
  action=list), anything due or pending from memory, and open follow-ups from recent conversations. \
  If there is genuinely nothing worth telling the user, reply with exactly HEARTBEAT_OK.\
  """

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

  @doc "Stable id of the daily brief job."
  @spec daily_brief_id() :: String.t()
  def daily_brief_id, do: @daily_brief_id

  @doc """
  Cron params for the daily brief at `hour:minute` server-local time.
  """
  @spec daily_brief_params(0..23, 0..59) :: map()
  def daily_brief_params(hour, minute) do
    %{
      id: @daily_brief_id,
      name: "Daily brief",
      schedule: "#{minute} #{hour} * * *",
      timezone: "local",
      agent_id: @daily_brief_agent,
      session_key: SessionKey.main(@daily_brief_agent),
      prompt: @daily_brief_prompt,
      meta: %{heartbeat: true, daily_brief: true, agent_id: @daily_brief_agent}
    }
  end

  @doc """
  Reconciles the daily brief job with `[automation] daily_brief` from config.
  """
  @spec sync_daily_brief() :: :ok | {:error, term()}
  def sync_daily_brief do
    sync_daily_brief(Modular.load().automation.daily_brief)
  rescue
    error ->
      Logger.warning("[Heartbeat] Daily brief sync skipped: #{Exception.message(error)}")
      {:error, :config_unavailable}
  end

  @doc """
  Reconciles the daily brief job with a `HH:MM` time (`nil` = disabled).
  `opts[:cron_manager]` overrides the cron manager module (tests).
  """
  @spec sync_daily_brief(String.t() | nil, keyword()) :: :ok | {:error, term()}
  def sync_daily_brief(time, opts \\ []) do
    cron = Keyword.get(opts, :cron_manager, CronManager)
    existing = Enum.find(cron.list(), &(&1.id == @daily_brief_id))

    case {time, existing} do
      {nil, nil} ->
        :ok

      {nil, %CronJob{id: id}} ->
        case cron.remove(id) do
          :ok ->
            Logger.info("[Heartbeat] Daily brief disabled; removed #{id}")
            :ok

          {:error, _} = error ->
            error
        end

      {time, existing} ->
        case Automation.parse_time(time) do
          {:ok, {hour, minute}} ->
            upsert_daily_brief(cron, existing, daily_brief_params(hour, minute))

          :error ->
            Logger.warning("[Heartbeat] Ignoring invalid automation.daily_brief #{inspect(time)}")
            {:error, :invalid_time}
        end
    end
  end

  defp upsert_daily_brief(cron, nil, params) do
    case cron.add_new(params) do
      {:ok, job} ->
        Logger.info("[Heartbeat] Daily brief scheduled (#{job.schedule}, local time)")
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp upsert_daily_brief(cron, %CronJob{} = job, params) do
    if job.schedule == params.schedule and job.timezone == params.timezone and job.enabled do
      :ok
    else
      patch = %{schedule: params.schedule, timezone: params.timezone, enabled: true}

      case cron.update(job.id, patch) do
        {:ok, _job} -> :ok
        {:error, _} = error -> error
      end
    end
  end
end
