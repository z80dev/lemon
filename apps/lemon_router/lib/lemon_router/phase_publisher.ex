defmodule LemonRouter.PhasePublisher do
  @moduledoc """
  Emits router-owned canonical run phase changes on per-run bus topics.

  This module only covers the router phases introduced before gateway ownership
  begins. It validates canonical phases and legal transitions, skips duplicates,
  and returns the updated submission struct so coordinator state can track the
  latest emitted phase.
  """

  require Logger

  alias LemonCore.{Bus, Event, RunPhase, RunPhaseEvent, RunPhaseGraph}
  alias LemonRouter.Submission

  @spec emit(Submission.t(), RunPhase.t(), RunPhase.t() | nil, atom()) :: Submission.t()
  def emit(submission, phase, previous_phase, source \\ :lemon_router_session_coordinator)

  def emit(
        %Submission{run_id: run_id, session_key: session_key, conversation_key: conversation_key} =
          submission,
        phase,
        previous_phase,
        source
      )
      when is_binary(run_id) do
    cond do
      previous_phase == phase ->
        submission

      not RunPhase.valid?(phase) ->
        Logger.warning(
          "Router run phase emission skipped run_id=#{inspect(run_id)} invalid_phase=#{inspect(phase)}"
        )

        submission

      is_nil(previous_phase) ->
        emit_phase_change(run_id, session_key, conversation_key, phase, previous_phase, source)
        Submission.put_phase(submission, phase)

      true ->
        case RunPhaseGraph.transition(previous_phase, phase) do
          :ok ->
            emit_phase_change(
              run_id,
              session_key,
              conversation_key,
              phase,
              previous_phase,
              source
            )

            Submission.put_phase(submission, phase)

          {:error, {:invalid_transition, _, _}} ->
            Logger.warning(
              "Router run phase emission skipped run_id=#{inspect(run_id)} previous_phase=#{inspect(previous_phase)} phase=#{inspect(phase)}"
            )

            submission
        end
    end
  end

  def emit(%Submission{} = submission, _phase, _previous_phase, _source), do: submission

  defp emit_phase_change(run_id, session_key, conversation_key, phase, previous_phase, source) do
    payload =
      RunPhaseEvent.build(
        run_id: run_id,
        session_key: session_key,
        conversation_key: conversation_key,
        phase: phase,
        previous_phase: previous_phase,
        source: source
      )

    event =
      Event.new(
        :run_phase_changed,
        payload,
        %{run_id: run_id, session_key: session_key}
      )

    Bus.broadcast(Bus.run_topic(run_id), event)
  end
end
