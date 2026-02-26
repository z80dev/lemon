defmodule LemonGames.Bus do
  @moduledoc """
  PubSub helper for game platform events.

  Broadcasts match and lobby events via `LemonCore.Bus`.
  """

  alias LemonCore.{Bus, Event}

  @lobby_topic "games:lobby"

  @spec lobby_topic() :: String.t()
  def lobby_topic, do: @lobby_topic

  @spec match_topic(String.t()) :: String.t()
  def match_topic(match_id), do: "games:match:" <> match_id

  @spec subscribe_lobby() :: :ok
  def subscribe_lobby, do: Bus.subscribe(@lobby_topic)

  @spec subscribe_match(String.t()) :: :ok
  def subscribe_match(match_id), do: Bus.subscribe(match_topic(match_id))

  @spec unsubscribe_lobby() :: :ok
  def unsubscribe_lobby, do: Bus.unsubscribe(@lobby_topic)

  @spec unsubscribe_match(String.t()) :: :ok
  def unsubscribe_match(match_id), do: Bus.unsubscribe(match_topic(match_id))

  @spec broadcast_lobby_changed(String.t(), String.t(), String.t()) :: :ok
  def broadcast_lobby_changed(match_id, status, reason) do
    event =
      Event.new(:game_lobby_changed, %{
        "match_id" => match_id,
        "status" => status,
        "reason" => reason
      })

    Bus.broadcast(@lobby_topic, event)
  end

  @spec broadcast_match_event(String.t(), map()) :: :ok
  def broadcast_match_event(match_id, payload) do
    event = Event.new(:game_match_event, payload)
    Bus.broadcast(match_topic(match_id), event)
  end
end
