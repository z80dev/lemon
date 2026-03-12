defmodule LemonSim.Examples.Werewolf.Roles do
  @moduledoc """
  Role definitions and assignment logic for Werewolf.
  """

  import LemonSim.GameHelpers

  @roles_by_count %{
    5 => [:werewolf, :seer, :doctor, :villager, :villager],
    6 => [:werewolf, :werewolf, :seer, :doctor, :villager, :villager],
    7 => [:werewolf, :werewolf, :seer, :doctor, :villager, :villager, :villager],
    8 => [:werewolf, :werewolf, :seer, :doctor, :villager, :villager, :villager, :villager]
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
  def role_list(player_count) when player_count >= 5 and player_count <= 8 do
    @roles_by_count
    |> Map.fetch!(player_count)
    |> Enum.shuffle()
  end

  @doc """
  Assigns roles to players, using names as canonical keys.
  """
  @spec assign_roles(pos_integer()) :: %{String.t() => map()}
  def assign_roles(player_count) do
    roles = role_list(player_count)
    names = player_names(player_count)

    names
    |> Enum.zip(roles)
    |> Enum.into(%{}, fn {name, role} ->
      {name,
       %{
         role: Atom.to_string(role),
         status: "alive"
       }}
    end)
  end

  @doc """
  Returns the night turn order based on roles.
  Werewolves act first, then seer, then doctor. Villagers sleep (no-op).
  """
  @spec night_turn_order(%{String.t() => map()}) :: [String.t()]
  def night_turn_order(players) do
    living = living_players(players)

    werewolves = Enum.filter(living, fn {_id, p} -> get(p, :role) == "werewolf" end)
    seers = Enum.filter(living, fn {_id, p} -> get(p, :role) == "seer" end)
    doctors = Enum.filter(living, fn {_id, p} -> get(p, :role) == "doctor" end)
    villagers = Enum.filter(living, fn {_id, p} -> get(p, :role) == "villager" end)

    extract_ids(werewolves) ++
      extract_ids(seers) ++ extract_ids(doctors) ++ extract_ids(villagers)
  end

  @doc """
  Returns the day turn order (all living players, rotated by the given offset).
  """
  @spec day_turn_order(%{String.t() => map()}, non_neg_integer()) :: [String.t()]
  def day_turn_order(players, offset \\ 0) do
    players
    |> living_players()
    |> extract_ids()
    |> Enum.sort()
    |> rotate(offset)
  end

  @doc """
  Returns the rotated discussion order for the given day and discussion round.
  This reduces fixed seat-order bias while keeping turn order deterministic.
  """
  @spec discussion_turn_order(%{String.t() => map()}, pos_integer(), pos_integer()) :: [
          String.t()
        ]
  def discussion_turn_order(players, day_number, round_number) do
    offset = max(0, day_number + round_number - 2)
    day_turn_order(players, offset)
  end

  @doc """
  Returns the rotated voting order for the given day.
  """
  @spec voting_turn_order(%{String.t() => map()}, pos_integer()) :: [String.t()]
  def voting_turn_order(players, day_number) do
    day_turn_order(players, max(0, day_number - 1))
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
  Returns the werewolf partner(s) for a given werewolf player.
  """
  @spec werewolf_partners(%{String.t() => map()}, String.t()) :: [String.t()]
  def werewolf_partners(players, player_id) do
    players
    |> Enum.filter(fn {id, p} ->
      id != player_id and get(p, :role) == "werewolf"
    end)
    |> extract_ids()
  end

  @doc """
  Checks if werewolves equal or outnumber non-werewolves among living players.
  """
  @spec werewolves_win?(%{String.t() => map()}) :: boolean()
  def werewolves_win?(players) do
    living = living_players(players)
    wolves = Enum.count(living, fn {_id, p} -> get(p, :role) == "werewolf" end)
    villagers = Enum.count(living, fn {_id, p} -> get(p, :role) != "werewolf" end)
    wolves >= villagers
  end

  @doc """
  Checks if all werewolves are eliminated.
  """
  @spec villagers_win?(%{String.t() => map()}) :: boolean()
  def villagers_win?(players) do
    living = living_players(players)
    wolves = Enum.count(living, fn {_id, p} -> get(p, :role) == "werewolf" end)
    wolves == 0
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
