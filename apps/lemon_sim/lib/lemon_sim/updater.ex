defmodule LemonSim.Updater do
  @moduledoc false

  @callback apply_event(
              state :: LemonSim.Kernel.State.t(),
              event :: LemonSim.Kernel.Event.t() | map(),
              opts :: keyword()
            ) ::
              {:ok, LemonSim.Kernel.State.t(), LemonSim.Kernel.DecisionSignal.t()}
              | {:error, term()}
end
