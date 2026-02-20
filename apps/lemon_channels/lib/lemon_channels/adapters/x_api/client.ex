defmodule LemonChannels.Adapters.XAPI.Client do
  @moduledoc """
  HTTP client for X API v2.

  Handles:
  - Tweet posting
  - Tweet deletion
  - Media uploads (images)
  - Reply threading
  - Rate limit handling with exponential backoff

  Supports both OAuth 2.0 and OAuth 1.0a authentication.
  """

  require Logger

  alias LemonChannels.OutboundPayload

  @api_base "https://api.x.com/2"
  @max_retries 3
  @base_backoff_ms 1000

  @doc """
  Deliver an outbound payload to X.
  """
  def deliver(%OutboundPayload{kind: :text} = payload) do
    case LemonChannels.Adapters.XAPI.auth_method() do
      :oauth1 ->
        LemonChannels.Adapters.XAPI.OAuth1Client.deliver(payload)

      :oauth2 ->
        with {:ok, token} <- get_access_token(),
             {:ok, tweet} <- build_tweet(payload),
             {:ok, result} <- post_tweet(tweet, token) do
          {:ok, %{tweet_id: result["data"]["id"], text: result["data"]["text"]}}
        end
    end
  end

  def deliver(%OutboundPayload{kind: :edit} = _payload) do
    # X API v2 doesn't support editing tweets via API
    {:error, :edit_not_supported}
  end

  def deliver(%OutboundPayload{kind: :delete} = payload) do
    case LemonChannels.Adapters.XAPI.auth_method() do
      :oauth1 ->
        LemonChannels.Adapters.XAPI.OAuth1Client.deliver(payload)

      :oauth2 ->
        with {:ok, token} <- get_access_token(),
             tweet_id <- get_tweet_id_from_meta(payload),
             {:ok, _result} <- do_delete_tweet(tweet_id, token) do
          {:ok, %{deleted: true, tweet_id: tweet_id}}
        end
    end
  end

  def deliver(%OutboundPayload{kind: :file} = payload) do
    case LemonChannels.Adapters.XAPI.auth_method() do
      :oauth1 ->
        # OAuth 1.0a handles media differently
        {:error, :media_upload_not_implemented}

      :oauth2 ->
        with {:ok, token} <- get_access_token(),
             {:ok, media_id} <- upload_media(payload.content, token),
             {:ok, tweet} <- build_tweet_with_media(payload, media_id),
             {:ok, result} <- post_tweet(tweet, token) do
          {:ok, %{tweet_id: result["data"]["id"], media_id: media_id}}
        end
    end
  end

  @doc """
  Post a simple text tweet.
  """
  def post_text(text, opts \\ []) do
    case LemonChannels.Adapters.XAPI.auth_method() do
      :oauth1 ->
        LemonChannels.Adapters.XAPI.OAuth1Client.post_text(text, opts)

      :oauth2 ->
        with {:ok, token} <- get_access_token() do
          tweet =
            %{
              "text" => truncate_text(text)
            }
            |> maybe_add_reply(opts[:reply_to])
            |> maybe_add_poll(opts[:poll])

          post_tweet(tweet, token)
        end
    end
  end

  @doc """
  Reply to a specific tweet.
  """
  def reply(tweet_id, text) do
    case LemonChannels.Adapters.XAPI.auth_method() do
      :oauth1 ->
        LemonChannels.Adapters.XAPI.OAuth1Client.reply(tweet_id, text)

      :oauth2 ->
        with {:ok, token} <- get_access_token() do
          tweet = %{
            "text" => truncate_text(text),
            "reply" => %{
              "in_reply_to_tweet_id" => tweet_id
            }
          }

          post_tweet(tweet, token)
        end
    end
  end

  @doc """
  Get recent mentions for the authenticated user.
  """
  def get_mentions(opts \\ []) do
    case LemonChannels.Adapters.XAPI.auth_method() do
      :oauth1 ->
        LemonChannels.Adapters.XAPI.OAuth1Client.get_mentions(opts)

      :oauth2 ->
        with {:ok, token} <- get_access_token(),
             {:ok, user_id} <- resolve_mentions_user_id(token, opts),
             {:ok, mentions} <- do_get_mentions(user_id, token, opts) do
          {:ok, mentions}
        end
    end
  end

  @doc """
  Delete a tweet.
  """
  def delete_tweet(tweet_id) do
    case LemonChannels.Adapters.XAPI.auth_method() do
      :oauth1 ->
        LemonChannels.Adapters.XAPI.OAuth1Client.delete_tweet(tweet_id)

      :oauth2 ->
        with {:ok, token} <- get_access_token() do
          do_delete_tweet(tweet_id, token)
        end
    end
  end

  ## Private Functions

  defp get_access_token do
    LemonChannels.Adapters.XAPI.TokenManager.get_access_token()
  end

  defp build_tweet(%OutboundPayload{content: text} = payload) do
    tweet =
      %{
        "text" => truncate_text(text)
      }
      |> maybe_add_reply(payload.reply_to)

    {:ok, tweet}
  end

  defp build_tweet_with_media(%OutboundPayload{} = payload, media_id) do
    tweet =
      %{
        "text" => truncate_text(payload.content[:text] || ""),
        "media" => %{
          "media_ids" => [media_id]
        }
      }
      |> maybe_add_reply(payload.reply_to)

    {:ok, tweet}
  end

  defp post_tweet(tweet, token, attempt \\ 1) do
    case request(:post, "#{@api_base}/tweets", token, json: tweet) do
      {:ok, %{status: 201, body: body}} ->
        {:ok, body}

      {:ok, %{status: 429, headers: headers}} ->
        if attempt < @max_retries do
          retry_after = get_retry_after(headers) || @base_backoff_ms * :math.pow(2, attempt)

          Logger.warning(
            "[XAPI] Rate limited, retrying in #{trunc(retry_after)}ms (attempt #{attempt})"
          )

          Process.sleep(trunc(retry_after))
          post_tweet(tweet, token, attempt + 1)
        else
          {:error, :rate_limited}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("[XAPI] Tweet failed: HTTP #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_delete_tweet(tweet_id, token) do
    case request(:delete, "#{@api_base}/tweets/#{tweet_id}", token) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upload_media(%{data: _data, mime_type: _mime_type}, _token) do
    # X API v2 media upload is complex - requires INIT, APPEND, FINALIZE
    # For now, return error indicating manual upload needed
    # TODO: Implement chunked media upload
    {:error, :media_upload_not_implemented}
  end

  defp request(method, url, token, opts \\ []) do
    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    req_opts = [
      method: method,
      url: url,
      headers: headers,
      retry: false
    ]

    req_opts =
      if opts[:json] do
        Keyword.put(req_opts, :json, opts[:json])
      else
        req_opts
      end

    req_opts =
      if opts[:params] do
        Keyword.put(req_opts, :params, opts[:params])
      else
        req_opts
      end

    Req.request(req_opts)
  end

  defp do_get_mentions(user_id, token, opts) do
    params = [
      max_results: clamp_mentions_limit(opts[:limit]),
      "tweet.fields": "created_at,author_id,conversation_id"
    ]

    case request(:get, "#{@api_base}/users/#{user_id}/mentions", token, params: params) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_mentions_user_id(token, opts) do
    case opts[:user_id] || configured_default_account() do
      nil ->
        fetch_authenticated_user_id(token)

      account when is_binary(account) ->
        account = String.trim(account)

        cond do
          account == "" ->
            fetch_authenticated_user_id(token)

          numeric_id?(account) ->
            {:ok, account}

          true ->
            lookup_user_id_by_username(account, token)
        end

      account ->
        account = to_string(account)

        if numeric_id?(account) do
          {:ok, account}
        else
          lookup_user_id_by_username(account, token)
        end
    end
  end

  defp configured_default_account do
    config = LemonChannels.Adapters.XAPI.config()
    config[:default_account_id] || config[:default_account_username]
  end

  defp fetch_authenticated_user_id(token) do
    case request(:get, "#{@api_base}/users/me", token) do
      {:ok, %{status: 200, body: %{"data" => %{"id" => user_id}}}} ->
        {:ok, user_id}

      {:ok, %{status: 200, body: body}} ->
        {:error, {:invalid_response, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup_user_id_by_username(username, token) do
    encoded = URI.encode_www_form(username)

    case request(:get, "#{@api_base}/users/by/username/#{encoded}", token) do
      {:ok, %{status: 200, body: %{"data" => %{"id" => user_id}}}} ->
        {:ok, user_id}

      {:ok, %{status: 200, body: body}} ->
        {:error, {:invalid_response, body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp numeric_id?(value) when is_binary(value) do
    value != "" and Regex.match?(~r/^\d+$/, value)
  end

  defp clamp_mentions_limit(nil), do: 10

  defp clamp_mentions_limit(limit) when is_integer(limit) do
    limit
    |> max(5)
    |> min(100)
  end

  defp clamp_mentions_limit(limit) when is_binary(limit) do
    case Integer.parse(String.trim(limit)) do
      {parsed, ""} -> clamp_mentions_limit(parsed)
      _ -> 10
    end
  end

  defp clamp_mentions_limit(_), do: 10

  defp maybe_add_reply(tweet, nil), do: tweet

  defp maybe_add_reply(tweet, reply_to) when is_binary(reply_to) do
    Map.put(tweet, "reply", %{"in_reply_to_tweet_id" => reply_to})
  end

  defp maybe_add_poll(tweet, nil), do: tweet

  defp maybe_add_poll(tweet, poll_opts) do
    Map.put(tweet, "poll", %{
      "options" => poll_opts[:options] || [],
      "duration_minutes" => poll_opts[:duration] || 1440
    })
  end

  defp truncate_text(text) when byte_size(text) <= 280, do: text

  defp truncate_text(text) do
    String.slice(text, 0, 277) <> "..."
  end

  defp get_tweet_id_from_meta(%OutboundPayload{meta: %{tweet_id: id}}), do: id
  defp get_tweet_id_from_meta(%OutboundPayload{meta: %{"tweet_id" => id}}), do: id
  defp get_tweet_id_from_meta(_), do: nil

  defp get_retry_after(headers) do
    case List.keyfind(headers, "x-rate-limit-reset", 0) do
      {_, reset_time} ->
        reset_unix = String.to_integer(reset_time)
        now_unix = System.system_time(:second)
        max((reset_unix - now_unix) * 1000, 1000)

      nil ->
        nil
    end
  end
end
