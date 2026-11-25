defmodule LemonRouter.RunCompletion do
  @moduledoc false

  alias LemonCore.{ExecutionCommand, RunStore, TerminalOutbox}
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
      presentation_cwd: command.cwd,
      attempt_id: command.execution_context && command.execution_context.attempt_id,
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

        TerminalOutbox.publish(command.run_id, event)

      {:error, {:already_finalized, run_id}} when run_id == command.run_id ->
        :ok = LemonRouter.RunReceiptStore.retain_terminal_evidence(run_id)

        case committed_summary(run_id) do
          {:ok, summary} ->
            reconciled = TerminalOutbox.event(run_id, summary)
            send(self(), reconciled)
            TerminalOutbox.publish(run_id, reconciled)

          {:error, _} ->
            exit(:terminal_persistence_failed)
        end

      {:error, _reason} ->
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

          _ ->
            {:error, :missing_completion}
        end

      error ->
        error
    end
  end
end
