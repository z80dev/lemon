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
  Returns how many public discussion rounds to run before voting.

  Larger tables get an extra public round so both teams have enough time to
  react to emerging claims, pressure, and vote momentum.
  """
  @spec discussion_round_limit(%{String.t() => map()}) :: pos_integer()
  def discussion_round_limit(players) do
    if length(living_players(players)) >= 5, do: 2, else: 1
  end

  @spec discussion_round_limit(%{String.t() => map()}, pos_integer()) :: pos_integer()
  def discussion_round_limit(players, _day_number), do: discussion_round_limit(players)

  # -- Personality Traits --

  @traits ~w(bold paranoid loyal cunning superstitious merciful observant dramatic)

  @trait_descriptions %{
    "bold" =>
      "You are BOLD — you speak your mind fearlessly, make dramatic accusations, and take risks. You prefer action over caution.",
    "paranoid" =>
      "You are PARANOID — you suspect everyone, over-analyze every comment, and always assume the worst. Trust doesn't come easily.",
    "loyal" =>
      "You are LOYAL — you defend your friends fiercely and value trust above all else. You stand by allies even when risky.",
    "cunning" =>
      "You are CUNNING — you think strategically, manipulate conversations subtly, and always have a backup plan.",
    "superstitious" =>
      "You are SUPERSTITIOUS — you believe in signs and omens, notice patterns others miss, and trust your gut feelings.",
    "merciful" =>
      "You are MERCIFUL — you're reluctant to condemn anyone, give the benefit of the doubt, and advocate for patience.",
    "observant" =>
      "You are OBSERVANT — you notice small details, catch inconsistencies, and quietly build cases before speaking up.",
    "dramatic" =>
      "You are DRAMATIC — you love grand speeches, emotional confrontations, and making every moment theatrical."
  }

  @spec assign_traits([String.t()]) :: %{String.t() => [String.t()]}
  def assign_traits(player_names) do
    Enum.into(player_names, %{}, fn name ->
      count = Enum.random(1..2)
      player_traits = @traits |> Enum.shuffle() |> Enum.take(count)
      {name, player_traits}
    end)
  end

  @spec trait_description(String.t()) :: String.t()
  def trait_description(trait), do: Map.get(@trait_descriptions, trait, "")

  # -- Backstory Connections --

  @connection_types ~w(siblings rivals old_friends debt mentor_student secret_keepers)

  @connection_templates %{
    "siblings" =>
      " are siblings who grew up together in the village. They share a deep familial bond.",
    "rivals" =>
      " have been bitter rivals since a land dispute tore their families apart years ago.",
    "old_friends" =>
      " are old friends who have known each other since childhood. They trust each other deeply.",
    "debt" => ": the first owes the second a significant debt from a failed business deal.",
    "mentor_student" =>
      ": the first was once the second's mentor and teacher in the village trade.",
    "secret_keepers" => " share a dark secret from the past that neither wants revealed."
  }

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

  @spec connections_for_player([map()], String.t()) :: [map()]
  def connections_for_player(connections, player_id) do
    Enum.filter(connections, fn conn ->
      players = Map.get(conn, :players, [])
      player_id in players
    end)
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
