defmodule LemonRouter.RestartCarryover do
  @moduledoc """
  Router side of a runtime drain (`LemonCore.Drain`): finish, suspend and carry
  conversation work across a restart.

  In the `:work` phase the router holds queued submissions, gives active runs
  the grace period to finish, then asks each remaining `RunProcess` to stop at
  the next point where no effectful action (tool, command, file change, web
  search, subagent) is executing. Shortly before the deadline any run still
  inside such an action is stopped anyway and marked uncertain. Admission is
  then sealed and one record per conversation is persisted in the
  `:router_restart_carryover` Store table:

    * an interrupted run continues the same native session with a short
      notice. When an action was cut off the model is told its outcome is
      unknown and must not repeat it without asking;
    * a submission the runtime never started is replayed with its original
      request.

  Each item gets its run ID when it is persisted. `replay/0` runs after the
  next boot and submits every item under that fixed ID, so a crash during
  replay can never start the same item twice; a record is deleted once all of
  its items are settled. Requests holding process-bound terms (pids,
  references, ports, funs) cannot outlive the VM and are skipped and counted.
  """

  @behaviour LemonCore.Drain

  require Logger

  alias LemonCore.{RunRequest, Store}
  alias LemonRouter.{RunProcess, SessionCoordinator, Submission}

  @table :router_restart_carryover
  @admission_key {__MODULE__, :admission}
  @poll_ms 100
  @force_margin_ms 3_000
  @settle_margin_ms 1_000
  @max_replay_attempts 3
  @identity_meta_keys [
    :router_request_identity,
    :router_replay_identity,
    :router_replay_content_identity
  ]

  @doc false
  def table, do: @table

  @doc "Whether queued work must stay queued (a drain is in progress)."
  @spec holding?() :: boolean()
  def holding?, do: :persistent_term.get(@admission_key, :open) != :open

  @doc "Whether new submissions must be refused (the carryover is persisted)."
  @spec sealed?() :: boolean()
  def sealed?, do: :persistent_term.get(@admission_key, :open) == :sealed

  @doc false
  # Tests only: reopen admission and restart held queues.
  def reset do
    :persistent_term.put(@admission_key, :open)
    SessionCoordinator.resume_all()
    :ok
  end

  # ── Drain ────────────────────────────────────────────────────────────────

  @impl LemonCore.Drain
  def drain(:ingress, _ctx), do: :ok

  def drain(:work, ctx) do
    :persistent_term.put(@admission_key, :holding)
    await_no_runs(ctx.grace_deadline_ms)

    %{snapshots: before} = SessionCoordinator.restart_snapshots()
    active = active_runs(before)

    outcomes =
      active
      |> Map.new(fn {run_id, entry} -> {run_id, entry.pid} end)
      |> suspend_runs(ctx.deadline_ms)

    await_no_runs(ctx.deadline_ms - @settle_margin_ms)
    :persistent_term.put(@admission_key, :sealed)

    %{snapshots: after_suspend, unavailable: unavailable} =
      SessionCoordinator.restart_snapshots()

    {records, skipped} = build_records(active, outcomes, after_suspend)
    persisted = persist(records)

    kinds = Enum.frequencies_by(outcomes, fn {_run_id, outcome} -> outcome_kind(outcome) end)

    {:ok,
     %{
       clean: Map.get(kinds, :clean, 0),
       uncertain: Map.get(kinds, :uncertain, 0),
       not_started: Map.get(kinds, :not_started, 0),
       finished: Map.get(kinds, :completed, 0) + Map.get(kinds, :not_running, 0),
       carried: persisted,
       skipped: skipped,
       unavailable_coordinators: unavailable
     }}
  end

  defp outcome_kind({:uncertain, _titles}), do: :uncertain
  defp outcome_kind(outcome), do: outcome

  defp await_no_runs(deadline_ms) do
    cond do
      run_count() == 0 ->
        :ok

      now() >= deadline_ms ->
        :timeout

      true ->
        Process.sleep(@poll_ms)
        await_no_runs(deadline_ms)
    end
  end

  defp run_count do
    Registry.count(LemonRouter.RunRegistry)
  rescue
    ArgumentError -> 0
  end

  defp active_runs(snapshots) do
    for %{active: %{run_id: run_id} = active} = snapshot <- snapshots,
        is_binary(run_id),
        into: %{} do
      {run_id,
       %{
         pid: active.pid,
         submission: active.submission,
         conversation_key: snapshot.conversation_key
       }}
    end
  end

  # Ask every run to stop at a tool boundary; shortly before the deadline force
  # the ones still inside an action. A run that exits without answering
  # finished on its own.
  defp suspend_runs(pids, deadline_ms) do
    monitors =
      for {run_id, pid} <- pids, is_pid(pid), into: %{} do
        RunProcess.suspend_for_restart(pid, self(), :boundary)
        {Process.monitor(pid), run_id}
      end

    outcomes = Map.new(pids, fn {run_id, pid} -> {run_id, if(is_pid(pid), do: nil, else: :not_running)} end)
    outcomes = collect(outcomes, monitors, deadline_ms - @force_margin_ms)

    for {run_id, nil} <- outcomes, pid = pids[run_id], Process.alive?(pid) do
      RunProcess.suspend_for_restart(pid, self(), :now)
    end

    outcomes = collect(outcomes, monitors, deadline_ms - @settle_margin_ms)
    Enum.each(monitors, fn {monitor, _run_id} -> Process.demonitor(monitor, [:flush]) end)
    Map.new(outcomes, fn {run_id, outcome} -> {run_id, outcome || :uncertain} end)
  end

  defp collect(outcomes, monitors, deadline_ms) do
    if Enum.all?(outcomes, fn {_id, outcome} -> outcome != nil end) do
      outcomes
    else
      receive do
        {:restart_suspended, run_id, outcome, titles} when is_map_key(outcomes, run_id) ->
          outcome = if titles == [] or outcome != :uncertain, do: outcome, else: {:uncertain, titles}
          collect(Map.put(outcomes, run_id, outcome), monitors, deadline_ms)

        {:DOWN, monitor, :process, _pid, _reason} when is_map_key(monitors, monitor) ->
          run_id = monitors[monitor]

          outcomes =
            if outcomes[run_id] == nil, do: Map.put(outcomes, run_id, :completed), else: outcomes

          collect(outcomes, monitors, deadline_ms)
      after
        max(deadline_ms - now(), 0) -> outcomes
      end
    end
  end

  # ── Records ──────────────────────────────────────────────────────────────

  defp build_records(active, outcomes, snapshots) do
    queued_by_conversation =
      Map.new(snapshots, fn snapshot -> {snapshot.conversation_key, snapshot} end)

    interrupted_by_conversation =
      Enum.group_by(active, fn {_run_id, entry} -> entry.conversation_key end)

    conversations =
      Enum.uniq(Map.keys(interrupted_by_conversation) ++ Map.keys(queued_by_conversation))

    Enum.map_reduce(conversations, 0, fn conversation_key, skipped ->
      interrupted =
        interrupted_by_conversation
        |> Map.get(conversation_key, [])
        |> Enum.flat_map(fn {run_id, entry} ->
          interrupted_item(entry.submission, outcome(outcomes, run_id))
        end)

      snapshot = Map.get(queued_by_conversation, conversation_key, %{active: nil, queued: []})
      still_active = still_active_item(snapshot.active, active)
      queued = Enum.map(snapshot.queued, &replay_item/1)
      {items, dropped} = Enum.split_with(interrupted ++ still_active ++ queued, &is_map/1)
      {%{items: items}, skipped + length(dropped)}
    end)
    |> then(fn {records, skipped} -> {Enum.reject(records, &(&1.items == [])), skipped} end)
  end

  defp outcome(outcomes, run_id) do
    case Map.get(outcomes, run_id, :uncertain) do
      {:uncertain, titles} -> {:uncertain, titles}
      :uncertain -> {:uncertain, []}
      other -> other
    end
  end

  # A run active at seal time was never confirmed stopped; the VM stop ends it.
  defp still_active_item(%{run_id: run_id, submission: submission}, active)
       when is_map_key(active, run_id) == false do
    interrupted_item(submission, {:uncertain, []})
  end

  defp still_active_item(_active, _known), do: []

  defp interrupted_item(%Submission{} = submission, :clean),
    do: [continue_item(submission, continue_prompt(:clean), :clean)]

  defp interrupted_item(%Submission{} = submission, {:uncertain, _titles} = outcome),
    do: [continue_item(submission, continue_prompt(outcome), :uncertain)]

  defp interrupted_item(%Submission{} = submission, :not_started), do: [replay_item(submission)]
  defp interrupted_item(_submission, _finished_or_unknown), do: []

  defp continue_item(%Submission{request: %RunRequest{} = request} = submission, prompt, outcome) do
    meta =
      (request.meta || %{})
      |> Map.drop([:disable_auto_resume, "disable_auto_resume"])
      |> Map.put(:restart_continuation, true)

    carry(%RunRequest{request | prompt: prompt, images: [], queue_mode: :collect, meta: meta},
      kind: :continue,
      outcome: outcome,
      interrupted_run_id: submission.run_id
    )
  end

  defp continue_item(_submission, _prompt, _outcome), do: :skipped

  defp replay_item(%Submission{request: %RunRequest{} = request} = submission),
    do: carry(request, kind: :replay, outcome: :queued, interrupted_run_id: submission.run_id)

  defp replay_item(_submission), do: :skipped

  defp carry(%RunRequest{} = request, fields) do
    meta = Map.drop(request.meta || %{}, @identity_meta_keys)
    request = %RunRequest{request | run_id: LemonCore.Id.run_id(), meta: meta}

    if vm_independent?(request) do
      Map.new(fields) |> Map.put(:request, request)
    else
      Logger.warning(
        "Restart carryover skipped a request holding process-bound terms",
        session_key: request.session_key
      )

      :skipped
    end
  end

  @doc false
  def continue_prompt(:clean) do
    "[Lemon restarted while you were working on this request. Your progress in this " <>
      "conversation was saved. Continue the task from where you stopped and do not " <>
      "redo steps that already finished.]"
  end

  def continue_prompt({:uncertain, titles}) do
    listed =
      case titles do
        [] -> "an action"
        titles -> Enum.map_join(titles, "; ", &"`#{&1}`")
      end

    "[Lemon restarted while #{listed} was still running. Its outcome is unknown: it " <>
      "may have finished, partly run, or not run at all. Do not repeat it automatically. " <>
      "Check the current state where you can, tell the user what was interrupted, and " <>
      "ask before redoing anything that changes state.]"
  end

  defp vm_independent?(term) when is_pid(term) or is_reference(term) or is_port(term),
    do: false

  defp vm_independent?(term) when is_function(term), do: false
  defp vm_independent?(%_{} = struct), do: struct |> Map.from_struct() |> vm_independent?()

  defp vm_independent?(term) when is_map(term),
    do: Enum.all?(term, fn {k, v} -> vm_independent?(k) and vm_independent?(v) end)

  defp vm_independent?(term) when is_list(term), do: list_independent?(term)

  defp vm_independent?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> vm_independent?()

  defp vm_independent?(_term), do: true

  # Improper lists (iodata) are valid terms too.
  defp list_independent?([]), do: true
  defp list_independent?([head | tail]), do: vm_independent?(head) and list_independent?(tail)
  defp list_independent?(tail), do: vm_independent?(tail)

  defp persist(records) do
    recorded_at = System.system_time(:millisecond)

    persisted =
      records
      |> Enum.with_index()
      |> Enum.count(fn {record, index} ->
        value = Map.merge(record, %{version: 1, recorded_at_ms: recorded_at, attempts: 0})

        case Store.put(@table, {recorded_at, index}, value) do
          :ok -> true
          _ -> false
        end
      end)

    _ = Store.sync()
    persisted
  end

  # ── Replay ───────────────────────────────────────────────────────────────

  @doc """
  Submit every persisted carryover item in recorded order and delete settled
  records. Returns counts; a store failure leaves records for the next boot.
  """
  @spec replay(keyword()) :: {:ok, map()} | {:error, term()}
  def replay(opts \\ []) do
    submit = Keyword.get(opts, :submit, &LemonRouter.submit/1)

    with {:ok, rows} <- Store.fetch_all(@table) do
      summary =
        rows
        |> Enum.sort_by(fn {key, _record} -> key end)
        |> Enum.reduce(%{submitted: 0, rejected: 0, pending: 0}, fn {key, record}, acc ->
          replay_record(key, record, submit, acc)
        end)

      if rows != [], do: Logger.warning("Restart carryover replayed: #{inspect(summary)}")
      {:ok, summary}
    end
  end

  defp replay_record(key, %{items: items} = record, submit, acc) do
    {remaining, acc} =
      Enum.reduce(items, {[], acc}, fn item, {remaining, acc} ->
        case submit.(item.request) do
          {:ok, _run_id} ->
            {remaining, %{acc | submitted: acc.submitted + 1}}

          {:error, :outcome_unknown} ->
            # The fixed run ID makes a later attempt idempotent.
            {[item | remaining], %{acc | pending: acc.pending + 1}}

          {:error, reason} ->
            Logger.warning("Restart carryover item rejected: #{inspect(reason, limit: 5)}",
              session_key: item.request.session_key
            )

            {remaining, %{acc | rejected: acc.rejected + 1}}
        end
      end)

    attempts = Map.get(record, :attempts, 0) + 1

    _ =
      if remaining == [] or attempts >= @max_replay_attempts do
        Store.delete(@table, key)
      else
        Store.put(@table, key, %{record | items: Enum.reverse(remaining), attempts: attempts})
      end

    acc
  end

  defp replay_record(key, _malformed, _submit, acc) do
    _ = Store.delete(@table, key)
    acc
  end

  defp now, do: System.monotonic_time(:millisecond)
end
