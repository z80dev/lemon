defmodule LemonSim.Bench.DomainsTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.Domains
  alias LemonSim.Bench.Domains.Descriptor

  describe "all/0" do
    test "every descriptor has a loadable example module and scorecard module" do
      for %Descriptor{} = descriptor <- Domains.all() do
        assert is_binary(descriptor.id) and descriptor.id != ""

        assert {:module, module} = Code.ensure_loaded(descriptor.example_module)
        assert function_exported?(module, :initial_world, 1)
        assert function_exported?(module, :initial_state, 1)
        assert function_exported?(module, :modules, 0) or function_exported?(module, :modules, 1)

        assert {:module, scorecard} = Code.ensure_loaded(descriptor.scorecard_module)
        assert LemonSim.Bench.Scorecard in behaviours(scorecard)
        assert function_exported?(scorecard, :scorecard, 1)
      end
    end

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

    test "every league-adapter domain also has a sim_id_prefix and a default_player_count" do
      for %Descriptor{league_adapter: adapter} = descriptor <- Domains.all(),
          not is_nil(adapter) do
        assert is_binary(descriptor.sim_id_prefix)
        assert is_integer(descriptor.default_player_count)
      end
    end

    test "tcg_shop and vending_bench carry SimManager's sim_id_prefix without a league adapter" do
      assert %Descriptor{sim_id_prefix: "tcg_", league_adapter: nil} = Domains.get("tcg_shop")
      assert %Descriptor{sim_id_prefix: "vb_", league_adapter: nil} = Domains.get("vending_bench")
    end
  end

  describe "keys/0" do
    test "matches the ids in all/0, in order" do
      assert Domains.keys() == Enum.map(Domains.all(), & &1.id)
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
    test "returns exactly the five always-on league domains with their arena metadata" do
      arena =
        Domains.arena_domains() |> Enum.map(&{&1.id, &1.sim_id_prefix, &1.default_player_count})

      assert Enum.sort(arena) == [
               {"poker", "pkr_", 4},
               {"space_station", "spc_", 6},
               {"stock_market", "stk_", 4},
               {"survivor", "srv_", 8},
               {"werewolf", "ww_", 6}
             ]
    end

    test "every arena domain has a non-nil league_adapter" do
      assert Enum.all?(Domains.arena_domains(), &(&1.league_adapter != nil))
    end
  end

  defp behaviours(module) do
    module.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end
end
