defmodule LemonSkills.Tools.PostToX do
  @moduledoc """
  Tool for agents to post tweets to X (Twitter).

  This tool allows agents to:
  - Post new tweets
  - Reply to existing tweets
  - Get recent mentions

  ## Usage

  The tool is designed to be used by agents to post updates, respond to
  mentions, or engage with the community on behalf of @realzeebot.

  ## Configuration

  Requires X_API_CLIENT_ID, X_API_CLIENT_SECRET, X_API_ACCESS_TOKEN,
  and X_API_REFRESH_TOKEN to be set in the environment.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @doc """
  Returns the PostToX tool definition.
  """
  @spec tool(keyword()) :: AgentTool.t()
  def tool(_opts \\ []) do
    %AgentTool{
      name: "post_to_x",
      description: """
      Post a tweet to X (Twitter) as @realzeebot. Use this to share updates, \
      thoughts, or engage with the community. Tweets are limited to 280 characters.
      """,
      label: "Post to X",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => "string",
            "description" => "The tweet content (max 280 characters)"
          },
          "reply_to" => %{
            "type" => "string",
            "description" => "Optional: Tweet ID to reply to"
          }
        },
        "required" => ["text"]
      },
      execute: &execute(&1, &2, &3, &4)
    }
  end

  @doc """
  Execute the post_to_x tool.

  ## Parameters

  - `tool_call_id` - Unique identifier for this tool invocation
  - `params` - Parameters map with "text" and optional "reply_to"
  - `signal` - Abort signal for cancellation (can be nil)
  - `on_update` - Callback for streaming partial results (unused)
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: function() | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, _signal, _on_update) do
    with {:ok, text} <- normalize_text(Map.get(params, "text")),
         {:ok, reply_to} <- normalize_reply_to(Map.get(params, "reply_to")),
         :ok <- ensure_configured(),
         {:ok, response} <- post_tweet(text, reply_to) do
      build_success_result(response, reply_to)
    else
      {:error, :not_configured} ->
        return_not_configured()

      {:error, {:invalid_input, message}} ->
        return_error(message)

      {:error, {:api_error, status, body}} ->
        return_error("API error (HTTP #{status}): #{inspect(body)}")

      {:error, reason} ->
        return_error("Failed to post tweet: #{inspect(reason)}")
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp return_not_configured do
    text = """
    ❌ X API not configured

    To enable posting to X, set these environment variables:
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

  defp ensure_configured do
    if LemonChannels.Adapters.XAPI.configured?() do
      :ok
    else
      {:error, :not_configured}
    end
  end

  defp normalize_text(nil), do: {:error, {:invalid_input, "Missing required parameter: text"}}

  defp normalize_text(text) when is_binary(text) do
    if String.trim(text) == "" do
      {:error, {:invalid_input, "Tweet text cannot be empty"}}
    else
      {:ok, text}
    end
  end

  defp normalize_text(_), do: {:error, {:invalid_input, "Parameter 'text' must be a string"}}

  defp normalize_reply_to(nil), do: {:ok, nil}

  defp normalize_reply_to(reply_to) when is_binary(reply_to) do
    case String.trim(reply_to) do
      "" -> {:ok, nil}
      value -> {:ok, value}
    end
  end

  defp normalize_reply_to(_),
    do: {:error, {:invalid_input, "Parameter 'reply_to' must be a string"}}

  defp post_tweet(text, nil), do: LemonChannels.Adapters.XAPI.Client.post_text(text)
  defp post_tweet(text, reply_to), do: LemonChannels.Adapters.XAPI.Client.reply(reply_to, text)

  defp build_success_result(%{"data" => %{"id" => tweet_id, "text" => tweet_text}}, reply_to) do
    success_result(tweet_id, tweet_text, reply_to)
  end

  defp build_success_result(%{tweet_id: tweet_id, text: tweet_text}, reply_to) do
    success_result(tweet_id, tweet_text, reply_to)
  end

  defp build_success_result(other, _reply_to) do
    return_error("Unexpected response from X API: #{inspect(other)}")
  end

  defp success_result(tweet_id, tweet_text, reply_to) do
    text_response = """
    ✅ Tweet posted successfully!

    Tweet ID: #{tweet_id}
    Text: #{tweet_text}
    URL: https://x.com/realzeebot/status/#{tweet_id}
    """

    %AgentToolResult{
      content: [%TextContent{text: text_response}],
      details: %{
        tweet_id: tweet_id,
        text: tweet_text,
        reply_to: reply_to
      }
    }
  end
end
