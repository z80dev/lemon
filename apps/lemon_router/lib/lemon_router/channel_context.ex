defmodule LemonRouter.ChannelContext do
  @moduledoc false
  @internal_channel_ids MapSet.new(["delegate"])

  def parse_session_key(session_key) when is_binary(session_key) do
    case LemonCore.SessionKey.parse(session_key) do
      {:error, _} ->
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

      parsed when is_map(parsed) ->
        parsed
    end
  rescue
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

  def parse_session_key(_session_key) do
    %{
      agent_id: "unknown",
      kind: :unknown,
      channel_id: nil,
      account_id: "unknown",
      peer_kind: :unknown,
      peer_id: "",
      thread_id: nil,
      sub_id: nil
    }
  end

  def channel_id(session_key) do
    case parse_session_key(session_key) do
      %{kind: :channel_peer, channel_id: channel_id}
      when is_binary(channel_id) and
             channel_id !=
               "" ->
        if internal_channel_id?(channel_id), do: :error, else: {:ok, channel_id}

      _ ->
        :error
    end
  end

  defp internal_channel_id?(channel_id) when is_binary(channel_id) do
    MapSet.member?(@internal_channel_ids, channel_id)
  end

  def compact_meta(meta) when is_map(meta) do
    Map.reject(meta, fn {_k, v} -> is_nil(v) end)
  end

  def compact_meta(_), do: %{}

  def coalescer_meta_from_request(%{meta: meta}) when is_map(meta) do
    %{
      user_msg_id: meta[:user_msg_id],
      show_running_prefix?:
        present_progress_reference?(meta[:progress_msg_id] || meta["progress_msg_id"])
    }
  end

  def coalescer_meta_from_request(_), do: %{}

  defp present_progress_reference?(value) when is_integer(value), do: true
  defp present_progress_reference?(value) when is_binary(value), do: value != ""
  defp present_progress_reference?(_), do: false

  def parse_int(nil), do: nil
  def parse_int(v) when is_integer(v), do: v

  def parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> nil
    end
  end

  def parse_int(_), do: nil
end
