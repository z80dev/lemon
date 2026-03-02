defmodule LemonSkills.Tools.GetMyTweets do
  @moduledoc """
  Tool for agents to look up their own recent tweets on X (Twitter).

  This tool allows agents to:
  - Review their own recent tweets
  - Check engagement metrics (likes, retweets, replies, impressions)
  - Filter out replies and/or retweets

  ## Configuration

  Requires X_API_CLIENT_ID, X_API_CLIENT_SECRET, X_API_ACCESS_TOKEN,
  and X_API_REFRESH_TOKEN to be set in the environment.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @doc """
  Returns the GetMyTweets tool definition.
  """
  @spec tool(keyword()) :: AgentTool.t()
  def tool(_opts \\ []) do
    account_label = configured_account_label()

    %AgentTool{
      name: "get_my_tweets",
      description: """
      Get recent tweets posted by #{account_label} on X (Twitter). Use this to review \
      your own tweets, check engagement metrics, or recall what you've posted recently.
      """,
      label: "Get My Tweets",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of tweets to fetch (default: 10, max: 100)",
            "default" => 10
          },
          "exclude_replies" => %{
            "type" => "boolean",
            "description" => "Exclude reply tweets (default: false)",
            "default" => false
          },
          "exclude_retweets" => %{
            "type" => "boolean",
            "description" => "Exclude retweets (default: false)",
            "default" => false
          },
          "pagination_token" => %{
            "type" => "string",
            "description" =>
              "Token for fetching the next page of results. Use the next_token from a previous response to get older tweets."
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4)
    }
  end

  @doc """
  Execute the get_my_tweets tool.
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
         opts <- build_opts(params, limit),
         {:ok, tweets_response} <- LemonChannels.Adapters.XAPI.Client.get_my_tweets(opts) do
      format_tweets_result(tweets_response)
    else
      {:error, :not_configured} ->
        return_not_configured()

      {:error, {:invalid_input, message}} ->
        return_error(message)

      {:error, {:api_error, status, body}} ->
        return_error("API error (HTTP #{status}): #{inspect(body)}")

      {:error, reason} ->
        return_error("Failed to get tweets: #{inspect(reason)}")
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp build_opts(params, limit) do
    [
      limit: limit,
      exclude_replies: params["exclude_replies"] == true,
      exclude_retweets: params["exclude_retweets"] == true,
      pagination_token: params["pagination_token"]
    ]
  end

  defp format_tweets_result(%{"data" => tweets, "meta" => meta}) when is_list(tweets) do
    formatted_tweets = format_tweet_list(tweets)
    next_token = meta["next_token"]
    build_result(formatted_tweets, length(tweets), next_token)
  end

  defp format_tweets_result(%{"data" => tweets}) when is_list(tweets) do
    formatted_tweets = format_tweet_list(tweets)
    build_result(formatted_tweets, length(tweets), nil)
  end

  defp format_tweets_result(%{"meta" => %{"result_count" => 0}}) do
    %AgentToolResult{
      content: [%TextContent{text: "No recent tweets found."}],
      details: %{tweets: [], count: 0}
    }
  end

  defp format_tweets_result(other) do
    return_error("Unexpected response from X API: #{inspect(other)}")
  end

  defp format_tweet_list(tweets) do
    Enum.map(tweets, fn t ->
      metrics = t["public_metrics"] || %{}

      %{
        id: t["id"],
        text: t["text"],
        created_at: t["created_at"],
        likes: metrics["like_count"] || 0,
        retweets: metrics["retweet_count"] || 0,
        replies: metrics["reply_count"] || 0,
        impressions: metrics["impression_count"] || 0
      }
    end)
  end

  defp build_result(tweets, count, next_token) do
    tweet_texts =
      Enum.map(tweets, fn t ->
        url = tweet_url(t[:id])

        """
        Tweet ID: #{t[:id]}
        "#{t[:text]}"
        Likes: #{t[:likes]} | Retweets: #{t[:retweets]} | Replies: #{t[:replies]} | Impressions: #{t[:impressions]}
        URL: #{url}
        """
      end)

    pagination_hint =
      if next_token,
        do: "\nMore tweets available. Use pagination_token: \"#{next_token}\" to fetch the next page.",
        else: ""

    text = """
    Found #{count} recent tweet(s):

    #{Enum.join(tweet_texts, "\n---\n")}
    #{pagination_hint}
    """

    details = %{
      tweets: tweets,
      count: count
    }

    details =
      if next_token,
        do: Map.put(details, :next_token, next_token),
        else: details

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: details
    }
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

  defp return_not_configured do
    text = """
    X API not configured

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
      content: [%TextContent{text: "Error: #{message}"}],
      details: %{error: message}
    }
  end

  defp tweet_url(tweet_id) do
    case x_account_username() do
      nil -> "https://x.com/i/web/status/#{tweet_id}"
      username -> "https://x.com/#{username}/status/#{tweet_id}"
    end
  end

  defp configured_account_label do
    case x_account_username() do
      nil -> "the configured X account"
      username -> "@#{username}"
    end
  end

  defp x_account_username do
    config = LemonChannels.Adapters.XAPI.config()
    candidate = config[:default_account_username] || config[:default_account_id]

    case candidate do
      nil ->
        nil

      value ->
        normalized =
          value
          |> to_string()
          |> String.trim()
          |> String.trim_leading("@")

        cond do
          normalized == "" -> nil
          Regex.match?(~r/^\d+$/, normalized) -> nil
          true -> normalized
        end
    end
  end
end
