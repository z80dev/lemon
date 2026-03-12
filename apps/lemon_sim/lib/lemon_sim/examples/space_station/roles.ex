defmodule LemonSim.Examples.SpaceStation.Roles do
  @moduledoc """
  Role definitions and assignment logic for Space Station Crisis.
  """

  import LemonSim.GameHelpers

  @roles_by_count %{
    5 => [:engineer, :captain, :saboteur, :crew, :crew],
    6 => [:engineer, :captain, :saboteur, :crew, :crew, :crew],
    7 => [:engineer, :captain, :saboteur, :crew, :crew, :crew, :crew]
  }
  @player_names [
    "Alice",
    "Bram",
    "Cora",
    "Dane",
    "Esme",
    "Felix",
    "Gia",
    "Hugo",
    "Iris",
    "Jude",
    "Kira",
    "Lena",
    "Milo",
    "Nora",
    "Owen",
    "Pia"
  ]

  @doc """
  Returns a shuffled role list for the given player count.
  """
  @spec role_list(pos_integer()) :: [atom()]
  def role_list(player_count) when player_count >= 5 and player_count <= 7 do
    @roles_by_count
    |> Map.fetch!(player_count)
    |> Enum.shuffle()
  end

  @doc """
  Assigns roles to player IDs, returning a players map.
  """
  @spec assign_roles([String.t()]) :: %{String.t() => map()}
  def assign_roles(player_ids) do
    roles = role_list(length(player_ids))
    names = player_names(length(player_ids))

    player_ids
    |> Enum.zip(roles)
    |> Enum.zip(names)
    |> Enum.into(%{}, fn {{player_id, role}, name} ->
      {player_id,
       %{
         role: Atom.to_string(role),
         status: "alive",
         name: name,
         location: nil,
         last_action: nil
       }}
    end)
  end

  @doc """
  Returns the action turn order: all living players sorted by ID and rotated by round.
  """
  @spec action_turn_order(%{String.t() => map()}, pos_integer()) :: [String.t()]
  def action_turn_order(players, round_number \\ 1) do
    players
    |> living_players()
    |> extract_ids()
    |> Enum.sort()
    |> rotate(max(0, round_number - 1))
  end

  @doc """
  Returns the rotated discussion order for the given round and discussion pass.
  """
  @spec discussion_turn_order(%{String.t() => map()}, pos_integer(), pos_integer()) :: [
          String.t()
        ]
  def discussion_turn_order(players, round_number, discussion_round) do
    action_turn_order(players, round_number + discussion_round - 1)
  end

  @doc """
  Returns the rotated voting order for the given round.
  """
  @spec voting_turn_order(%{String.t() => map()}, pos_integer()) :: [String.t()]
  def voting_turn_order(players, round_number) do
    action_turn_order(players, max(1, round_number + 1))
  end

  @doc """
  Returns how many discussion rounds to run before voting.
  """
  @spec discussion_round_limit(%{String.t() => map()}) :: pos_integer()
  def discussion_round_limit(players) do
    if length(living_players(players)) >= 5, do: 2, else: 1
  end

  @doc """
  Returns all living player entries.
  """
  @spec living_players(%{String.t() => map()}) :: [{String.t(), map()}]
  def living_players(players) do
    Enum.filter(players, fn {_id, p} -> get(p, :status) == "alive" end)
  end

  @doc """
  Returns living player IDs with the given role.
  """
  @spec living_with_role(%{String.t() => map()}, String.t()) :: [String.t()]
  def living_with_role(players, role) do
    players
    |> living_players()
    |> Enum.filter(fn {_id, p} -> get(p, :role) == role end)
    |> extract_ids()
  end

  @doc """
  Checks if the saboteur has been ejected (crew wins faster condition).
  """
  @spec saboteur_ejected?(%{String.t() => map()}) :: boolean()
  def saboteur_ejected?(players) do
    living_with_role(players, "saboteur") == []
  end

  @doc """
  Returns the saboteur's player ID (living or dead).
  """
  @spec find_saboteur(%{String.t() => map()}) :: String.t() | nil
  def find_saboteur(players) do
    players
    |> Enum.find(fn {_id, p} -> get(p, :role) == "saboteur" end)
    |> case do
      {id, _p} -> id
      nil -> nil
    end
  end

  defp extract_ids(pairs), do: Enum.map(pairs, fn {id, _p} -> id end)

  defp rotate([], _offset), do: []

  defp rotate(list, offset) do
    normalized = rem(offset, length(list))
    {head, tail} = Enum.split(list, normalized)
    tail ++ head
  end

  defp player_names(count) do
    @player_names
    |> Enum.shuffle()
    |> Enum.take(count)
  end
end
