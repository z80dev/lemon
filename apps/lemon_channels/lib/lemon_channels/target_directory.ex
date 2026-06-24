defmodule LemonChannels.TargetDirectory do
  @moduledoc """
  Channel-owned directory of recently seen route targets.
  """

  alias LemonChannels.Discord.KnownTargetStore, as: DiscordKnownTargetStore
  alias LemonChannels.Telegram.KnownTargetStore, as: TelegramKnownTargetStore

  @peer_kind_map %{
    "dm" => :dm,
    "group" => :group,
    "channel" => :channel,
    "main" => :main,
    "unknown" => :unknown
  }

  @spec list_known_routes(keyword()) :: [map()]
  def list_known_routes(opts \\ []) do
    platforms = opts[:platforms] || ["telegram", "discord"]

    platforms
    |> Enum.flat_map(&known_routes/1)
    |> Enum.sort_by(&(&1.updated_at_ms || 0), :desc)
  end

  defp known_routes("telegram") do
    TelegramKnownTargetStore.list_available()
    |> Enum.map(&telegram_route/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  end

  defp known_routes("discord") do
    DiscordKnownTargetStore.list_available()
    |> Enum.map(&discord_route/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  end

  defp known_routes(_), do: []

  defp telegram_route({{account_id, chat_id, topic_id}, entry}) when is_map(entry) do
    with account_id when is_binary(account_id) and account_id != "" <-
           normalize_optional_binary(account_id),
         peer_id when is_binary(peer_id) <- target_peer_id(entry, chat_id) do
      thread_id = target_thread_id(entry, topic_id)

      %{
        channel_id: "telegram",
        account_id: account_id,
        peer_kind:
          normalize_peer_kind(map_get(entry, :peer_kind)) || infer_telegram_peer_kind(chat_id),
        peer_id: peer_id,
        thread_id: thread_id,
        target: render_short_target("tg", account_id, peer_id, thread_id),
        peer_label:
          normalize_optional_binary(
            map_get(entry, :chat_title) || map_get(entry, :chat_display_name)
          ),
        peer_username: normalize_optional_binary(map_get(entry, :chat_username)),
        topic_name: normalize_optional_binary(map_get(entry, :topic_name)),
        chat_type: normalize_optional_binary(map_get(entry, :chat_type)),
        updated_at_ms: normalize_int(map_get(entry, :updated_at_ms))
      }
    else
      _ -> nil
    end
  end

  defp telegram_route(_), do: nil

  defp discord_route({{account_id, channel_id, thread_id}, entry}) when is_map(entry) do
    with account_id when is_binary(account_id) and account_id != "" <-
           normalize_optional_binary(account_id),
         peer_id when is_binary(peer_id) <- target_peer_id(entry, channel_id) do
      thread_id = target_thread_id(entry, thread_id)

      %{
        channel_id: "discord",
        account_id: account_id,
        peer_kind: normalize_peer_kind(map_get(entry, :peer_kind)) || :channel,
        peer_id: peer_id,
        thread_id: thread_id,
        target: render_short_target("discord", account_id, peer_id, thread_id),
        peer_label: normalize_optional_binary(map_get(entry, :channel_name)),
        peer_username: nil,
        topic_name: normalize_optional_binary(map_get(entry, :thread_name)),
        chat_type: normalize_optional_binary(map_get(entry, :channel_type)),
        guild_id: normalize_optional_binary(map_get(entry, :guild_id)),
        updated_at_ms: normalize_int(map_get(entry, :updated_at_ms))
      }
    else
      _ -> nil
    end
  end

  defp discord_route(_), do: nil

  defp target_peer_id(entry, id) do
    case normalize_optional_binary(map_get(entry, :peer_id)) do
      nil -> normalize_optional_binary(id)
      peer_id -> peer_id
    end
  end

  defp target_thread_id(entry, id) do
    case normalize_optional_binary(map_get(entry, :thread_id)) do
      nil -> normalize_optional_binary(id)
      thread_id -> thread_id
    end
  end

  defp render_short_target(prefix, account_id, peer_id, thread_id) do
    account_prefix =
      if account_id in [nil, "", "default"] do
        ""
      else
        "#{account_id}@"
      end

    suffix =
      case normalize_optional_binary(thread_id) do
        nil -> ""
        thread_id -> "/#{thread_id}"
      end

    "#{prefix}:#{account_prefix}#{peer_id}#{suffix}"
  end

  defp normalize_peer_kind(nil), do: nil

  defp normalize_peer_kind(kind) when is_atom(kind) do
    if kind in Map.values(@peer_kind_map), do: kind, else: nil
  end

  defp normalize_peer_kind(kind) when is_binary(kind) do
    Map.get(@peer_kind_map, String.downcase(kind))
  end

  defp normalize_peer_kind(_), do: nil

  defp normalize_optional_binary(nil), do: nil

  defp normalize_optional_binary(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_binary(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_optional_binary()

  defp normalize_optional_binary(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize_optional_binary(_), do: nil

  defp normalize_int(value) when is_integer(value), do: value

  defp normalize_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp normalize_int(_), do: nil

  defp infer_telegram_peer_kind(chat_id) when is_integer(chat_id) and chat_id < 0, do: :group
  defp infer_telegram_peer_kind(_chat_id), do: :dm

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_, _), do: nil
end
