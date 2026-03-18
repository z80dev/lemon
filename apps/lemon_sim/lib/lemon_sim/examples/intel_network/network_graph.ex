defmodule LemonSim.Examples.IntelNetwork.NetworkGraph do
  @moduledoc """
  Topology generation and adjacency helpers for the Intelligence Network simulation.

  Generates a connected graph where each node has 2-3 connections,
  assigns codenames to agents, and distributes intel fragments.
  """

  @agent_codenames [
    "CARDINAL", "FALCON", "RAVEN", "SPHINX", "VIPER", "LYNX",
    "COBRA", "EAGLE"
  ]

  @intel_fragments [
    "fragment_alpha",
    "fragment_bravo",
    "fragment_charlie",
    "fragment_delta",
    "fragment_echo",
    "fragment_foxtrot",
    "fragment_golf",
    "fragment_hotel"
  ]

  @doc """
  Returns the list of agent codenames for a given player count.
  """
  @spec agent_codenames(pos_integer()) :: [String.t()]
  def agent_codenames(count) do
    Enum.take(@agent_codenames, count)
  end

  @doc """
  Generates a connected adjacency map for the given player IDs.
  Each node will have 2-3 connections. Uses a deterministic algorithm
  for reproducibility.
  """
  @spec generate_adjacency([String.t()]) :: %{String.t() => [String.t()]}
  def generate_adjacency(player_ids) do
    n = length(player_ids)

    # Start with a ring topology (guaranteed connectivity, each node has 2)
    ring_edges =
      Enum.map(0..(n - 1), fn i ->
        a = Enum.at(player_ids, i)
        b = Enum.at(player_ids, rem(i + 1, n))
        {a, b}
      end)

    # Add extra edges to reach 3 connections for some nodes (up to n/2 extra edges)
    extra_count = div(n, 2)

    extra_edges =
      0..(extra_count - 1)
      |> Enum.flat_map(fn i ->
        a = Enum.at(player_ids, i)
        b = Enum.at(player_ids, rem(i + 2, n))
        if a != b, do: [{a, b}], else: []
      end)

    all_edges = ring_edges ++ extra_edges

    # Build adjacency map (undirected)
    base = Enum.into(player_ids, %{}, &{&1, []})

    Enum.reduce(all_edges, base, fn {a, b}, acc ->
      acc
      |> Map.update(a, [b], fn neighbors ->
        if b in neighbors, do: neighbors, else: neighbors ++ [b]
      end)
      |> Map.update(b, [a], fn neighbors ->
        if a in neighbors, do: neighbors, else: neighbors ++ [a]
      end)
    end)
  end

  @doc """
  Returns the adjacency view for a specific player — only their direct neighbors.
  """
  @spec local_view(map(), String.t()) :: [String.t()]
  def local_view(adjacency, player_id) do
    Map.get(adjacency, player_id, [])
  end

  @doc """
  Checks if two players are adjacent.
  """
  @spec adjacent?(map(), String.t(), String.t()) :: boolean()
  def adjacent?(adjacency, a, b) do
    b in Map.get(adjacency, a, [])
  end

  @doc """
  Distributes intel fragments across players. Each player gets one fragment.
  Returns a map of player_id => fragment_id.
  """
  @spec distribute_intel([String.t()]) :: %{String.t() => String.t()}
  def distribute_intel(player_ids) do
    fragments = Enum.take(@intel_fragments, length(player_ids))

    player_ids
    |> Enum.zip(fragments)
    |> Enum.into(%{})
  end

  @doc """
  Returns all intel fragment IDs.
  """
  @spec all_fragments() :: [String.t()]
  def all_fragments, do: @intel_fragments

  @doc """
  Selects the mole — always player at index 0 to keep it deterministic per run
  (real randomness comes from agent decisions). In practice the entry module
  picks a random player using Enum.random.
  """
  @spec select_mole([String.t()]) :: String.t()
  def select_mole(player_ids) do
    Enum.random(player_ids)
  end
end
