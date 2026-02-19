defmodule LemonSkills.Tools.GetXMentions do
  @moduledoc """
  Tool for agents to get recent mentions on X (Twitter).

  This tool allows agents to:
  - Check recent mentions of @realzeebot
  - See who is engaging with the account
  - Find tweets to reply to

  ## Usage

  The tool is designed to be used by agents to monitor engagement
  and find opportunities to respond to the community.

  ## Configuration

  Requires X_API_CLIENT_ID, X_API_CLIENT_SECRET, X_API_ACCESS_TOKEN,
  and X_API_REFRESH_TOKEN to be set in the environment.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @doc """
  Returns the GetXMentions tool definition.
  """
  @spec tool(keyword()) :: AgentTool.t()
  def tool(_opts \\ []) do
    %AgentTool{
      name: "get_x_mentions",
      description: """
      Get recent mentions of @realzeebot on X (Twitter). Use this to check \
      who is engaging with the account and find tweets to reply to.
      """,
      label: "Get X Mentions",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of mentions to fetch (default: 10, max: 100)",
            "default" => 10
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4)
    }
  end

  @doc """
  Execute the get_x_mentions tool.
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: function() | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, _signal, _on_update) do
    with {:ok, limit} <- normalize_limit(Map.get(params, "limit", 10)),
         :ok <- ensure_configured(),
         {:ok, mentions_response} <- LemonChannels.Adapters.XAPI.Client.get_mentions(limit: limit) do
      format_mentions_result(mentions_response)
    else
      {:error, :not_configured} ->
        return_not_configured()

      {:error, {:invalid_input, message}} ->
        return_error(message)

      {:error, {:api_error, status, body}} ->
        return_error("API error (HTTP #{status}): #{inspect(body)}")

      {:error, reason} ->
        return_error("Failed to get mentions: #{inspect(reason)}")
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp format_mentions_result(%{"data" => mentions, "includes" => includes})
       when is_list(mentions) do
    users =
      Map.get(includes, "users", [])
      |> Map.new(fn u -> {u["id"], u} end)

    formatted_mentions =
      Enum.map(mentions, fn m ->
        author = Map.get(users, m["author_id"], %{})

        %{
          id: m["id"],
          text: m["text"],
          author_username: author["username"],
          author_name: author["name"],
          created_at: m["created_at"]
        }
      end)

    build_result(formatted_mentions, length(mentions))
  end

  defp format_mentions_result(%{"data" => mentions}) when is_list(mentions) do
    formatted_mentions =
      Enum.map(mentions, fn m ->
        %{
          id: m["id"],
          text: m["text"],
          author_id: m["author_id"],
          created_at: m["created_at"]
        }
      end)

    build_result(formatted_mentions, length(mentions))
  end

  defp format_mentions_result(%{"meta" => %{"result_count" => 0}}) do
    %AgentToolResult{
      content: [%TextContent{text: "No recent mentions found."}],
      details: %{mentions: [], count: 0}
    }
  end

  defp format_mentions_result(mentions) when is_list(mentions) do
    build_result(mentions, length(mentions))
  end

  defp format_mentions_result(other) do
    return_error("Unexpected response from X API: #{inspect(other)}")
  end

  defp ensure_configured do
    if LemonChannels.Adapters.XAPI.configured?() do
      :ok
    else
      {:error, :not_configured}
    end
  end

  defp normalize_limit(nil), do: {:ok, 10}

  defp normalize_limit(limit) when is_integer(limit) and limit > 0 do
    {:ok, min(limit, 100)}
  end

  defp normalize_limit(limit) when is_integer(limit) do
    {:error, {:invalid_input, "Parameter 'limit' must be a positive integer"}}
  end

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} -> normalize_limit(parsed)
      _ -> {:error, {:invalid_input, "Parameter 'limit' must be a positive integer"}}
    end
  end

  defp normalize_limit(_),
    do: {:error, {:invalid_input, "Parameter 'limit' must be a positive integer"}}

  defp build_result(mentions, count) do
    mention_texts =
      Enum.map(mentions, fn m ->
        username =
          m[:author_username] || m["author_username"] || m[:author_id] || m["author_id"] ||
            "unknown"

        name = m[:author_name] || m["author_name"] || username
        text = m[:text] || m["text"] || ""
        id = m[:id] || m["id"]

        """
        @#{username} (#{name})
        Tweet ID: #{id}
        "#{text}"
        """
      end)

    text = """
    Found #{count} recent mention(s):

    #{Enum.join(mention_texts, "\n---\n")}
    """

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{
        mentions: mentions,
        count: count
      }
    }
  end

  defp return_not_configured do
    text = """
    ❌ X API not configured

    To enable X integration, set these environment variables:
    - X_API_CLIENT_ID
    - X_API_CLIENT_SECRET
    - X_API_ACCESS_TOKEN
    - X_API_REFRESH_TOKEN

    Get these from https://developer.x.com
    """

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{error: :not_configured}
    }
  end

  defp return_error(message) do
    %AgentToolResult{
      content: [%TextContent{text: "❌ #{message}"}],
      details: %{error: message}
    }
  end
end
