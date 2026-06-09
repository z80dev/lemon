defmodule LemonSim.DecisionFrame do
  @moduledoc false

  @type t :: LemonSim.Kernel.DecisionFrame.t()

  defdelegate from_state(state, opts \\ []), to: LemonSim.Kernel.DecisionFrame
end
