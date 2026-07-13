defmodule LemonSim.Kernel.StoreTest do
  use ExUnit.Case, async: false

  alias LemonSim.Kernel.Store

  test "malformed persisted records are skipped without crashing reads" do
    sim_id = "malformed_sim_#{System.unique_integer([:positive])}"

    on_exit(fn -> LemonCore.Store.delete(:lemon_sim_world_states, sim_id) end)
    assert :ok = LemonCore.Store.put(:lemon_sim_world_states, sim_id, %{world: %{}})

    assert Store.get_state(sim_id) == nil
    refute Enum.any?(Store.list_states(), &(&1.sim_id == sim_id))
  end
end
