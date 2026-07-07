defmodule LemonSim.Examples.DungeonCrawl.Updaters.Support do
  @moduledoc false

  import LemonSim.Examples.Helpers

  alias LemonCore.MapHelpers
  alias LemonSim.Kernel.State
  alias LemonSim.Examples.DungeonCrawl.Events

  def append_action(%State{} = state, event, next_world, action_events) do
    state
    |> State.append_event(event)
    |> State.update_world(fn _ -> next_world end)
    |> State.append_events(Enum.reject(action_events, &is_nil/1))
  end

  def reject_action(%State{} = state, event, actor_id, reason) do
    message = rejection_reason(reason)

    next_state =
      state
      |> State.append_event(event)
      |> State.append_event(
        Events.action_rejected(to_string(event.kind), to_string(actor_id || "unknown"), message)
      )

    {:ok, next_state, {:decide, message}}
  end

  def ensure_in_progress(world) do
    if MapHelpers.get_key(world, :status) == "in_progress", do: :ok, else: {:error, :game_over}
  end

  def ensure_active_actor(world, actor_id) do
    if MapHelpers.get_key(world, :active_actor_id) == actor_id,
      do: :ok,
      else: {:error, :not_active_actor}
  end

  def fetch_living_adventurer(world, actor_id) when is_binary(actor_id) do
    party = get(world, :party, %{})

    case Map.get(party, actor_id) do
      nil ->
        {:error, :unknown_adventurer}

      adventurer ->
        if get(adventurer, :hp, 0) <= 0 do
          {:error, :adventurer_dead}
        else
          {:ok, adventurer}
        end
    end
  end

  def fetch_living_adventurer(_world, _actor_id), do: {:error, :invalid_actor}

  def ensure_ap(actor, cost) do
    if get(actor, :ap, 0) >= cost, do: :ok, else: {:error, :insufficient_ap}
  end

  def put_adventurer(world, actor_id, adventurer) do
    party = get(world, :party, %{})
    Map.put(world, :party, Map.put(party, actor_id, adventurer))
  end

  def put_enemy(world, enemy_id, enemy) do
    enemies = get(world, :enemies, %{})
    Map.put(world, :enemies, Map.put(enemies, enemy_id, enemy))
  end

  defp rejection_reason(:game_over), do: "game already over"
  defp rejection_reason(:not_active_actor), do: "not the active actor"
  defp rejection_reason(:unknown_adventurer), do: "unknown adventurer"
  defp rejection_reason(:invalid_actor), do: "invalid actor"
  defp rejection_reason(:adventurer_dead), do: "adventurer is dead"
  defp rejection_reason(:unknown_enemy), do: "unknown enemy"
  defp rejection_reason(:invalid_enemy), do: "invalid enemy"
  defp rejection_reason(:enemy_dead), do: "enemy is already dead"
  defp rejection_reason(:insufficient_ap), do: "insufficient AP"
  defp rejection_reason(:wrong_class), do: "wrong class for this ability"
  defp rejection_reason(:target_dead), do: "target is dead"
  defp rejection_reason(:target_full_hp), do: "target is at full health"
  defp rejection_reason(:item_not_found), do: "item not found in inventory"
  defp rejection_reason(:unknown_ability), do: "unknown ability"
  defp rejection_reason(:no_active_traps), do: "no active traps to disarm"
  defp rejection_reason(other), do: "rejected: #{inspect(other)}"
end
