defmodule LemonSimUi.DomainRegistrationTest do
  @moduledoc """
  Completeness checks tying `lemon_sim_ui`'s per-domain registration points
  (`Arena`, `ArenaDomains`, `SpectatorLive`) back to the shared
  `LemonSim.Bench.Domains` registry. A domain can't be added to one of these
  and forgotten in another without one of these tests failing.
  """

  use ExUnit.Case, async: true

  alias LemonSim.Bench.Domains
  alias LemonSimUi.{Arena, ArenaDomains, SpectatorLive}

  defp arena_domain_ids do
    Domains.arena_domains() |> Enum.map(&String.to_atom(&1.id)) |> MapSet.new()
  end

  describe "LemonSimUi.Arena" do
    test "domains/0 matches Domains.arena_domains/0 membership exactly" do
      assert MapSet.new(Arena.domains()) == arena_domain_ids()
    end

    test "domains/0 preserves the curated werewolf-first display order" do
      # Domains.arena_domains/0 exists specifically to preserve this order
      # (see its moduledoc); the lobby page's arena card order depends on it.
      assert Arena.domains() == [:werewolf, :space_station, :stock_market, :survivor, :poker]
    end

    test "sim_prefix/1 matches the registry for every arena domain" do
      for descriptor <- Domains.arena_domains() do
        domain = String.to_atom(descriptor.id)
        assert Arena.sim_prefix(domain) == descriptor.sim_id_prefix
      end
    end

    test "default player counts are unchanged from before the Domains-derived refactor" do
      # Snapshot of the values LemonSimUi.Arena hardcoded before deriving
      # from LemonSim.Bench.Domains. Poker intentionally diverges from the
      # registry's own `default_player_count` (4): the arena always seats 6.
      expected = %{
        werewolf: 6,
        space_station: 6,
        stock_market: 4,
        survivor: 8,
        poker: 6
      }

      for {domain, count} <- expected do
        assert Arena.default_player_count(domain) == count
      end
    end
  end

  describe "LemonSimUi.ArenaDomains" do
    test "presentation map keys match Domains.arena_domains/0 exactly" do
      assert MapSet.new(ArenaDomains.keys()) == arena_domain_ids()
    end
  end

  describe "LemonSimUi.SpectatorLive" do
    test "supported_domains/0 is a superset of the arena domains" do
      assert MapSet.subset?(arena_domain_ids(), MapSet.new(SpectatorLive.supported_domains()))
    end

    test "supported_domains/0 stays in sync with the board dispatch case clauses" do
      assert MapSet.new(SpectatorLive.supported_domains()) ==
               MapSet.new(SpectatorLive.rendered_board_domains())
    end

    test "every supported domain id is registered in LemonSim.Bench.Domains" do
      registered_ids = MapSet.new(Domains.keys(), &String.to_atom/1)

      for domain <- SpectatorLive.supported_domains() do
        assert domain in registered_ids, "#{domain} is not registered in LemonSim.Bench.Domains"
      end
    end
  end
end
