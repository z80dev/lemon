defmodule LemonControlPlane.Methods.SessionsActiveList do
  @moduledoc """
  Handler for the `sessions.active.list` method.

  Lists active (in-flight) sessions with optional agent/route filtering.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "sessions.active.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    agent_id = get_param(params, "agentId")
    limit = normalize_limit(get_param(params, "limit"))
    route = normalize_route_filter(get_param(params, "route"))

    sessions =
      LemonRouter.list_agent_sessions(
        agent_id: agent_id,
        route: route,
        limit: limit
      )
      |> Enum.filter(&(&1[:active?] == true))
      |> Enum.map(&format_session/1)

    {:ok,
     %{
       "sessions" => sessions,
       "total" => length(sessions),
       "filters" => %{
         "agentId" => agent_id,
         "limit" => limit,
         "route" => format_route_filter(route)
       }
     }}
  rescue
    e ->
      {:error, {:internal_error, "Failed to list active sessions", Exception.message(e)}}
  end

  defp format_session(session) do
    %{
      "sessionKey" => session[:session_key],
      "agentId" => session[:agent_id],
      "kind" => to_string(session[:kind] || :unknown),
      "channelId" => session[:channel_id],
      "accountId" => session[:account_id],
      "peerKind" => session[:peer_kind] && to_string(session[:peer_kind]),
      "peerId" => session[:peer_id],
      "threadId" => session[:thread_id],
      "route" => format_route(session),
      "target" => target_from_session(session),
      "peerLabel" => session[:peer_label],
      "peerUsername" => session[:peer_username],
      "topicName" => session[:topic_name],
      "chatType" => session[:chat_type],
      "subId" => session[:sub_id],
      "active" => session[:active?] == true,
      "runId" => session[:run_id],
      "runCount" => session[:run_count],
      "createdAtMs" => session[:created_at_ms],
      "updatedAtMs" => session[:updated_at_ms]
    }
  end

  defp target_from_session(session) do
    channel_id = session[:channel_id]
    account_id = session[:account_id]
    peer_kind = session[:peer_kind]
    peer_id = session[:peer_id]
    thread_id = session[:thread_id]

    cond do
      not is_binary(channel_id) or not is_binary(peer_id) ->
        nil

      channel_id == "telegram" ->
        account_prefix =
          if account_id in [nil, "", "default"] do
            ""
          else
            "#{account_id}@"
          end

        topic_suffix =
          if is_binary(thread_id) and thread_id != "" do
            "/#{thread_id}"
          else
            ""
          end

        "tg:#{account_prefix}#{peer_id}#{topic_suffix}"

      true ->
        base = "#{channel_id}:#{account_id}:#{peer_kind}:#{peer_id}"

        if is_binary(thread_id) and thread_id != "" do
          "#{base}/#{thread_id}"
        else
          base
        end
    end
  end

  defp format_route(session_or_route) when is_map(session_or_route) do
    %{
      "channelId" => map_get(session_or_route, :channel_id),
      "accountId" => map_get(session_or_route, :account_id),
      "peerKind" =>
        map_get(session_or_route, :peer_kind) && to_string(map_get(session_or_route, :peer_kind)),
      "peerId" => map_get(session_or_route, :peer_id),
      "threadId" => map_get(session_or_route, :thread_id)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp format_route(_), do: %{}

  defp normalize_route_filter(route) when is_map(route) do
    %{}
    |> maybe_put(
      :channel_id,
      normalize_optional_binary(route_value(route, :channel_id, "channelId"))
    )
    |> maybe_put(
      :account_id,
      normalize_optional_binary(route_value(route, :account_id, "accountId"))
    )
    |> maybe_put(
      :peer_kind,
      normalize_optional_binary(route_value(route, :peer_kind, "peerKind"))
    )
    |> maybe_put(
      :peer_id,
      normalize_optional_binary(route_value(route, :peer_id, "peerId", :chat_id, "chatId"))
    )
    |> maybe_put(
      :thread_id,
      normalize_optional_binary(route_value(route, :thread_id, "threadId", :topic_id, "topicId"))
    )
  end

  defp normalize_route_filter(_), do: %{}

  defp format_route_filter(route) when is_map(route), do: format_route(route)
  defp format_route_filter(_), do: %{}

  defp route_value(route, primary_atom, primary_string) do
    map_get(route, primary_atom) || map_get(route, primary_string)
  end

  defp route_value(route, a1, s1, a2, s2) do
    route_value(route, a1, s1) || map_get(route, a2) || map_get(route, s2)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _rest} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_limit(_), do: nil

  defp normalize_optional_binary(nil), do: nil

  defp normalize_optional_binary(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_binary(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_optional_binary()

  defp normalize_optional_binary(value) when is_integer(value),
    do: value |> Integer.to_string() |> normalize_optional_binary()

  defp normalize_optional_binary(_), do: nil

  defp get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_params, _key), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    underscored = Macro.underscore(key)
    Map.get(map, key) || Map.get(map, underscored)
  end

  defp map_get(_, _), do: nil
end
