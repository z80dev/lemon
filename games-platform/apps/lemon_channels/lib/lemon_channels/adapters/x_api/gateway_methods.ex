defmodule LemonChannels.Adapters.XAPI.GatewayMethods do
  @moduledoc """
  Control plane gateway methods for X API integration.

  These methods are exposed via the Lemon gateway for agents to call.
  """

  require Logger

  alias LemonChannels.Adapters.XAPI.Client

  @doc """
  Post a tweet.

  ## Parameters
    - text: The tweet content (max 280 chars)
    - opts: Optional parameters
      - reply_to: Tweet ID to reply to
      - poll: Poll options %{options: ["Yes", "No"], duration: 1440}

  ## Returns
    - {:ok, %{tweet_id: id, text: text}}
    - {:error, reason}
  """
  def post_tweet(%{"text" => text} = params) do
    opts =
      [
        reply_to: params["reply_to"],
        poll: params["poll"]
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    case Client.post_text(text, opts) do
      {:ok, %{"data" => data}} ->
        {:ok,
         %{
           tweet_id: data["id"],
           text: data["text"],
           created_at: data["created_at"]
         }}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def post_tweet(_), do: {:error, "Missing required parameter: text"}

  @doc """
  Get recent mentions for the authenticated account.

  ## Parameters
    - limit: Maximum number of mentions to fetch (default: 10, max: 100)

  ## Returns
    - {:ok, [%{id: id, text: text, author_id: id, created_at: time}]}
  """
  def get_mentions(params \\ %{}) do
    limit = normalize_mentions_limit(params["limit"])

    case Client.get_mentions(limit: limit) do
      {:ok, %{"data" => mentions, "includes" => includes}} ->
        users =
          Map.get(includes, "users", [])
          |> Map.new(fn u -> {u["id"], u} end)

        formatted =
          Enum.map(mentions, fn m ->
            author = Map.get(users, m["author_id"], %{})

            %{
              id: m["id"],
              text: m["text"],
              author_id: m["author_id"],
              author_username: author["username"],
              author_name: author["name"],
              created_at: m["created_at"],
              conversation_id: m["conversation_id"]
            }
          end)

        {:ok, formatted}

      {:ok, %{"data" => mentions}} ->
        formatted =
          Enum.map(mentions, fn m ->
            %{
              id: m["id"],
              text: m["text"],
              author_id: m["author_id"],
              created_at: m["created_at"],
              conversation_id: m["conversation_id"]
            }
          end)

        {:ok, formatted}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp normalize_mentions_limit(nil), do: 10

  defp normalize_mentions_limit(limit) when is_integer(limit) do
    limit
    |> max(5)
    |> min(100)
  end

  defp normalize_mentions_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} -> normalize_mentions_limit(parsed)
      _ -> 10
    end
  end

  defp normalize_mentions_limit(_), do: 10

  @doc """
  Reply to a specific tweet.

  ## Parameters
    - tweet_id: The ID of the tweet to reply to
    - text: The reply content

  ## Returns
    - {:ok, %{tweet_id: id, text: text}}
  """
  def reply_to_tweet(%{"tweet_id" => tweet_id, "text" => text}) do
    case Client.reply(tweet_id, text) do
      {:ok, %{"data" => data}} ->
        {:ok,
         %{
           tweet_id: data["id"],
           text: data["text"],
           created_at: data["created_at"]
         }}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def reply_to_tweet(%{"tweet_id" => _}), do: {:error, "Missing required parameter: text"}
  def reply_to_tweet(%{"text" => _}), do: {:error, "Missing required parameter: tweet_id"}
  def reply_to_tweet(_), do: {:error, "Missing required parameters: tweet_id and text"}

  @doc """
  Delete a tweet.

  ## Parameters
    - tweet_id: The ID of the tweet to delete

  ## Returns
    - {:ok, %{deleted: true}}
  """
  def delete_tweet(%{"tweet_id" => tweet_id}) do
    case Client.delete_tweet(tweet_id) do
      {:ok, _} ->
        {:ok, %{deleted: true, tweet_id: tweet_id}}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def delete_tweet(_), do: {:error, "Missing required parameter: tweet_id"}

  @doc """
  Get the current token status (for debugging).
  """
  def token_status(_) do
    case LemonChannels.Adapters.XAPI.TokenManager.get_state() do
      {:ok, state} ->
        {:ok,
         %{
           has_access_token: not is_nil(state.access_token),
           has_refresh_token: not is_nil(state.refresh_token),
           expires_at: state.expires_at,
           token_type: state.token_type
         }}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
