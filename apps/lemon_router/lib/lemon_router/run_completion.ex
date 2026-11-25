defmodule LemonRouter.RunCompletion do
  @moduledoc """
  Router's single entry point for committing run outcomes.

  The live run owner, coordinator rejection and crash recovery all commit
  through the same durable terminal fence. `LemonCore.TerminalOutbox` publishes
  the committed completion using that fence's attempt identity.
  """

  alias LemonCore.{ExecutionCommand, RunStore, TerminalOutbox}
  alias LemonRouter.RunProcess.CompactionTrigger

  @doc """
  Persist `event` as `command`'s terminal record, then publish it.

  Returns `{:published, event}` when this call committed the result, or
  `{:already_finalized, event_or_nil}` when an earlier decision won. The
  outbox publishes only a pending notification for the committed result.
  A failed write exits `:terminal_persistence_failed`.
  """
  @spec finalize(ExecutionCommand.t(), LemonCore.Event.t(), keyword()) ::
          {:published, LemonCore.Event.t()} | {:already_finalized, LemonCore.Event.t() | nil}
  def finalize(
        %ExecutionCommand{} = command,
        %LemonCore.Event{type: :run_completed} = event,
        opts \\ []
      ) do
    completed =
      event.payload.completed
      |> Map.put(:run_id, command.run_id)
      |> Map.put(:session_key, command.session_key)

    attempt_id =
      if command.execution_context,
        do: command.execution_context.attempt_id,
        else: "#{command.run_id}:attempt:1"

    summary_meta =
      if Keyword.get(opts, :router_owned, false),
        do: Map.put(command.meta || %{}, :router_owned, true),
        else: command.meta

    event = %{
      event
      | payload: %{event.payload | completed: completed},
        meta:
          (event.meta || %{})
          |> Map.merge(Keyword.get(opts, :meta, %{}))
          |> Map.put(:session_key, command.session_key)
    }

    summary = %{
      completed: completed,
      session_key: command.session_key,
      run_id: command.run_id,
      attempt_id: attempt_id,
      prompt: command.prompt,
      presentation_cwd: command.cwd,
      duration_ms: event.payload.duration_ms,
      completed_at_ms: System.system_time(:millisecond),
      engine: "lemon",
      terminal_event_meta: event.meta,
      meta: summary_meta
    }

    case RunStore.finalize(command.run_id, summary) do
      :ok ->
        _ = LemonRouter.RunReceiptStore.retain_terminal_evidence_best_effort(command.run_id)

        # A stable event ID lets the owning RunProcess enrich the same receipt.
        LemonCore.Introspection.record(
          :run_completed,
          %{
            ok: completed.ok,
            error: CompactionTrigger.safe_error_label(Map.get(completed, :error)),
            duration_ms: event.payload.duration_ms
          },
          event_id: "run_completed:#{command.run_id}",
          run_id: command.run_id,
          session_key: command.session_key,
          engine: "lemon"
        )

        LemonCore.Telemetry.emit(
          [:lemon, :run, :stop],
          %{duration_ms: event.payload.duration_ms || 0, ok: completed.ok},
          %{run_id: command.run_id, session_key: command.session_key, engine: "lemon"}
        )

        _ = TerminalOutbox.publish(command.run_id, event)
        {:published, event}

      {:error, {:already_finalized, run_id}} when run_id == command.run_id ->
        {:already_finalized, reconcile(run_id)}

      {:error, _reason} ->
        exit(:terminal_persistence_failed)
    end
  end

  @doc "Terminalize a run that has no owner (see `finalize/3`)."
  @spec publish(ExecutionCommand.t(), LemonCore.Event.t()) :: :ok
  def publish(%ExecutionCommand{} = command, %LemonCore.Event{type: :run_completed} = event) do
    _ = finalize(command, event)
    :ok
  end

  @doc "Record the outcome of an admission whose owner died with the VM."
  @spec abandon(binary(), map()) :: :ok | {:error, term()}
  def abandon(run_id, summary) when is_binary(run_id) and is_map(summary) do
    RunStore.finalize(run_id, summary)
  end

  @doc false
  def reconcile(run_id) do
    _ = LemonRouter.RunReceiptStore.retain_terminal_evidence_best_effort(run_id)

    case committed_summary(run_id) do
      {:ok, summary} when is_map(summary) ->
        event = TerminalOutbox.event(run_id, summary)
        _ = TerminalOutbox.publish(run_id, event)
        event

      {:ok, nil} ->
        # Retention or session deletion removed the payload, not the fence.
        nil

      {:error, _} ->
        exit(:terminal_persistence_failed)
    end
  end

  defp committed_summary(run_id) do
    case RunStore.fetch(run_id) do
      {:ok, %{summary: %{completed: completed} = summary}} when is_map(completed) ->
        {:ok, summary}

      result when elem(result, 0) == :ok or result == {:error, :evicted} ->
        case TerminalOutbox.pending(run_id) do
          {:ok, %{record: %{summary: %{completed: completed} = summary}}}
          when is_map(completed) ->
            {:ok, summary}

          {:ok, _} ->
            {:ok, nil}

          error ->
            error
        end

      error ->
        error
    end
  end
end
