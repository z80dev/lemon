defmodule LemonSim.Bus do
  @moduledoc """
  PubSub helpers for simulation updates and decisions.
  """

  @spec sim_topic(String.t()) :: String.t()
  def sim_topic(sim_id) when is_binary(sim_id), do: "sim:#{sim_id}"

  @spec decisions_topic(String.t()) :: String.t()
  def decisions_topic(sim_id) when is_binary(sim_id), do: "sim:#{sim_id}:decisions"

  @spec subscribe(String.t()) :: :ok
  def subscribe(sim_id) when is_binary(sim_id) do
    LemonCore.Bus.subscribe(sim_topic(sim_id))
  end

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(sim_id) when is_binary(sim_id) do
    LemonCore.Bus.unsubscribe(sim_topic(sim_id))
  end

  @spec subscribe_decisions(String.t()) :: :ok
  def subscribe_decisions(sim_id) when is_binary(sim_id) do
    LemonCore.Bus.subscribe(decisions_topic(sim_id))
  end

  @spec broadcast_world_update(String.t(), map()) :: :ok
  def broadcast_world_update(sim_id, payload) when is_binary(sim_id) and is_map(payload) do
    event = LemonCore.Event.new(:sim_world_updated, payload, %{sim_id: sim_id})
    LemonCore.Bus.broadcast(sim_topic(sim_id), event)
  end

  @spec broadcast_decision(String.t(), map()) :: :ok
  def broadcast_decision(sim_id, payload) when is_binary(sim_id) and is_map(payload) do
    event = LemonCore.Event.new(:sim_decision_made, payload, %{sim_id: sim_id})
    LemonCore.Bus.broadcast(decisions_topic(sim_id), event)
  end
end
