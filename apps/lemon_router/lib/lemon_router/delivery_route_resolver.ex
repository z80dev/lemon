defmodule LemonRouter.DeliveryRouteResolver do
  @moduledoc false

  alias LemonCore.DeliveryRoute
  alias LemonRouter.ChannelContext

  @spec resolve(binary(), binary() | nil, map()) :: {:ok, DeliveryRoute.t()} | :error
  def resolve(session_key, fallback_channel_id \\ nil, meta \\ %{})

  def resolve(session_key, fallback_channel_id, meta) when is_binary(session_key) do
    parsed = ChannelContext.parse_session_key(session_key)

    cond do
      parsed.kind == :channel_peer and is_binary(parsed.channel_id) and parsed.channel_id != "" and
        parsed.peer_kind in [:dm, :group, :channel] and is_binary(parsed.peer_id) and
          parsed.peer_id != "" ->
        {:ok,
         %DeliveryRoute{
           channel_id: parsed.channel_id,
           account_id: parsed.account_id || "default",
           peer_kind: parsed.peer_kind,
           peer_id: parsed.peer_id,
           thread_id: parsed.thread_id
         }}

      is_binary(fallback_channel_id) and fallback_channel_id != "" ->
        from_meta(fallback_channel_id, meta)

      true ->
        :error
    end
  end

  def resolve(_session_key, fallback_channel_id, meta) when is_binary(fallback_channel_id) do
    from_meta(fallback_channel_id, meta)
  end

  def resolve(_session_key, _fallback_channel_id, _meta), do: :error

  defp from_meta(channel_id, meta) when is_map(meta) do
    case meta[:peer] || meta["peer"] || %{} do
      peer when is_map(peer) or is_list(peer) ->
        peer_kind = normalize_peer_kind(peer[:kind] || peer["kind"])
        peer_id = peer[:id] || peer["id"]

        if not is_nil(peer_kind) and is_binary(peer_id) and peer_id != "" do
          {:ok,
           %DeliveryRoute{
             channel_id: channel_id,
             account_id: (meta[:account_id] || meta["account_id"] || "default") |> to_string(),
             peer_kind: peer_kind,
             peer_id: peer_id,
             thread_id: peer[:thread_id] || peer["thread_id"]
           }}
        else
          :error
        end

      _ ->
        :error
    end
  rescue
    _ in [ArgumentError, Protocol.UndefinedError] -> :error
  end

  defp from_meta(_channel_id, _meta), do: :error

  defp normalize_peer_kind(kind) do
    Map.get(
      %{
        "dm" => :dm,
        "group" => :group,
        "channel" => :channel,
        dm: :dm,
        group: :group,
        channel: :channel
      },
      kind
    )
  end
end
