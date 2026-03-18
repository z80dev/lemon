defmodule LemonSim.Examples.MurderMystery.CaseGenerator do
  @moduledoc """
  Generates randomised murder mystery cases: rooms, suspects, clues, and a
  hidden solution.
  """

  @rooms [
    %{id: "library", name: "Library"},
    %{id: "ballroom", name: "Ballroom"},
    %{id: "conservatory", name: "Conservatory"},
    %{id: "study", name: "Study"},
    %{id: "kitchen", name: "Kitchen"},
    %{id: "cellar", name: "Cellar"}
  ]

  @weapons ["candlestick", "knife", "lead_pipe", "revolver", "rope", "wrench"]

  @clue_types ["fingerprint", "footprint", "weapon_trace", "bloodstain", "thread", "hair_sample"]

  @guest_names [
    "Lady Ashford",
    "Colonel Whitmore",
    "Professor Blackwell",
    "Mrs Harrington",
    "Dr Pemberton",
    "Countess Volkov"
  ]

  @alibis [
    "was admiring the portrait gallery",
    "was reading by the fireplace",
    "was tending to the roses",
    "was playing cards in the smoking room",
    "was having a nightcap at the bar",
    "was sketching architectural details"
  ]

  @doc """
  Generates a full case for a game with `player_count` players.

  Returns a map with:
    - `rooms`   - map of room_id => room data
    - `evidence` - map of clue_id => clue data
    - `solution` - %{killer_id, weapon, room_id}
    - `crime_solution` - same as solution (canonical key used for domain detection)
    - `players`  - map of player_id => player data (roles assigned)
    - `turn_order` - list of player_ids
  """
  @spec generate(pos_integer()) :: map()
  def generate(player_count) do
    player_count = max(3, min(6, player_count))
    player_ids = Enum.map(1..player_count, &"player_#{&1}")

    # Pick killer randomly
    killer_id = Enum.random(player_ids)
    weapon = Enum.random(@weapons)

    # Crime room is one of the 6 mansion rooms
    crime_room_id = Enum.random(@rooms) |> Map.fetch!(:id)

    solution = %{
      killer_id: killer_id,
      weapon: weapon,
      room_id: crime_room_id
    }

    # Build rooms map
    rooms = build_rooms()

    # Assign names, roles, alibis to players
    shuffled_names = Enum.shuffle(@guest_names) |> Enum.take(player_count)
    shuffled_alibis = Enum.shuffle(@alibis) |> Enum.take(player_count)

    players =
      player_ids
      |> Enum.with_index()
      |> Enum.into(%{}, fn {pid, idx} ->
        role = if pid == killer_id, do: "killer", else: "investigator"

        {pid,
         %{
           name: Enum.at(shuffled_names, idx, "Guest #{idx + 1}"),
           role: role,
           alibi: Enum.at(shuffled_alibis, idx, "was wandering the halls"),
           clues_found: [],
           accusations_remaining: 1,
           status: "alive"
         }}
      end)

    # Scatter clues across rooms; include at least one clue pointing to killer
    {rooms_with_clues, evidence} = scatter_clues(rooms, player_ids, killer_id, crime_room_id)

    %{
      rooms: rooms_with_clues,
      evidence: evidence,
      solution: solution,
      crime_solution: solution,
      players: players,
      turn_order: player_ids
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_rooms do
    Enum.into(@rooms, %{}, fn %{id: id, name: name} ->
      {id, %{name: name, clues_present: [], searched_by: []}}
    end)
  end

  defp scatter_clues(rooms, player_ids, killer_id, crime_room_id) do
    # Always place one real clue pointing to the killer in the crime room
    main_clue_id = "clue_#{crime_room_id}_killer"

    main_clue = %{
      clue_id: main_clue_id,
      clue_type: Enum.random(@clue_types),
      room_id: crime_room_id,
      points_to: killer_id,
      is_false: false
    }

    # Scatter 2-4 additional red-herring / supporting clues
    extra_count = Enum.random(2..4)

    {extra_clues, _} =
      Enum.map_reduce(1..extra_count, 1, fn _i, acc ->
        room_id = Enum.random(@rooms) |> Map.fetch!(:id)
        clue_id = "clue_#{acc}_#{room_id}"
        points_to = Enum.random(player_ids)

        clue = %{
          clue_id: clue_id,
          clue_type: Enum.random(@clue_types),
          room_id: room_id,
          points_to: points_to,
          is_false: false
        }

        {clue, acc + 1}
      end)

    all_clues = [main_clue | extra_clues]

    # Build evidence map
    evidence =
      Enum.into(all_clues, %{}, fn clue ->
        {clue.clue_id, clue}
      end)

    # Place clues into their rooms
    updated_rooms =
      Enum.reduce(all_clues, rooms, fn clue, acc_rooms ->
        Map.update(acc_rooms, clue.room_id, %{clues_present: [clue.clue_id], searched_by: []}, fn room ->
          Map.update(room, :clues_present, [clue.clue_id], &(&1 ++ [clue.clue_id]))
        end)
      end)

    {updated_rooms, evidence}
  end
end
