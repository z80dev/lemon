defmodule LemonRouter.RunCompletion do
  @moduledoc """
  The single terminal writer of the `:runs` table.

  Every run terminalizes here exactly once: `LemonRouter.RunProcess` for the
  runs it owns (executor completions and synthetic ones alike),
  `SessionCoordinator` for queued submissions dropped before any owner
  started, and `RunOrchestrator` crash recovery for an admission whose owner
  died with the VM (`abandon/2`). The terminal summary is persisted before the
  `:run_completed` event is published, so a waiter that sees the event can rely
  on the durable record.
  """

  alias LemonCore.{Bus, ExecutionCommand, RunStore}
  alias LemonRouter.RunProcess.CompactionTrigger

  @doc """
  Persist `event` as `command`'s terminal record, then publish it.

  Returns `{:published, event}` when this call wrote the record, or
  `{:already_finalized, event}` carrying the durable completion when another
  writer won; nothing is published then, so clients never see a contradictory
  second terminal event. A failed write exits `:terminal_persistence_failed`.
  """
  @spec finalize(ExecutionCommand.t(), LemonCore.Event.t(), keyword()) ::
          {:published | :already_finalized, LemonCore.Event.t()}
  def finalize(
        %ExecutionCommand{} = command,
        %LemonCore.Event{type: :run_completed} = event,
        opts \\ []
      ) do
    completed =
      event.payload.completed
      |> Map.put(:run_id, command.run_id)
      |> Map.put(:session_key, command.session_key)

    event = %{event | payload: %{event.payload | completed: completed}}

    summary = %{
      completed: completed,
      session_key: command.session_key,
      run_id: command.run_id,
      prompt: command.prompt,
      duration_ms: event.payload.duration_ms,
      completed_at_ms: System.system_time(:millisecond),
      engine: "lemon",
      meta: command.meta
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

        event = %{event | meta: Map.merge(event.meta || %{}, Keyword.get(opts, :meta, %{}))}
        Bus.broadcast(Bus.run_topic(command.run_id), event)
        {:published, event}

      {:error, {:already_finalized, run_id}} when run_id == command.run_id ->
        {:ok, %{summary: existing}} = RunStore.fetch(run_id)
        _ = LemonRouter.RunReceiptStore.retain_terminal_evidence_best_effort(run_id)
        {:already_finalized, %{event | payload: %{event.payload | completed: existing.completed}}}

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

  @doc """
  Record an unknown or refused outcome for a crash-recovered admission whose
  owner died with the VM. Nothing is published: no client waits on a run from
  a previous VM.
  """
  @spec abandon(binary(), map()) :: :ok | {:error, term()}
  def abandon(run_id, summary) when is_binary(run_id) and is_map(summary) do
    RunStore.finalize(run_id, summary)
  end
end
