defmodule LemonRouter.ChannelContext do
  @moduledoc false

  @allowed_peer_kinds %{
    "dm" => :dm,
    "group" => :group,
    "channel" => :channel,
    "main" => :main,
    "unknown" => :unknown
  }

  def parse_session_key(session_key) when is_binary(session_key) do
    case LemonRouter.SessionKey.parse(session_key) do
      {:error, _} -> fallback_parse_session_key(session_key)
      parsed when is_map(parsed) -> parsed
    end
  rescue
    _ -> fallback_parse_session_key(session_key)
  end

  def parse_session_key(_session_key), do: fallback_parse_session_key("")

  def channel_id(session_key) do
    case parse_session_key(session_key) do
      %{kind: :channel_peer, channel_id: channel_id}
      when is_binary(channel_id) and
             channel_id !=
               "" ->
        {:ok, channel_id}

      _ ->
        :error
    end
  end

  def channel_supports_edit?(channel_id) when is_binary(channel_id) do
    if is_pid(Process.whereis(LemonChannels.Registry)) do
      case LemonChannels.Registry.get_capabilities(channel_id) do
        %{edit_support: true} -> true
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  def channel_supports_edit?(_), do: false

  def compact_meta(meta) when is_map(meta) do
    Map.reject(meta, fn {_k, v} -> is_nil(v) end)
  end

  def compact_meta(_), do: %{}

  def coalescer_meta_from_job(%{meta: meta}) when is_map(meta) do
    %{
      progress_msg_id: meta[:progress_msg_id],
      status_msg_id: meta[:status_msg_id],
      user_msg_id: meta[:user_msg_id]
    }
  end

  def coalescer_meta_from_job(_), do: %{}

  def parse_int(nil), do: nil
  def parse_int(v) when is_integer(v), do: v

  def parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> nil
    end
  end

  def parse_int(_), do: nil

  defp fallback_parse_session_key(session_key) do
    case String.split(session_key, ":") do
      ["agent", agent_id, channel_id, account_id, peer_kind, peer_id | rest] ->
        %{
          agent_id: agent_id,
          kind: :channel_peer,
          channel_id: channel_id,
          account_id: account_id,
          peer_kind: safe_to_atom(peer_kind),
          peer_id: peer_id,
          thread_id: extract_thread_id(rest),
          sub_id: nil
        }

      ["agent", agent_id, "main"] ->
        %{
          agent_id: agent_id,
          kind: :main,
          channel_id: nil,
          account_id: agent_id,
          peer_kind: :main,
          peer_id: "main",
          thread_id: nil,
          sub_id: nil
        }

      ["channel", "telegram", transport, chat_id | rest] ->
        %{
          agent_id: "default",
          kind: :channel_peer,
          channel_id: "telegram",
          account_id: transport,
          peer_kind: :dm,
          peer_id: chat_id,
          thread_id: extract_thread_id(rest),
          sub_id: nil
        }

      _ ->
        %{
          agent_id: "unknown",
          kind: :unknown,
          channel_id: nil,
          account_id: "unknown",
          peer_kind: :unknown,
          peer_id: session_key,
          thread_id: nil,
          sub_id: nil
        }
    end
  end

  defp extract_thread_id(["thread", thread_id | _]), do: thread_id
  defp extract_thread_id(_), do: nil

  defp safe_to_atom(str) when is_binary(str) do
    Map.get(@allowed_peer_kinds, str, :unknown)
  end
end
