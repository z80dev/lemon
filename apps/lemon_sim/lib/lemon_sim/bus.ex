defmodule LemonSim.Bus do
  @moduledoc false

  defdelegate sim_topic(sim_id), to: LemonSim.Kernel.Bus
  defdelegate decisions_topic(sim_id), to: LemonSim.Kernel.Bus
  defdelegate subscribe(sim_id), to: LemonSim.Kernel.Bus
  defdelegate unsubscribe(sim_id), to: LemonSim.Kernel.Bus
  defdelegate subscribe_decisions(sim_id), to: LemonSim.Kernel.Bus
  defdelegate broadcast_world_update(sim_id, payload), to: LemonSim.Kernel.Bus
  defdelegate broadcast_decision(sim_id, payload), to: LemonSim.Kernel.Bus
end
