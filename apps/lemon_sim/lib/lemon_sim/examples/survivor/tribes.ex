defmodule LemonSim.Examples.Survivor.Tribes do
  @moduledoc """
  Player and tribe management for Survivor.
  Handles initial tribe assignment, merge logic, and turn ordering.
  """

  import LemonSim.GameHelpers

  @tribe_names ["Tala", "Manu"]
  @merge_tribe_name "Solana"
  @merge_threshold 6

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
