defmodule LemonSim.Examples.SpaceStation.Updaters.Support do
  @moduledoc false

  import LemonSim.Examples.Helpers
  import LemonSim.Examples.Helpers.UpdaterHelpers

  alias LemonSim.Kernel.State

  @max_health 100

  # -- Journal helpers --

  def add_journal_entry(state, player_id, text) do
    journals = get(state.world, :journals, %{})
    player_journal = Map.get(journals, player_id, [])

    entry = %{
      round: get(state.world, :round, 1),
      phase: get(state.world, :phase),
      text: text
    }

    new_journals = Map.put(journals, player_id, player_journal ++ [entry])
    State.put_world(state, world_updates(state.world, %{journals: new_journals}))
  end

  # -- Reputation helpers --

  def adjust_reputation(state, player_id, delta) do
    players = get(state.world, :players, %{})

    case Map.get(players, player_id) do
      nil ->
        state

      player ->
        current = get(player, :reputation, 0)
        new_rep = max(-100, min(100, current + delta))
        updated_players = Map.put(players, player_id, Map.put(player, :reputation, new_rep))
        State.put_world(state, world_updates(state.world, %{players: updated_players}))
    end
  end

  # -- System helpers --

  def apply_system_change(systems, system_id, delta) do
    sys_key = normalize_system_key(systems, system_id)

    case Map.get(systems, sys_key) do
      nil ->
        systems

      sys ->
        health = get(sys, :health, 100)
        new_health = min(@max_health, max(0, health + delta))
        Map.put(systems, sys_key, Map.put(sys, :health, new_health))
    end
  end

  def normalize_system_key(systems, system_id) do
    cond do
      Map.has_key?(systems, system_id) ->
        system_id

      is_binary(system_id) and Map.has_key?(systems, String.to_existing_atom(system_id)) ->
        String.to_existing_atom(system_id)

      true ->
        system_id
    end
  rescue
    ArgumentError -> system_id
  end

  def get_action_field(action_entry, key) when is_map(action_entry) do
    Map.get(action_entry, key, Map.get(action_entry, Atom.to_string(key)))
  end

  def get_action_field(_, _), do: nil

  def system_display_name(nil), do: "unknown"
  def system_display_name("o2"), do: "Oxygen"
  def system_display_name("power"), do: "Reactor Power"
  def system_display_name("hull"), do: "Hull Integrity"
  def system_display_name("comms"), do: "Communications"
  def system_display_name("nav"), do: "Navigation"
  def system_display_name("medbay"), do: "Medical Bay"
  def system_display_name("shields"), do: "Shield Array"
  def system_display_name(other), do: other
end
