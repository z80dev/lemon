defmodule LemonSim.Examples.IntelNetworkNetworkGraphTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.IntelNetwork.NetworkGraph

  test "generates a deterministic connected undirected graph" do
    players = ~w(Alice Bram Cora Dane Etta Finn)

    adjacency = NetworkGraph.generate_adjacency(players)

    assert Map.keys(adjacency) |> Enum.sort() == Enum.sort(players)

    for player <- players do
      neighbors = Map.fetch!(adjacency, player)

      assert length(neighbors) in 2..4
      assert player not in neighbors

      for neighbor <- neighbors do
        assert NetworkGraph.adjacent?(adjacency, neighbor, player)
      end
    end

    assert connected?(adjacency, "Alice") == MapSet.new(players)
  end

  test "local views and intel assignment stay stable by player order" do
    players = ~w(Alice Bram Cora)
    adjacency = NetworkGraph.generate_adjacency(players)

    assert NetworkGraph.local_view(adjacency, "Alice") == ["Bram", "Cora"]
    assert NetworkGraph.local_view(adjacency, "missing") == []

    assert NetworkGraph.distribute_intel(players) == %{
             "Alice" => "fragment_alpha",
             "Bram" => "fragment_bravo",
             "Cora" => "fragment_charlie"
           }

    assert NetworkGraph.agent_codenames(3) == ["CARDINAL", "FALCON", "RAVEN"]
    assert "fragment_hotel" in NetworkGraph.all_fragments()
  end

  defp connected?(adjacency, start) do
    walk(adjacency, [start], MapSet.new())
  end

  defp walk(_adjacency, [], visited), do: visited

  defp walk(adjacency, [next | rest], visited) do
    if MapSet.member?(visited, next) do
      walk(adjacency, rest, visited)
    else
      neighbors = Map.get(adjacency, next, [])
      walk(adjacency, rest ++ neighbors, MapSet.put(visited, next))
    end
  end
end
