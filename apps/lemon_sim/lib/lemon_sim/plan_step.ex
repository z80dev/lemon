defmodule LemonSim.PlanStep do
  @moduledoc false

  @type t :: LemonSim.Kernel.PlanStep.t()

  defdelegate new(summary, opts \\ []), to: LemonSim.Kernel.PlanStep
end
