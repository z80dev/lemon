defmodule LemonSkills.Tools.PostToX do
  @moduledoc """
  Tool for agents to post tweets to X (Twitter).

  This tool allows agents to:
  - Post new tweets
  - Reply to existing tweets
  - Get recent mentions

  ## Usage

  The tool is designed to be used by agents to post updates, respond to
  mentions, or engage with the community on behalf of the configured account.

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
    account_label = configured_account_label()

    %AgentTool{
      name: "post_to_x",
      description: """
      Post a tweet to X (Twitter) as #{account_label}. Use this to share updates, \
      thoughts, or engage with the community. Tweets are limited to 280 characters. \
      Supports attaching images by providing a media_path.
      """,
      label: "Post to X",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => "string",
            "description" => "The tweet content (max 280 characters). Optional if media_path is provided."
          },
          "reply_to" => %{
            "type" => "string",
            "description" => "Optional: Tweet ID to reply to"
          },
          "media_path" => %{
            "type" => "string",
            "description" => "Optional: Path to an image file to attach. Supports absolute paths and relative paths from project/workspace."
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4)
    }
  end

  @doc """
  Execute the post_to_x tool.

  ## Parameters

  - `tool_call_id` - Unique identifier for this tool invocation
  - `params` - Parameters map with "text", optional "reply_to", and optional "media_path"
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
    with {:ok, text} <- normalize_text(Map.get(params, "text"), Map.get(params, "media_path")),
         {:ok, reply_to} <- normalize_reply_to(Map.get(params, "reply_to")),
         {:ok, media_path} <- normalize_media_path(Map.get(params, "media_path")),
         :ok <- ensure_configured(),
         {:ok, response} <- post_tweet(text, reply_to, media_path) do
      build_success_result(response, reply_to, media_path)
    else
      {:error, :not_configured} ->
        return_not_configured()

      {:error, {:invalid_input, message}} ->
        return_error(message)

      {:error, {:api_error, status, body}} ->
        return_error("API error (HTTP #{status}): #{inspect(body)}")

      {:error, {:file_read_error, reason, path}} ->
        return_error("Failed to read media file #{path}: #{inspect(reason)}")

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

  defp normalize_text(nil, nil),
    do: {:error, {:invalid_input, "Either 'text' or 'media_path' must be provided"}}

  defp normalize_text(nil, media_path) when is_binary(media_path) do
    # Text is optional when media is provided
    {:ok, ""}
  end

  defp normalize_text(text, _media_path) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      {:error, {:invalid_input, "Tweet text cannot be empty"}}
    else
      {:ok, text}
    end
  end

  defp normalize_text(_, _), do: {:error, {:invalid_input, "Parameter 'text' must be a string"}}

  defp normalize_reply_to(nil), do: {:ok, nil}

  defp normalize_reply_to(reply_to) when is_binary(reply_to) do
    case String.trim(reply_to) do
      "" -> {:ok, nil}
      value -> {:ok, value}
    end
  end

  defp normalize_reply_to(_),
    do: {:error, {:invalid_input, "Parameter 'reply_to' must be a string"}}

  defp normalize_media_path(nil), do: {:ok, nil}

  defp normalize_media_path(path) when is_binary(path) do
    case String.trim(path) do
      "" -> {:ok, nil}
      value -> {:ok, value}
    end
  end

  defp normalize_media_path(_),
    do: {:error, {:invalid_input, "Parameter 'media_path' must be a string"}}

  defp post_tweet(text, reply_to, nil) do
    # No media - regular text tweet
    if is_nil(reply_to) do
      LemonChannels.Adapters.XAPI.Client.post_text(text)
    else
      LemonChannels.Adapters.XAPI.Client.reply(reply_to, text)
    end
  end

  defp post_tweet(text, reply_to, media_path) do
    # With media attachment
    opts = [reply_to: reply_to]
    LemonChannels.Adapters.XAPI.Client.post_with_media(text, media_path, opts)
  end

  defp build_success_result(%{"data" => %{"id" => tweet_id, "text" => tweet_text}}, reply_to, media_path) do
    success_result(tweet_id, tweet_text, reply_to, media_path)
  end

  defp build_success_result(%{tweet_id: tweet_id, text: tweet_text}, reply_to, media_path) do
    success_result(tweet_id, tweet_text, reply_to, media_path)
  end

  defp build_success_result(other, _reply_to, _media_path) do
    return_error("Unexpected response from X API: #{inspect(other)}")
  end

  defp success_result(tweet_id, tweet_text, reply_to, media_path) do
    url = tweet_url(tweet_id)
    media_info = if media_path, do: "\nMedia: #{Path.basename(media_path)}", else: ""

    text_response = """
    ✅ Tweet posted successfully!

    Tweet ID: #{tweet_id}
    Text: #{tweet_text}#{media_info}
    URL: #{url}
    """

    details = %{
      tweet_id: tweet_id,
      text: tweet_text,
      reply_to: reply_to
    }

    details = if media_path, do: Map.put(details, :media_path, media_path), else: details

    %AgentToolResult{
      content: [%TextContent{text: text_response}],
      details: details
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
