defmodule LemonSim.Examples.Diplomacy.MapGraph do
  @moduledoc """
  Territory map definition for the Diplomacy-lite game.

  Defines a graph of 12 territories with adjacency relationships,
  starting positions for 4-6 players, and character personality data
  for faction leaders.
  """

  # -- Character Data --

  @leader_names [
    "Alaric", "Cassius", "Drusilla", "Empress Yara", "Fenrik", "Galatea",
    "Hadrian", "Isolde", "Justinian", "Kalindra", "Leopold", "Morgause"
  ]

  @traits ~w(expansionist defensive treacherous honorable aggressive diplomatic cautious vengeful)

  @trait_descriptions %{
    "expansionist" => "You are EXPANSIONIST — you always want more territory. Peace is just preparation for the next campaign.",
    "defensive" => "You are DEFENSIVE — you protect what you have above all. You build alliances to deter aggression, not to conquer.",
    "treacherous" => "You are TREACHEROUS — alliances are tools to be discarded when they stop serving you. Every promise has an expiration date.",
    "honorable" => "You are HONORABLE — your word is your bond. You keep promises even when it costs you, and you despise oath-breakers.",
    "aggressive" => "You are AGGRESSIVE — you attack early and often. The best defense is overwhelming force.",
    "diplomatic" => "You are DIPLOMATIC — you prefer to win through negotiation. Why fight when you can convince someone to fight for you?",
    "cautious" => "You are CAUTIOUS — you never overextend. Every move is calculated, every risk assessed. Patience wins empires.",
    "vengeful" => "You are VENGEFUL — you never forget a slight. Anyone who attacks you will pay, even if it costs you the game."
  }

  @connection_types ~w(blood_feud marriage_alliance ancient_treaty border_dispute trade_partners sworn_enemies)

  @connection_templates %{
    "blood_feud" => " have waged wars against each other for generations. The hatred runs deep in both courts.",
    "marriage_alliance" => " are bound by a royal marriage. The alliance is politically convenient but personally complicated.",
    "ancient_treaty" => " signed a mutual defense pact generations ago. Whether it still holds is a matter of interpretation.",
    "border_dispute" => " share a contested border. Skirmishes are common and diplomats on both sides are exhausted.",
    "trade_partners" => " depend on each other economically. War between them would be mutually ruinous.",
    "sworn_enemies" => ": one conquered the other's ancestral homeland. The displaced ruler has sworn to reclaim it."
  }

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

  # -- Character Functions --

  @doc """
  Returns a list of leader names for the given player count.

  Names are drawn from the pool deterministically so the same count
  always yields the same set.
  """
  @spec leader_names(pos_integer()) :: [String.t()]
  def leader_names(player_count) when is_integer(player_count) and player_count > 0 do
    Enum.take(@leader_names, player_count)
  end

  @doc """
  Assigns a personality trait to each player name from the trait pool.

  Returns a map of `%{player_id => %{trait: trait_name, description: trait_description}}`.
  Traits are distributed round-robin so each player gets a distinct trait
  when the player count does not exceed the trait pool size.
  """
  @spec assign_traits([String.t()]) :: %{String.t() => %{trait: String.t(), description: String.t()}}
  def assign_traits(player_ids) when is_list(player_ids) do
    player_ids
    |> Enum.with_index()
    |> Enum.into(%{}, fn {player_id, idx} ->
      trait = Enum.at(@traits, rem(idx, length(@traits)))
      {player_id, %{trait: trait, description: Map.get(@trait_descriptions, trait, "")}}
    end)
  end

  @doc """
  Returns the description for a single trait name.
  """
  @spec trait_description(String.t()) :: String.t() | nil
  def trait_description(trait_name) do
    Map.get(@trait_descriptions, trait_name)
  end

  @doc """
  Generates a set of backstory connections between pairs of players.

  Each pair of players receives at most one connection. The connection type
  is chosen deterministically based on the pair index so results are
  reproducible for a given player list.

  Returns a list of `%{pair: {id_a, id_b}, type: type, description: desc}`.
  """
  @spec generate_connections([String.t()]) :: [map()]
  def generate_connections(player_ids) when is_list(player_ids) do
    pairs =
      for {a, i} <- Enum.with_index(player_ids),
          {b, j} <- Enum.with_index(player_ids),
          i < j,
          do: {a, b}

    pairs
    |> Enum.with_index()
    |> Enum.map(fn {{id_a, id_b}, idx} ->
      conn_type = Enum.at(@connection_types, rem(idx, length(@connection_types)))
      template = Map.get(@connection_templates, conn_type, "")

      %{
        pair: {id_a, id_b},
        type: conn_type,
        description: "#{id_a} and #{id_b}" <> template
      }
    end)
  end

  @doc """
  Returns all connections that involve a specific player.
  """
  @spec connections_for_player([map()], String.t()) :: [map()]
  def connections_for_player(connections, player_id) when is_list(connections) do
    Enum.filter(connections, fn conn ->
      {a, b} = conn.pair
      a == player_id or b == player_id
    end)
  end
end
