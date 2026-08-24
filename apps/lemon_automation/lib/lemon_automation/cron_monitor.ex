defmodule LemonAutomation.CronMonitor do
  @moduledoc """
  Monitor semantics for cron jobs: suppress delivery while the output is unchanged.

  A job with `monitor: true` only forwards its summary when the *normalized*
  output differs from the previous completed run. That makes "watch this and
  tell me when it changes" jobs cheap to schedule aggressively without spamming
  the originating session every tick.

  ## Normalization contract

  `normalize/1` collapses CRLF to LF, strips trailing whitespace from every
  line, and trims the ends. Everything else is content: a job whose output
  embeds a timestamp, a counter, or a random ordering will hash differently on
  every run and therefore always deliver. Writing an output that is stable while
  nothing interesting changed is the job author's contract.

  ## State

  Fingerprints live in the durable cron store (`:cron_monitor_state`, keyed by
  job id) rather than in the cron memory markdown file — that file is
  prompt-facing prose, unfit for structural state — so suppression survives a
  CronManager or node restart.

  State shape:

      %{
        last_hash: binary(),
        last_run_id: binary(),
        last_changed_at_ms: non_neg_integer(),
        updated_at_ms: non_neg_integer(),
        runs_since_change: non_neg_integer()
      }

  ## Delivery rules

  - Non-monitor jobs, unknown jobs, and runs that did not complete
    (`:failed`, `:timeout`, `:aborted`) always deliver and never touch state.
    Because failures leave state untouched, a recovery run that reproduces the
    pre-failure output is still suppressed.
  - The first monitored run records a baseline and delivers only when
    `monitor_notify_first_run` is true (or the run was manual).
  - Manual/wake runs always deliver, changed or not.
  - Store failures fail *open*: a broken store must never silently mute
    deliveries.

  ## Preflight-failure notices

  `apply_preflight_policy/2` is a separate, output-independent policy applied to
  *every* job (monitor or not). A preflight skip such as `:model_drift` or
  `:no_ready_provider` persists until an operator acts, so forwarding it on
  every occurrence would spam the originating session once per tick — the exact
  failure monitor mode exists to prevent. The first occurrence of a given
  `{class, detail}` is delivered in full, identical repeats are suppressed, and
  a reminder is re-delivered on a widening backoff (1h, then daily) annotated
  with how many runs have been blocked. Manual/wake runs always deliver — an
  operator triggering by hand is waiting for the answer. Any run that is not a
  preflight failure clears the state, so a recovery re-arms the next distinct
  failure.

  It keeps its own table (`:cron_preflight_notice_state`) so an output
  fingerprint and a failure fingerprint can never collide.
  """

  alias LemonAutomation.{CronJob, CronRun, CronStore}

  require Logger

  @doc """
  Normalize output for hashing: CRLF → LF, trailing per-line whitespace and
  surrounding blank lines removed.
  """
  @spec normalize(binary() | nil) :: binary()
  def normalize(nil), do: ""

  def normalize(output) when is_binary(output) do
    output
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  def normalize(_output), do: ""

  @doc """
  Lowercase hex SHA-256 of the normalized output.
  """
  @spec hash(binary() | nil) :: binary()
  def hash(output) do
    :crypto.hash(:sha256, normalize(output)) |> Base.encode16(case: :lower)
  end

  @doc """
  Whether monitor semantics apply to this job.
  """
  @spec monitor?(CronJob.t() | nil) :: boolean()
  def monitor?(%CronJob{monitor: true}), do: true
  def monitor?(_job), do: false

  @doc """
  Apply monitor policy to a finished run.

  Returns the (possibly suppressed) run and whether the summary should be
  forwarded to the originating session.
  """
  @spec apply_policy(CronJob.t() | nil, CronRun.t()) :: {CronRun.t(), boolean()}
  def apply_policy(job, %CronRun{} = run) do
    if monitor?(job) and run.status == :completed do
      evaluate(job, run)
    else
      {run, true}
    end
  rescue
    error ->
      Logger.warning("[CronMonitor] Monitor policy failed open: #{Exception.message(error)}")
      {run, true}
  catch
    :exit, reason ->
      Logger.warning("[CronMonitor] Monitor policy failed open: #{inspect(reason)}")
      {run, true}
  end

  @doc """
  Apply the preflight-failure notice policy to a finished run.

  Returns the (possibly suppressed) run and whether the summary should be
  forwarded. Applies to every job, monitor or not; runs that are not preflight
  failures pass through and clear any recorded failure fingerprint.
  """
  @spec apply_preflight_policy(CronJob.t() | nil, CronRun.t()) :: {CronRun.t(), boolean()}
  def apply_preflight_policy(job, %CronRun{} = run) do
    case {job, preflight_failure(run)} do
      {%CronJob{} = job, nil} ->
        CronStore.delete_preflight_notice_state(job.id)
        {run, true}

      {%CronJob{} = job, failure} ->
        evaluate_preflight(job, run, failure)

      _ ->
        {run, true}
    end
  rescue
    error ->
      Logger.warning(
        "[CronMonitor] Preflight notice policy failed open: #{Exception.message(error)}"
      )

      {run, true}
  catch
    :exit, reason ->
      Logger.warning("[CronMonitor] Preflight notice policy failed open: #{inspect(reason)}")
      {run, true}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp preflight_failure(%CronRun{meta: meta}) when is_map(meta) do
    case Map.get(meta, :preflight_failure) || Map.get(meta, "preflight_failure") do
      failure when is_map(failure) ->
        if is_nil(failure[:class]) and is_nil(failure["class"]), do: nil, else: failure

      _ ->
        nil
    end
  end

  defp preflight_failure(_run), do: nil

  defp evaluate_preflight(%CronJob{} = job, %CronRun{} = run, failure) do
    now = LemonCore.Clock.now_ms()
    class = failure[:class] || failure["class"]
    digest = hash(to_string(failure[:detail] || failure["detail"] || ""))
    previous = CronStore.get_preflight_notice_state(job.id)

    cond do
      is_nil(previous) or previous.class != class or previous.detail_hash != digest ->
        notify_preflight(job, run, class, digest, now, %{
          first_seen_at_ms: now,
          occurrences: 1,
          notifications: 1
        })

      # An operator who triggered the run by hand is waiting for the answer.
      run.triggered_by in [:manual, :wake] ->
        notify_preflight(job, run, class, digest, now, %{
          first_seen_at_ms: previous.first_seen_at_ms || now,
          occurrences: (previous.occurrences || 0) + 1,
          notifications: (previous.notifications || 1) + 1
        })

      true ->
        repeated_preflight(job, run, class, digest, now, previous)
    end
  end

  defp repeated_preflight(%CronJob{} = job, %CronRun{} = run, class, digest, now, previous) do
    occurrences = (previous.occurrences || 0) + 1
    last_notified = previous.last_notified_at_ms || previous.first_seen_at_ms || now

    if now - last_notified >= renotify_after_ms(previous.notifications || 1) do
      run = annotate_repeat(run, occurrences, previous.first_seen_at_ms)

      notify_preflight(job, run, class, digest, now, %{
        first_seen_at_ms: previous.first_seen_at_ms || now,
        occurrences: occurrences,
        notifications: (previous.notifications || 1) + 1
      })
    else
      CronStore.put_preflight_notice_state(job.id, %{
        class: class,
        detail_hash: digest,
        first_seen_at_ms: previous.first_seen_at_ms || now,
        last_notified_at_ms: last_notified,
        occurrences: occurrences,
        notifications: previous.notifications || 1
      })

      CronStore.record_audit(:preflight_notice_suppressed, %{
        job_id: job.id,
        run_id: run.id,
        source: :cron_monitor,
        status: run.status,
        triggered_by: run.triggered_by,
        reason: "#{class} unchanged (#{occurrences} runs)"
      })

      {CronRun.suppress(run), false}
    end
  end

  defp notify_preflight(%CronJob{} = job, %CronRun{} = run, class, digest, now, fields) do
    CronStore.put_preflight_notice_state(job.id, %{
      class: class,
      detail_hash: digest,
      first_seen_at_ms: fields.first_seen_at_ms,
      last_notified_at_ms: now,
      occurrences: fields.occurrences,
      notifications: fields.notifications
    })

    {run, true}
  end

  # Widening reminder cadence: the first repeat reminder after an hour, every
  # later one daily. A weekend-long outage is a handful of messages, not one
  # per tick.
  defp renotify_after_ms(notifications) when notifications <= 1, do: 3_600_000
  defp renotify_after_ms(_notifications), do: 86_400_000

  defp annotate_repeat(%CronRun{error: error} = run, occurrences, first_seen_at_ms)
       when is_binary(error) do
    since =
      case first_seen_at_ms do
        ms when is_integer(ms) -> " since #{DateTime.from_unix!(ms, :millisecond)}"
        _ -> ""
      end

    %{run | error: "#{error} (still blocked; #{occurrences} runs#{since})"}
  end

  defp annotate_repeat(run, _occurrences, _first_seen_at_ms), do: run

  defp evaluate(%CronJob{} = job, %CronRun{} = run) do
    digest = hash(run.output)
    previous = CronStore.get_monitor_state(job.id)
    manual? = run.triggered_by in [:manual, :wake]

    cond do
      is_nil(previous) or is_nil(previous.last_hash) ->
        baseline(job, run, digest, manual?)

      previous.last_hash == digest and not manual? ->
        unchanged(job, run, previous)

      previous.last_hash == digest ->
        # Manual run over unchanged output: deliver, but do not re-audit.
        {run, true}

      true ->
        changed(job, run, digest)
    end
  end

  defp baseline(%CronJob{} = job, %CronRun{} = run, digest, manual?) do
    now = LemonCore.Clock.now_ms()

    CronStore.put_monitor_state(job.id, %{
      last_hash: digest,
      last_run_id: run.id,
      last_changed_at_ms: now,
      updated_at_ms: now,
      runs_since_change: 0
    })

    CronStore.record_audit(:monitor_baseline_recorded, %{
      job_id: job.id,
      run_id: run.id,
      router_run_id: run.run_id,
      source: :cron_monitor,
      status: run.status,
      triggered_by: run.triggered_by,
      reason: "baseline #{hash_prefix(digest)}"
    })

    if manual? or job.monitor_notify_first_run do
      {run, true}
    else
      {CronRun.suppress(run), false}
    end
  end

  defp unchanged(%CronJob{} = job, %CronRun{} = run, previous) do
    now = LemonCore.Clock.now_ms()
    runs_since_change = (previous.runs_since_change || 0) + 1

    CronStore.put_monitor_state(job.id, %{
      last_hash: previous.last_hash,
      last_run_id: run.id,
      last_changed_at_ms: previous.last_changed_at_ms,
      updated_at_ms: now,
      runs_since_change: runs_since_change
    })

    CronStore.record_audit(:monitor_output_unchanged, %{
      job_id: job.id,
      run_id: run.id,
      router_run_id: run.run_id,
      source: :cron_monitor,
      status: run.status,
      triggered_by: run.triggered_by,
      reason: "unchanged #{hash_prefix(previous.last_hash)} (#{runs_since_change} runs)"
    })

    {CronRun.suppress(run), false}
  end

  defp changed(%CronJob{} = job, %CronRun{} = run, digest) do
    now = LemonCore.Clock.now_ms()

    CronStore.put_monitor_state(job.id, %{
      last_hash: digest,
      last_run_id: run.id,
      last_changed_at_ms: now,
      updated_at_ms: now,
      runs_since_change: 0
    })

    CronStore.record_audit(:monitor_output_changed, %{
      job_id: job.id,
      run_id: run.id,
      router_run_id: run.run_id,
      source: :cron_monitor,
      status: run.status,
      triggered_by: run.triggered_by,
      reason: "changed to #{hash_prefix(digest)}"
    })

    {run, true}
  end

  defp hash_prefix(digest) when is_binary(digest) and byte_size(digest) >= 12,
    do: binary_part(digest, 0, 12)

  defp hash_prefix(digest) when is_binary(digest), do: digest
  defp hash_prefix(_digest), do: "unknown"
end
