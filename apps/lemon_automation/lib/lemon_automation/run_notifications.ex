defmodule LemonAutomation.RunNotifications do
  @moduledoc """
  Binds automation runs to their supervision channel before submission and hands
  terminal facts to channels. Channels owns rendering, durable delivery and
  platform authorization; automation never calls an adapter or builds buttons.
  """
  alias LemonAgent.Workspace.{GoalStore, KanbanStore}
  alias LemonAutomation.{CronDelivery, CronJob, CronStore}
  alias LemonCore.ChannelSupervision
  alias LemonCore.Config.Modular
  require Logger

  def bind_cron(job, params), do: bind(CronDelivery.target(job, job.session_key), params)

  def bind_goal(goal, params) do
    bind(target(goal.meta, goal.session_key), params)
  end

  def bind_kanban(task, params) do
    board = KanbanStore.get_board(task.board_id)
    session = get_in(board, [:meta, "notificationSessionKey"]) || task.session_key
    bind(target(board[:meta] || %{}, session), params)
  end

  def cron_finished(job, run, summary, opts \\ []) do
    route = CronDelivery.target(job, (job && job.session_key) || get_in(run.meta, [:session_key]))
    invocation_session = run.meta[:router_session_key] || run.meta["router_session_key"]

    route =
      if is_binary(invocation_session),
        do: bound_target(run.run_id, invocation_session, route),
        else: route

    notice = %{
      kind: :cron,
      id: run.job_id,
      run_id: run.run_id || run.id,
      status: terminal_status(run.status),
      title: (job && job.name) || run.meta[:job_name] || "Scheduled task",
      summary: summary
    }

    cron_notice(route, job, run, notice, opts)
  end

  def kanban_finished(task, lease_id) do
    board = KanbanStore.get_board(task.board_id)
    checkpoint = task.meta["codingWorkflow"] || %{}

    session =
      if checkpoint["reviewRunId"] == task.run_id,
        do: checkpoint["reviewSessionKey"] || task.session_key,
        else: task.session_key

    fallback =
      target(board[:meta] || %{}, get_in(board, [:meta, "notificationSessionKey"]) || session)

    route = bound_target(task.run_id, session, fallback)

    status =
      if task.status == "done",
        do: :completed,
        else:
          if(get_in(task.meta, ["lastFailure", "reason"]) == "cancelled",
            do: :cancelled,
            else: :failed
          )

    notice = %{
      kind: :kanban,
      id: task.id,
      run_id: task.run_id || "lease_#{lease_id}",
      status: status,
      title: task.title,
      summary:
        get_in(task.meta, ["kanbanRun", "output"]) || get_in(task.meta, ["lastFailure", "reason"]),
      commit_sha: checkpoint["commitSha"],
      pr_url: checkpoint["prUrl"]
    }

    deliver(route, notice)
  end

  def goal_finished(session_key, loop_status) do
    goal = GoalStore.get(session_key)
    loop = get_in(goal, [:meta, "goalLoop"]) || %{}
    run_id = loop["lastRunId"]

    status =
      cond do
        goal[:status] == "completed" -> :completed
        loop_status == :stopped -> :cancelled
        goal[:status] == "paused" or loop_status in [:error, :limit_reached] -> :failed
        true -> nil
      end

    if status && is_binary(run_id) do
      # Judges execute under their own deterministic child session.
      session =
        if loop["lastRunKind"] == "judge", do: session_key <> ":goal_judge", else: session_key

      route = bound_target(run_id, session, target(goal.meta, session_key))

      summary =
        get_in(goal.meta, ["lastResult", "output"]) || get_in(loop, ["lastVerdict", "reason"]) ||
          loop["lastError"] ||
          if(status == :failed,
            do: "Goal paused or bounded loop ended before completion.",
            else: nil
          )

      deliver(route, %{
        kind: :goal,
        id: goal.id,
        run_id: run_id,
        status: status,
        title: "Coding goal",
        summary: summary
      })
    else
      :ok
    end
  end

  defp cron_notice(route, job, %{status: status} = run, notice, opts)
       when status in [:failed, :timeout] do
    now = Keyword.get(opts, :now_ms, LemonCore.Clock.now_ms())
    cooldown = Keyword.get_lazy(opts, :cooldown_ms, &failure_alert_cooldown/0)
    label = error_label(run)
    state = CronStore.get_failure_alert_state(run.job_id)
    incidents = Map.get(state, :incidents, %{})
    last_alert = Map.get(incidents, label)

    if is_nil(last_alert) or now - last_alert >= cooldown do
      route = alert_route(route)
      summary = alert_summary(job, run, label, :failed)
      result = deliver(route, %{notice | title: safe_title(notice.title), summary: summary})
      record_alert_result(result, route, job, run, label, summary, now)

      # Signature is {job_id, error_label}; the fixed classifier bounds the map.
      incidents = Map.put(incidents, label, now)

      CronStore.put_failure_alert_state(run.job_id, %{
        incidents: incidents,
        alerted: Map.get(state, :alerted, false) or alert_admitted?(route, result),
        last_error_label: label
      })
    else
      :ok =
        CronStore.put_failure_alert_state(run.job_id, Map.put(state, :last_error_label, label))

      :suppressed
    end
  end

  defp cron_notice(route, job, %{status: :completed} = run, notice, _opts) do
    state = CronStore.get_failure_alert_state(run.job_id)
    CronStore.delete_failure_alert_state(run.job_id)
    CronStore.clear_failure_notice(run.job_id)

    cond do
      silent_success?(run) ->
        :ok

      state[:alerted] == true ->
        deliver(alert_route(route), %{
          notice
          | title: safe_title(notice.title),
            summary: alert_summary(job, run, state[:last_error_label], :recovered)
        })

      run.suppressed ->
        :ok

      true ->
        deliver(route, notice)
    end
  end

  defp cron_notice(route, _job, _run, notice, _opts), do: deliver(route, notice)

  defp silent_success?(run) do
    run.suppressed and is_binary(run.output) and
      String.trim(run.output) in ["[SILENT]", "HEARTBEAT_OK"]
  end

  defp failure_alert_cooldown do
    case Modular.load().automation.failure_alert_cooldown_ms do
      value when is_integer(value) and value >= 0 -> value
      _ -> 21_600_000
    end
  end

  defp alert_route(:none), do: CronDelivery.owner_target()
  defp alert_route(route), do: route

  defp alert_admitted?({:ok, _target}, result),
    do: result in [:ok, {:error, :outcome_unknown}, {:error, :supervision_unavailable}]

  defp alert_admitted?(_route, _result), do: false

  defp record_alert_result(:ok, {:ok, _target}, _job, run, _label, _summary, _now),
    do: CronStore.clear_failure_notice(run.job_id)

  defp record_alert_result(_result, route, job, run, label, summary, now) do
    CronStore.record_failure_notice(run.job_id, %{
      job_id: run.job_id,
      run_id: run.id,
      ts_ms: now,
      error_label: label,
      summary: summary,
      failure_streak: if(job, do: CronJob.failure_streak(job), else: 1),
      last_status: run.status,
      reason: if(route == :none, do: :no_route, else: :delivery_failed)
    })
  end

  defp alert_summary(job, run, label, status) do
    title = safe_title((job && job.name) || "Scheduled task")
    streak = if job, do: CronJob.failure_streak(job), else: 1
    outcome = if status == :recovered, do: "recovered", else: "failed"
    id = run.job_id |> LemonCore.Redact.text() |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")

    "Cron #{outcome}: #{title}\nFailure streak: #{streak}\n" <>
      "Last error: #{label || "run_failed"}\n" <>
      "Inspect: lemon cron runs --job #{String.slice(id, 0, 128)}"
  end

  defp safe_title(title) do
    title
    |> LemonCore.Redact.text()
    |> String.replace(~r/[\r\n[:cntrl:]]/, " ")
    |> String.slice(0, 160)
  end

  # Only classified labels cross the alert boundary, never raw errors, paths or URLs.
  defp error_label(%{status: :timeout}), do: "timeout"

  defp error_label(run) do
    error = if is_binary(run.error), do: String.downcase(run.error), else: ""

    cond do
      String.contains?(error, "admission_unavailable") ->
        "admission_unavailable"

      String.contains?(error, "admission_denied") ->
        "admission_denied"

      String.contains?(error, "preflight") ->
        "preflight_failed"

      String.contains?(error, ["timed out", "timeout"]) ->
        "timeout"

      String.contains?(error, ["rate_limit", "rate limit", "429"]) ->
        "rate_limited"

      String.contains?(error, ["unauthorized", "authentication", "401"]) ->
        "authentication_failed"

      String.contains?(error, "worker") ->
        "worker_exited"

      String.contains?(error, "exit") ->
        "command_failed"

      true ->
        "run_failed"
    end
  end

  defp target(meta, session_key),
    do: CronDelivery.target_for(meta["deliverTo"] || meta[:deliver_to], session_key)

  defp bind(:none, _params), do: :ok

  defp bind({:ok, target}, params),
    do: ChannelSupervision.bind_run(params.run_id, params.session_key, target)

  defp bound_target(nil, _session, fallback), do: fallback

  defp bound_target(run_id, session, fallback) do
    case ChannelSupervision.target_for_run(run_id, session) do
      :none -> fallback
      result -> result
    end
  end

  defp deliver(:none, _notice), do: :ok

  defp deliver({:ok, target}, notice) do
    result = ChannelSupervision.notify(target, notice)

    if result != :ok,
      do:
        Logger.warning(
          "Automation channel notice admission failed kind=#{notice.kind} status=#{notice.status}"
        )

    result
  end

  defp deliver({:error, _} = error, _notice), do: error

  defp terminal_status(:completed), do: :completed
  defp terminal_status(status) when status in [:aborted, :cancelled], do: :cancelled
  defp terminal_status(_), do: :failed
end
