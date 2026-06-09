defmodule LemonSim.DecisionSignal do
  @moduledoc false

  @type t :: LemonSim.Kernel.DecisionSignal.t()

  defdelegate decide?(signal), to: LemonSim.Kernel.DecisionSignal
end
