defmodule LemonSim.Bench.Scorecard.RegistryTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Scorecard.Registry

  test "unregistered scenarios keep skip semantics" do
    assert Registry.fetch("unknown_scenario") == :error
    assert Registry.scorecard("unknown_scenario", %{}) == {:ok, :skip}
  end
end
