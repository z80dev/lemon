defmodule LemonSim.Examples.Diplomacy.MapGraph do
  @moduledoc """
  Territory map definition for the Diplomacy-lite game.

  Defines a graph of 12 territories with adjacency relationships and
  starting positions for 4-6 players.
  """

  @doc """
  Returns the full territory adjacency graph.

  The map has 12 territories:
  - 6 home territories (one per possible player)
  - 6 contested/neutral territories

  Layout (conceptual):

      northland --- highland --- eastmarch
         |     \\       |       /     |
      westwood --- central --- eastwood
         |     /       |       \\     |
      southmoor --- lowland --- southeast
         |             |             |
      farwest --- badlands --- fareast
  """
  @spec adjacency() :: %{String.t() => [String.t()]}
  def adjacency do
    %{
      "northland" => ["highland", "westwood", "central"],
      "highland" => ["northland", "eastmarch", "central"],
      "eastmarch" => ["highland", "eastwood", "central"],
      "westwood" => ["northland", "central", "southmoor"],
      "central" => ["northland", "highland", "eastmarch", "westwood", "eastwood", "southmoor", "lowland", "southeast"],
      "eastwood" => ["eastmarch", "central", "southeast"],
      "southmoor" => ["westwood", "central", "lowland", "farwest"],
      "lowland" => ["central", "southmoor", "southeast", "badlands"],
      "southeast" => ["central", "eastwood", "lowland", "fareast"],
      "farwest" => ["southmoor", "badlands"],
      "badlands" => ["farwest", "lowland", "fareast"],
      "fareast" => ["southeast", "badlands"]
    }
  end

  @doc """
  Returns starting positions for the given number of players (4-6).

  Each player starts with 1 territory and 2 armies on it.
  """
  @spec starting_positions(pos_integer()) :: %{String.t() => String.t()}
  def starting_positions(4) do
    %{
      "player_1" => "northland",
      "player_2" => "eastmarch",
      "player_3" => "southmoor",
      "player_4" => "fareast"
    }
  end

  def starting_positions(5) do
    %{
      "player_1" => "northland",
      "player_2" => "eastmarch",
      "player_3" => "southmoor",
      "player_4" => "fareast",
      "player_5" => "farwest"
    }
  end

  def starting_positions(6) do
    %{
      "player_1" => "northland",
      "player_2" => "eastmarch",
      "player_3" => "southmoor",
      "player_4" => "fareast",
      "player_5" => "farwest",
      "player_6" => "eastwood"
    }
  end

  @doc """
  Returns faction names for players.
  """
  @spec factions() :: %{String.t() => String.t()}
  def factions do
    %{
      "player_1" => "Northguard",
      "player_2" => "Eastern Realm",
      "player_3" => "Southmoor Clans",
      "player_4" => "Far Eastern Empire",
      "player_5" => "Western Alliance",
      "player_6" => "Eastwood Confederacy"
    }
  end

  @doc """
  Returns all territory names.
  """
  @spec territory_names() :: [String.t()]
  def territory_names do
    Map.keys(adjacency())
  end

  @doc """
  Returns true if two territories are adjacent.
  """
  @spec adjacent?(String.t(), String.t()) :: boolean()
  def adjacent?(from, to) do
    neighbors = Map.get(adjacency(), from, [])
    to in neighbors
  end
end
