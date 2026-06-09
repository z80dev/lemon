defmodule LemonSim.Store do
  @moduledoc false

  defdelegate put_state(state), to: LemonSim.Kernel.Store
  defdelegate get_state(sim_id), to: LemonSim.Kernel.Store
  defdelegate delete_state(sim_id), to: LemonSim.Kernel.Store
  defdelegate list_states(), to: LemonSim.Kernel.Store
end
