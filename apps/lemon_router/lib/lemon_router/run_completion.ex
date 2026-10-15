defmodule LemonRouter.RunCompletion do
  @moduledoc false

  alias LemonCore.{Bus, ExecutionCommand, RunStore}
  alias LemonRouter.RunProcess.CompactionTrigger

  # Runs removed before an executor owns them still need the same durable
  # terminal receipt as executed runs. Persist before notifying waiters.
  def publish(%ExecutionCommand{} = command, %LemonCore.Event{type: :run_completed} = event) do
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
      engine: "lemon",
      meta: command.meta
    }

    case RunStore.finalize(command.run_id, summary) do
      :ok ->
        :ok = LemonRouter.RunReceiptStore.retain_terminal_evidence(command.run_id)

        # Pre-executor terminalizations have no RunProcess to write history.
        # A stable event ID lets a live RunProcess enrich the same receipt.
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

        Bus.broadcast(Bus.run_topic(command.run_id), event)

      {:error, {:already_finalized, run_id}} when run_id == command.run_id ->
        # A late gateway completion may have won during the grace window.
        # Reconcile this owner from the durable result without broadcasting a
        # contradictory second terminal event to clients.
        {:ok, %{summary: existing}} = RunStore.fetch(run_id)
        :ok = LemonRouter.RunReceiptStore.retain_terminal_evidence(run_id)
        send(self(), %{event | payload: %{event.payload | completed: existing.completed}})
        :ok

      {:error, _reason} ->
        exit(:terminal_persistence_failed)
    end
  end
end
