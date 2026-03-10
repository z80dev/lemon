defmodule LemonCore.RunPhaseGraph do
  @moduledoc """
  Legal canonical run phase transitions across router and gateway boundaries.
  """

  alias LemonCore.RunPhase

  @transitions %{
    accepted: [:queued_in_session, :waiting_for_slot, :aborted],
    queued_in_session: [:waiting_for_slot, :aborted],
    waiting_for_slot: [:dispatched_to_gateway, :aborted, :failed],
    dispatched_to_gateway: [:starting_engine, :failed, :aborted],
    starting_engine: [:streaming, :finalizing, :failed, :aborted],
    streaming: [:finalizing, :failed, :aborted],
    finalizing: [:completed, :failed],
    completed: [],
    failed: [],
    aborted: []
  }

  @spec allowed_next(RunPhase.t()) :: [RunPhase.t()]
  def allowed_next(phase), do: Map.get(@transitions, phase, [])

  @spec valid_transition?(RunPhase.t(), RunPhase.t()) :: boolean()
  def valid_transition?(from, to), do: to in allowed_next(from)

  @spec transition(RunPhase.t(), RunPhase.t()) ::
          :ok | {:error, {:invalid_transition, RunPhase.t(), RunPhase.t()}}
  def transition(from, to) do
    if valid_transition?(from, to) do
      :ok
    else
      {:error, {:invalid_transition, from, to}}
    end
  end
end
