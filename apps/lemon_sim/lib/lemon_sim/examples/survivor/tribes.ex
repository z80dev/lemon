defmodule LemonSim.Examples.Survivor.Tribes do
  @moduledoc """
  Player and tribe management for Survivor.
  Handles initial tribe assignment, merge logic, turn ordering,
  character names, personality traits, and backstory connections.
  """

  import LemonSim.GameHelpers

  @tribe_names ["Tala", "Manu"]
  @merge_tribe_name "Solana"
  @merge_threshold 6

  @player_names [
    "Kai", "Sierra", "Marcus", "Jade", "Rex", "Luna", "Dex", "Paloma",
    "Blaze", "Isla", "Thorn", "Willow", "Nash", "Sable", "Zane", "Ember"
  ]

  # -- Personality Traits --

  @traits ~w(strategic ruthless loyal charismatic paranoid athletic cunning underdog)

  @trait_descriptions %{
    "strategic" => "You are STRATEGIC — you think three steps ahead, plan blindsides, and always have a target list ranked by threat level.",
    "ruthless" => "You are RUTHLESS — you will cut any ally loose when they stop being useful. Winning is everything, and sentimentality is weakness.",
    "loyal" => "You are LOYAL — you ride or die with your alliance. Betraying an ally is the worst sin, and you remember every backstab.",
    "charismatic" => "You are CHARISMATIC — you can talk anyone into anything. You defuse conflicts, build bridges, and make everyone feel heard.",
    "paranoid" => "You are PARANOID — you read too much into every whisper, every glance. If someone talked to your rival, they're plotting against you.",
    "athletic" => "You are ATHLETIC — you live for challenges and respect physical prowess. You judge people by their performance under pressure.",
    "cunning" => "You are CUNNING — you plant seeds of doubt, spread controlled misinformation, and let others do your dirty work.",
    "underdog" => "You are an UNDERDOG — you fly under the radar, let bigger threats absorb attention, and strike when no one expects it."
  }

  # -- Backstory Connections --

  @connection_types ~w(exes college_roommates work_rivals hometown secret_alliance bitter_enemies)

  @connection_templates %{
    "exes" => " dated briefly before the show. There's unresolved tension and neither has told the others.",
    "college_roommates" => " were college roommates and still know each other's tells and habits.",
    "work_rivals" => " worked at the same company and competed for the same promotion. Old wounds die hard.",
    "hometown" => " grew up in the same small town. They share memories no one else would understand.",
    "secret_alliance" => " made a pact before the game started to watch each other's backs no matter what.",
    "bitter_enemies" => " had a falling out years ago over a mutual friend. Neither has forgiven the other."
  }

  @doc """
  Returns N shuffled player names from the name pool.
  """
  @spec player_names(pos_integer()) :: [String.t()]
  def player_names(count) do
    @player_names
    |> Enum.shuffle()
    |> Enum.take(count)
  end

  @doc """
  Assigns personality traits (1-2) to each player.
  Returns a map of player_name => [trait1, trait2].
  """
  @spec assign_traits([String.t()]) :: %{String.t() => [String.t()]}
  def assign_traits(player_names) do
    Enum.into(player_names, %{}, fn name ->
      count = Enum.random(1..2)
      player_traits = @traits |> Enum.shuffle() |> Enum.take(count)
      {name, player_traits}
    end)
  end

  @doc """
  Returns the description for a given trait.
  """
  @spec trait_description(String.t()) :: String.t()
  def trait_description(trait), do: Map.get(@trait_descriptions, trait, "")

  @doc """
  Generates backstory connections between random pairs of players.
  Returns a list of connection maps with :players, :type, and :description keys.
  """
  @spec generate_connections([String.t()]) :: [map()]
  def generate_connections(player_names) when length(player_names) < 4, do: []

  def generate_connections(player_names) do
    num_connections = min(3, div(length(player_names), 2))

    player_names
    |> Enum.shuffle()
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.take(num_connections)
    |> Enum.map(fn [a, b] ->
      type = Enum.random(@connection_types)
      template = Map.get(@connection_templates, type, " have a connection.")

      %{
        players: [a, b],
        type: type,
        description: "#{a} and #{b}" <> template
      }
    end)
  end

  @doc """
  Filters connections to only those involving the given player.
  """
  @spec connections_for_player([map()], String.t()) :: [map()]
  def connections_for_player(connections, player_id) do
    Enum.filter(connections, fn conn ->
      players = Map.get(conn, :players, [])
      player_id in players
    end)
  end

  @doc """
  Assigns players into two tribes and gives one player a hidden immunity idol.
  Returns {players_map, tribes_map}.
  """
  @spec assign_tribes([String.t()]) :: {%{String.t() => map()}, %{String.t() => [String.t()]}}
  def assign_tribes(player_ids) do
    shuffled = Enum.shuffle(player_ids)
    mid = div(length(shuffled), 2)
    {tribe_a_ids, tribe_b_ids} = Enum.split(shuffled, mid)

    [name_a, name_b] = @tribe_names

    # One random player gets the idol
    idol_holder = Enum.random(player_ids)

    players =
      Enum.into(player_ids, %{}, fn id ->
        tribe =
          if id in tribe_a_ids, do: name_a, else: name_b

        {id,
         %{
           status: "alive",
           tribe: tribe,
           has_idol: id == idol_holder,
           jury_member: false
         }}
      end)

    tribes = %{
      name_a => Enum.sort(tribe_a_ids),
      name_b => Enum.sort(tribe_b_ids)
    }

    {players, tribes}
  end

  @doc """
  Returns the default merge tribe name.
  """
  @spec merge_tribe_name() :: String.t()
  def merge_tribe_name, do: @merge_tribe_name

  @doc """
  Returns the merge threshold (merge when total alive players <= this).
  """
  @spec merge_threshold() :: non_neg_integer()
  def merge_threshold, do: @merge_threshold

  @doc """
  Returns all living player entries.
  """
  @spec living_players(%{String.t() => map()}) :: [{String.t(), map()}]
  def living_players(players) do
    Enum.filter(players, fn {_id, p} -> get(p, :status) == "alive" end)
  end

  @doc """
  Returns living player IDs.
  """
  @spec living_player_ids(%{String.t() => map()}) :: [String.t()]
  def living_player_ids(players) do
    players
    |> living_players()
    |> extract_ids()
    |> Enum.sort()
  end

  @doc """
  Returns living player IDs for a specific tribe.
  """
  @spec living_tribe_members(%{String.t() => map()}, String.t()) :: [String.t()]
  def living_tribe_members(players, tribe_name) do
    players
    |> living_players()
    |> Enum.filter(fn {_id, p} -> get(p, :tribe) == tribe_name end)
    |> extract_ids()
    |> Enum.sort()
  end

  @doc """
  Returns the number of living players.
  """
  @spec living_count(%{String.t() => map()}) :: non_neg_integer()
  def living_count(players) do
    length(living_players(players))
  end

  @doc """
  Returns true if the game should merge tribes.
  """
  @spec should_merge?(%{String.t() => map()}, boolean()) :: boolean()
  def should_merge?(players, already_merged) do
    not already_merged and living_count(players) <= @merge_threshold
  end

  @doc """
  Merges all living players into a single tribe.
  Returns {updated_players, updated_tribes}.
  """
  @spec merge_tribes(%{String.t() => map()}) :: {%{String.t() => map()}, %{String.t() => [String.t()]}}
  def merge_tribes(players) do
    merged_players =
      Enum.into(players, %{}, fn {id, p} ->
        if get(p, :status) == "alive" do
          {id, Map.put(p, :tribe, @merge_tribe_name)}
        else
          {id, p}
        end
      end)

    merged_tribe_members = living_player_ids(merged_players)
    tribes = %{@merge_tribe_name => merged_tribe_members}

    {merged_players, tribes}
  end

  @doc """
  Turn order for challenge phase: all living players in sorted order.
  """
  @spec challenge_turn_order(%{String.t() => map()}) :: [String.t()]
  def challenge_turn_order(players) do
    living_player_ids(players)
  end

  @doc """
  Turn order for strategy phase: players from the losing tribe (or all post-merge).
  """
  @spec strategy_turn_order(%{String.t() => map()}, String.t() | nil, boolean()) :: [String.t()]
  def strategy_turn_order(players, losing_tribe, merged) do
    if merged do
      living_player_ids(players)
    else
      case losing_tribe do
        nil -> living_player_ids(players)
        tribe -> living_tribe_members(players, tribe)
      end
    end
  end

  @doc """
  Turn order for tribal council: losing tribe members (or all post-merge), each gets idol + vote.
  Returns list of {player_id, sub_phase} tuples for ordered actions.
  """
  @spec tribal_council_turn_order(%{String.t() => map()}, String.t() | nil, boolean()) :: [String.t()]
  def tribal_council_turn_order(players, losing_tribe, merged) do
    strategy_turn_order(players, losing_tribe, merged)
  end

  @doc """
  Turn order for final tribal council: jury members speak/vote first, then finalists plead.
  Returns {jury_order, finalist_order}.
  """
  @spec final_tribal_council_order(%{String.t() => map()}, [String.t()]) ::
          {[String.t()], [String.t()]}
  def final_tribal_council_order(players, jury) do
    finalists = living_player_ids(players)
    {Enum.sort(jury), Enum.sort(finalists)}
  end

  @doc """
  Returns true if there are exactly the final number of players (3) remaining.
  """
  @spec at_final_tribal?(%{String.t() => map()}) :: boolean()
  def at_final_tribal?(players) do
    living_count(players) <= 3
  end

  @doc """
  Eliminates a player and potentially adds them to the jury (if post-merge).
  Returns {updated_players, updated_jury}.
  """
  @spec eliminate_player(%{String.t() => map()}, String.t(), [String.t()], boolean()) ::
          {%{String.t() => map()}, [String.t()]}
  def eliminate_player(players, player_id, jury, merged) do
    player = Map.get(players, player_id, %{})

    updated_player =
      player
      |> Map.put(:status, "eliminated")
      |> Map.put(:jury_member, merged)

    updated_players = Map.put(players, player_id, updated_player)
    updated_jury = if merged, do: jury ++ [player_id], else: jury

    {updated_players, updated_jury}
  end

  defp extract_ids(pairs), do: Enum.map(pairs, fn {id, _p} -> id end)

end
