defmodule LemonSim.DecisionAdapters.ToolResultEvents do
  @moduledoc false

  defdelegate to_events(decision, state, opts),
    to: LemonSim.Kernel.DecisionAdapters.ToolResultEvents
end
