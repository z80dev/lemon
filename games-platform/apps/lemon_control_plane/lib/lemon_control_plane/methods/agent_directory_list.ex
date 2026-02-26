defmodule LemonControlPlane.Methods.AgentDirectoryList do
  @moduledoc """
  Handler for the `agent.directory.list` method.

  Returns discoverability metadata for agents and (optionally) sessions.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "agent.directory.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    agent_id = get_param(params, "agentId")
    include_sessions? = get_param(params, "includeSessions")
    include_sessions? = if is_nil(include_sessions?), do: true, else: include_sessions? == true
    limit = get_param(params, "limit")
    route = get_param(params, "route")

    agents =
      LemonRouter.list_agent_directory()
      |> maybe_filter_agents(agent_id)
      |> Enum.map(&format_agent/1)

    sessions =
      if include_sessions? do
        LemonRouter.list_agent_sessions(
          agent_id: agent_id,
          route: route,
          limit: normalize_limit(limit)
        )
        |> Enum.map(&format_session/1)
      else
        []
      end

    {:ok,
     %{
       "agents" => agents,
       "sessions" => sessions,
       "totalAgents" => length(agents),
       "totalSessions" => length(sessions)
     }}
  rescue
    e ->
      {:error, {:internal_error, "Failed to list agent directory", Exception.message(e)}}
  end

  defp maybe_filter_agents(agents, nil), do: agents
  defp maybe_filter_agents(agents, ""), do: agents

  defp maybe_filter_agents(agents, agent_id) do
    Enum.filter(agents, &(&1.agent_id == agent_id))
  end

  defp format_agent(agent) do
    %{
      "agentId" => agent[:agent_id],
      "name" => agent[:name],
      "description" => agent[:description],
      "latestSessionKey" => agent[:latest_session_key],
      "latestUpdatedAtMs" => agent[:latest_updated_at_ms],
      "activeSessionCount" => agent[:active_session_count] || 0,
      "sessionCount" => agent[:session_count] || 0,
      "routeCount" => agent[:route_count] || 0
    }
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

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _rest} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_limit(_), do: nil

  defp get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_params, _key), do: nil
end
