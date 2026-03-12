defmodule LemonSim.GameHelpers.UpdaterHelpers do
  @moduledoc """
  Shared validation and utility functions for game updaters.

  Provides common guards (ensure_*), turn advancement, world key
  normalization, and action rejection helpers.
  """

  import LemonSim.GameHelpers

  alias LemonSim.{Event, State}

  # -- Validation guards --

  def ensure_in_progress(world) do
    if get(world, :status) == "in_progress", do: :ok, else: {:error, :game_over}
  end

  def ensure_phase(world, expected_phase) do
    if get(world, :phase) == expected_phase, do: :ok, else: {:error, :wrong_phase}
  end

  def ensure_active_actor(world, player_id) do
    if get(world, :active_actor_id) == player_id,
      do: :ok,
      else: {:error, :not_active_actor}
  end

  def ensure_living(players, player_id) do
    case Map.get(players, player_id) do
      nil ->
        {:error, :unknown_player}

      player ->
        if get(player, :status) == "alive", do: :ok, else: {:error, :player_dead}
    end
  end

  def ensure_role(players, player_id, expected_role) do
    case Map.get(players, player_id) do
      nil ->
        {:error, :unknown_player}

      player ->
        if get(player, :role) == expected_role, do: :ok, else: {:error, :wrong_role}
    end
  end

  def ensure_not_role(players, player_id, forbidden_role) do
    case Map.get(players, player_id) do
      nil ->
        {:error, :unknown_player}

      player ->
        if get(player, :role) != forbidden_role, do: :ok, else: {:error, :invalid_target}
    end
  end

  def ensure_different(id_a, id_b) do
    if id_a != id_b, do: :ok, else: {:error, :cannot_target_self}
  end

  def ensure_valid_vote_target(_players, _voter_id, "skip"), do: :ok

  def ensure_valid_vote_target(players, voter_id, target_id) do
    with :ok <- ensure_living(players, target_id),
         :ok <- ensure_different(voter_id, target_id) do
      :ok
    end
  end

  # -- Turn advancement --

  @doc """
  Returns the next player in the turn order after `current_id`, or nil if
  `current_id` is the last in the order.
  """
  def next_in_order(turn_order, current_id) do
    case Enum.find_index(turn_order, &(&1 == current_id)) do
      nil ->
        nil

      idx ->
        next_idx = idx + 1

        if next_idx < length(turn_order) do
          Enum.at(turn_order, next_idx)
        else
          nil
        end
    end
  end

  # -- World state helpers --

  @doc """
  Normalizes update keys to match the existing world state's key type
  (atom vs string).
  """
  def world_updates(world, updates) do
    Enum.into(updates, %{}, fn {key, value} ->
      normalized_key =
        cond do
          Map.has_key?(world, key) -> key
          Map.has_key?(world, Atom.to_string(key)) -> Atom.to_string(key)
          true -> key
        end

      {normalized_key, value}
    end)
  end

  # -- Action rejection --

  @doc """
  Rejects an invalid action, appending the original event and an
  action_rejected event, then signalling the decider to retry.
  """
  def reject_action(%State{} = state, event, player_id, reason) do
    message = rejection_reason(reason)

    rejected =
      Event.new("action_rejected", %{
        "kind" => to_string(event.kind),
        "player_id" => to_string(player_id || "unknown"),
        "reason" => message
      })

    next_state =
      state
      |> State.append_event(event)
      |> State.append_event(rejected)

    {:ok, next_state, {:decide, message}}
  end

  def rejection_reason(:game_over), do: "game already over"
  def rejection_reason(:wrong_phase), do: "wrong phase"
  def rejection_reason(:not_active_actor), do: "not the active actor"
  def rejection_reason(:unknown_player), do: "unknown player"
  def rejection_reason(:player_dead), do: "player is dead"
  def rejection_reason(:wrong_role), do: "wrong role for this action"
  def rejection_reason(:invalid_target), do: "invalid target"
  def rejection_reason(:cannot_target_self), do: "cannot target yourself"
  def rejection_reason(:system_locked), do: "system is locked by the captain"
  def rejection_reason(:insufficient_funds), do: "insufficient funds"
  def rejection_reason(:insufficient_shares), do: "insufficient shares"
  def rejection_reason(:invalid_quantity), do: "invalid quantity"
  def rejection_reason(:no_idol), do: "you don't have an idol"
  def rejection_reason(:emergency_used), do: "emergency meeting already used"
  def rejection_reason(other), do: "rejected: #{inspect(other)}"
end
