defmodule LemonSim.Kernel.Updater do
  @moduledoc """
  Behaviour for applying inbound events to simulation state.

  The updater owns domain-specific projection from event -> state mutations and
  decides whether a model decision is required.
  """

  @callback apply_event(
              state :: LemonSim.Kernel.State.t(),
              event :: LemonSim.Kernel.Event.t() | map(),
              opts :: keyword()
            ) ::
              {:ok, LemonSim.Kernel.State.t(), LemonSim.Kernel.DecisionSignal.t()} | {:error, term()}
end
