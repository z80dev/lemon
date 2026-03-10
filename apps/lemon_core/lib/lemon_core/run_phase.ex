defmodule LemonCore.RunPhase do
  @moduledoc """
  Canonical end-to-end lifecycle phases for a run across router and gateway.

  These phases provide a shared vocabulary for observability, debugging, and
  boundary clarity. Subsystems may maintain additional local state, but any
  externally observable lifecycle should map onto this phase model.
  """

  @type t ::
          :accepted
          | :queued_in_session
          | :waiting_for_slot
          | :dispatched_to_gateway
          | :starting_engine
          | :streaming
          | :finalizing
          | :completed
          | :failed
          | :aborted

  @ordered [
    :accepted,
    :queued_in_session,
    :waiting_for_slot,
    :dispatched_to_gateway,
    :starting_engine,
    :streaming,
    :finalizing,
    :completed,
    :failed,
    :aborted
  ]

  @phase_set MapSet.new(@ordered)

  @spec all() :: [t()]
  def all, do: @ordered

  @spec valid?(term()) :: boolean()
  def valid?(phase), do: MapSet.member?(@phase_set, phase)

  @spec terminal?(t()) :: boolean()
  def terminal?(phase), do: phase in [:completed, :failed, :aborted]
end
