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
    if length(living_players(players)) >= 5, do: 3, else: 2
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

  # -- Personality Traits (space crew themed) --

  @traits ~w(methodical hotheaded empathetic calculating suspicious by_the_book improviser stoic)

  @trait_descriptions %{
    "methodical" => "You are METHODICAL — you follow procedures exactly, document everything, and trust data over gut feelings. Chaos makes you uncomfortable.",
    "hotheaded" => "You are HOTHEADED — you react fast, speak before thinking, and push for immediate action. Patience is not your strength.",
    "empathetic" => "You are EMPATHETIC — you read people well, notice emotional shifts, and try to keep the crew together. You hate conflict.",
    "calculating" => "You are CALCULATING — you think in probabilities, weigh every option, and rarely reveal your full reasoning to others.",
    "suspicious" => "You are SUSPICIOUS — you question everyone's motives, look for inconsistencies, and trust no one completely.",
    "by_the_book" => "You are BY-THE-BOOK — you follow chain of command, respect authority, and believe rules exist for a reason.",
    "improviser" => "You are an IMPROVISER — you think on your feet, bend rules when needed, and trust your instincts over protocol.",
    "stoic" => "You are STOIC — you stay calm under pressure, speak only when necessary, and never show fear. Others find you hard to read."
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

  # -- Backstory Connections (space crew themed) --

  @connection_types ~w(academy_classmates former_crew mission_rivals mentor_protege bunkmates incident_survivors)

  @connection_templates %{
    "academy_classmates" => " graduated from the same Space Academy class. They competed for top marks and know each other's strengths.",
    "former_crew" => " served together on a previous deep-space mission. They've seen each other at their worst.",
    "mission_rivals" => " both applied for the same mission commander position. Only one was chosen.",
    "mentor_protege" => ": the first mentored the second through their early career. The dynamic hasn't fully evolved.",
    "bunkmates" => " share quarters on the station. They know each other's habits, routines, and tells.",
    "incident_survivors" => " survived a station breach together on a previous posting. That kind of bond doesn't break easily."
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
