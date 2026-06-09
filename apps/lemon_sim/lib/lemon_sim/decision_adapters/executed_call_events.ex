defmodule LemonSim.DecisionAdapters.ExecutedCallEvents do
  @moduledoc false

  defdelegate to_events(decision, state, opts),
    to: LemonSim.Kernel.DecisionAdapters.ExecutedCallEvents
end
