defmodule LemonHoncho.UserPeer do
  @moduledoc "Resolves a turn's human peer from transport-owned channel identity."

  alias LemonHoncho.Config

  @doc "Only canonical channel sessions may supply channel identity."
  def identity(session_key, identity) when is_binary(session_key) and is_map(identity) do
    channel = Map.get(identity, :channel_id) || Map.get(identity, "channel_id")

    case LemonCore.SessionKey.parse(session_key) do
      %{kind: :channel_peer, channel_id: ^channel} -> identity
      _ -> nil
    end
  end

  def identity(_, _), do: nil

  @doc "Channel-qualified runtime ids keep identical sender ids on different platforms apart."
  def runtime_id(%{channel_id: channel, sender_id: sender})
      when is_binary(channel) and is_binary(sender) and channel != "" and sender != "" do
    channel <> "_" <> sender
  end

  def runtime_id(%{"channel_id" => channel, "sender_id" => sender}),
    do: runtime_id(%{channel_id: channel, sender_id: sender})

  def runtime_id(_), do: nil

  @doc "Pin, alias, owner peer, then platform-qualified runtime peer; local sessions keep the configured peer."
  def resolve(%Config{} = config, identity) do
    case runtime_id(identity) do
      nil ->
        config.user_peer

      runtime_id ->
        cond do
          config.pin_user_peer ->
            config.user_peer

          peer = config.user_peer_aliases[runtime_id] ->
            valid_peer(peer, config.user_peer)

          owner?(identity) ->
            config.user_peer

          true ->
            sanitize(config.runtime_peer_prefix <> runtime_id)
        end
    end
  end

  def bot?(%{is_bot: true}), do: true
  def bot?(%{"is_bot" => true}), do: true
  def bot?(_), do: false

  defp owner?(%{owner?: true}), do: true
  defp owner?(%{"owner?" => true}), do: true
  defp owner?(_), do: false

  defp valid_peer(peer, fallback) do
    if is_binary(peer) and Regex.match?(~r/^[A-Za-z0-9_-]{1,512}$/, peer),
      do: peer,
      else: fallback
  end

  @doc "Partitions volatile context by resolved peer, including multi-sender group chats."
  def cache_key(key, %Config{} = config, identity) do
    if runtime_id(identity) do
      digest =
        :crypto.hash(:sha256, resolve(config, identity))
        |> Base.encode16(case: :lower)

      key <> ":honcho-peer:" <> digest
    else
      key
    end
  end

  # Keep a digest whenever normalization changes an id, avoiding collisions such
  # as `a.b` versus `a/b` or two long ids with the same first 512 bytes.
  defp sanitize(value) do
    normalized = String.replace(value, ~r/[^A-Za-z0-9_-]/u, "_")

    if normalized == value and byte_size(value) <= 512 do
      value
    else
      digest = :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 16)
      String.slice(normalized, 0, 495) <> "_" <> digest
    end
  end
end
