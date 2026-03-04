defmodule LemonSim.Updater do
  @moduledoc """
  Behaviour for applying inbound events to simulation state.

  The updater owns domain-specific projection from event -> state mutations and
  decides whether a model decision is required.
  """

  @callback apply_event(
              state :: LemonSim.State.t(),
              event :: LemonSim.Event.t() | map(),
              opts :: keyword()
            ) ::
              {:ok, LemonSim.State.t(), LemonSim.DecisionSignal.t()} | {:error, term()}
end
