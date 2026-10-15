defmodule LemonSim.Bench.DomainsTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Domains
  alias LemonSim.Bench.Domains.Descriptor

  describe "all/0" do
    test "ids are unique" do
      ids = Enum.map(Domains.all(), & &1.id)
      assert Enum.sort(ids) == ids |> Enum.uniq() |> Enum.sort()
    end

    test "league adapters implement the Adapter behaviour and self-report the same id" do
      for %Descriptor{league_adapter: adapter} = descriptor <- Domains.all(),
          not is_nil(adapter) do
        assert {:module, module} = Code.ensure_loaded(adapter)
        assert LemonSim.Bench.League.Adapter in behaviours(module)
        assert adapter.scenario_id() == descriptor.id
        assert adapter.mode() in [:team] or match?({:ranked, _}, adapter.mode())
      end
    end

    test "vending_bench carries SimManager's sim_id_prefix without a league adapter" do
      assert %Descriptor{sim_id_prefix: "vb_", league_adapter: nil} = Domains.get("vending_bench")
    end
  end

  describe "get/1 and fetch/1" do
    test "look up by string or atom id" do
      assert %Descriptor{id: "poker"} = Domains.get("poker")
      assert %Descriptor{id: "poker"} = Domains.get(:poker)
      assert {:ok, %Descriptor{id: "poker"}} = Domains.fetch("poker")
    end

    test "return nil / :error for unregistered ids" do
      assert Domains.get("not_a_domain") == nil
      assert Domains.fetch("not_a_domain") == :error
    end
  end

  describe "arena_domains/0" do
    test "returns the always-on league domains in display order" do
      assert Enum.map(Domains.arena_domains(), & &1.id) == ["werewolf", "poker"]
    end
  end

  defp behaviours(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end
end
