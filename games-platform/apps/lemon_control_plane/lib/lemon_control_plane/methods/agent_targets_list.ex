defmodule LemonControlPlane.Methods.AgentTargetsList do
  @moduledoc """
  Handler for the `agent.targets.list` method.

  Lists known channel targets (for example Telegram rooms/topics) so endpoint
  aliases can be created without guessing IDs.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "agent.targets.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    channel_id = get_param(params, "channelId") || "telegram"
    account_id = get_param(params, "accountId")
    agent_id = get_param(params, "agentId")
    query = get_param(params, "query")
    limit = normalize_limit(get_param(params, "limit"))

    targets =
      LemonRouter.list_agent_targets(
        channel_id: channel_id,
        account_id: account_id,
        agent_id: agent_id,
        query: query,
        limit: limit
      )
      |> Enum.map(&format_target/1)

    {:ok,
     %{
       "targets" => targets,
       "total" => length(targets),
       "channelId" => channel_id
     }}
  rescue
    e ->
      {:error, {:internal_error, "Failed to list known targets", Exception.message(e)}}
  end

  defp format_target(target) do
    %{
      "channelId" => target[:channel_id],
      "accountId" => target[:account_id],
      "peerKind" => target[:peer_kind] && to_string(target[:peer_kind]),
      "peerId" => target[:peer_id],
      "threadId" => target[:thread_id],
      "chatId" => target[:chat_id],
      "topicId" => target[:topic_id],
      "target" => target[:target],
      "label" => target[:label],
      "peerLabel" => target[:peer_label],
      "peerUsername" => target[:peer_username],
      "topicName" => target[:topic_name],
      "chatType" => target[:chat_type],
      "sessionCount" => target[:session_count] || 0,
      "activeSessionCount" => target[:active_session_count] || 0,
      "latestSessionKey" => target[:latest_session_key],
      "latestUpdatedAtMs" => target[:latest_updated_at_ms],
      "agentIds" => target[:agent_ids] || []
    }
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
