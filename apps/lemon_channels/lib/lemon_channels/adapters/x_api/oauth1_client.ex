defmodule LemonChannels.Adapters.XAPI.OAuth1Client do
  @moduledoc """
  OAuth 1.0a client for X API v2.

  Uses the simpler OAuth 1.0a User Context authentication which is
  supported for API v2 posting and is more straightforward for
  automated bot accounts.

  ## Required Credentials

  From X Developer Portal → Projects → Your App → Keys and Tokens:

    - Consumer Key (API Key)
    - Consumer Secret (API Secret)
    - Access Token (with Read/Write permissions)
    - Access Token Secret

  ## Configuration

      config :lemon_channels, LemonChannels.Adapters.XAPI,
        consumer_key: System.get_env("X_API_CONSUMER_KEY"),
        consumer_secret: System.get_env("X_API_CONSUMER_SECRET"),
        access_token: System.get_env("X_API_ACCESS_TOKEN"),
        access_token_secret: System.get_env("X_API_ACCESS_TOKEN_SECRET")

  ## References

  - https://developer.x.com/en/docs/authentication/oauth-1-0a
  - OAuth 1.0a is still supported for API v2 endpoints
  """

  require Logger

  alias LemonChannels.OutboundPayload

  @api_base "https://api.x.com/2"
  # @upload_base "https://upload.x.com/1.1"

  @doc """
  Deliver an outbound payload to X using OAuth 1.0a.
  """
  def deliver(%OutboundPayload{kind: :text} = payload) do
    with {:ok, credentials} <- get_credentials(),
         {:ok, tweet} <- build_tweet(payload),
         {:ok, result} <- post_tweet(tweet, credentials) do
      {:ok, %{tweet_id: result["data"]["id"], text: result["data"]["text"]}}
    end
  end

  def deliver(%OutboundPayload{kind: :delete} = payload) do
    with {:ok, credentials} <- get_credentials(),
         tweet_id <- get_tweet_id_from_meta(payload),
         {:ok, _result} <- delete_tweet(tweet_id, credentials) do
      {:ok, %{deleted: true, tweet_id: tweet_id}}
    end
  end

  @doc """
  Post a simple text tweet.
  """
  def post_text(text, opts \\ []) do
    with {:ok, credentials} <- get_credentials() do
      tweet =
        %{"text" => truncate_text(text)}
        |> maybe_add_reply(opts[:reply_to])

      post_tweet(tweet, credentials)
    end
  end

  @doc """
  Reply to a specific tweet.
  """
  def reply(tweet_id, text) do
    with {:ok, credentials} <- get_credentials() do
      tweet = %{
        "text" => truncate_text(text),
        "reply" => %{
          "in_reply_to_tweet_id" => tweet_id
        }
      }

      post_tweet(tweet, credentials)
    end
  end

  @doc """
  Get recent mentions for the authenticated user.
  """
  def get_mentions(opts \\ []) do
    with {:ok, credentials} <- get_credentials(),
         {:ok, user_id} <- resolve_mentions_user_id(credentials, opts),
         {:ok, mentions} <- do_get_mentions(user_id, credentials, opts) do
      {:ok, mentions}
    end
  end

  @doc """
  Delete a tweet.
  """
  def delete_tweet(tweet_id) do
    with {:ok, credentials} <- get_credentials() do
      request(:delete, "#{@api_base}/tweets/#{tweet_id}", credentials)
    end
  end

  @doc """
  Get user info for the authenticated account.
  """
  def get_me do
    with {:ok, credentials} <- get_credentials() do
      request(:get, "#{@api_base}/users/me", credentials)
    end
  end

  ## Private Functions

  defp get_credentials do
    config = LemonChannels.Adapters.XAPI.config()

    case {
      config[:consumer_key],
      config[:consumer_secret],
      config[:access_token],
      config[:access_token_secret]
    } do
      {nil, _, _, _} ->
        {:error, :missing_consumer_key}

      {_, nil, _, _} ->
        {:error, :missing_consumer_secret}

      {_, _, nil, _} ->
        {:error, :missing_access_token}

      {_, _, _, nil} ->
        {:error, :missing_access_token_secret}

      {ck, cs, at, ats} ->
        {:ok,
         %{consumer_key: ck, consumer_secret: cs, access_token: at, access_token_secret: ats}}
    end
  end

  defp build_tweet(%OutboundPayload{content: text} = payload) do
    tweet =
      %{
        "text" => truncate_text(text)
      }
      |> maybe_add_reply(payload.reply_to)

    {:ok, tweet}
  end

  defp post_tweet(tweet, credentials) do
    case request(:post, "#{@api_base}/tweets", credentials, json: tweet) do
      {:ok, %{status: 201, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[XAPI] Tweet failed: HTTP #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_tweet(tweet_id, credentials) do
    case request(:delete, "#{@api_base}/tweets/#{tweet_id}", credentials) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(method, url, credentials, opts \\ []) do
    headers = oauth_headers(method, url, credentials, opts)

    req_opts = [
      method: method,
      url: url,
      headers: headers
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

  defp do_get_mentions(user_id, credentials, opts) do
    params = [
      max_results: clamp_mentions_limit(opts[:limit]),
      "tweet.fields": "created_at,author_id,conversation_id"
    ]

    case request(:get, "#{@api_base}/users/#{user_id}/mentions", credentials, params: params) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_mentions_user_id(credentials, opts) do
    case opts[:user_id] || configured_default_account() do
      nil ->
        fetch_authenticated_user_id(credentials)

      account when is_binary(account) ->
        account = String.trim(account)

        cond do
          account == "" ->
            fetch_authenticated_user_id(credentials)

          numeric_id?(account) ->
            {:ok, account}

          true ->
            lookup_user_id_by_username(account, credentials)
        end

      account ->
        account = to_string(account)

        if numeric_id?(account) do
          {:ok, account}
        else
          lookup_user_id_by_username(account, credentials)
        end
    end
  end

  defp configured_default_account do
    config = LemonChannels.Adapters.XAPI.config()
    config[:default_account_id] || config[:default_account_username]
  end

  defp fetch_authenticated_user_id(credentials) do
    case request(:get, "#{@api_base}/users/me", credentials) do
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

  defp lookup_user_id_by_username(username, credentials) do
    encoded = URI.encode_www_form(username)

    case request(:get, "#{@api_base}/users/by/username/#{encoded}", credentials) do
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

  defp oauth_headers(method, url, credentials, opts) do
    timestamp = System.system_time(:second)
    nonce = generate_nonce()

    # Build base parameters
    base_params = %{
      "oauth_consumer_key" => credentials.consumer_key,
      "oauth_nonce" => nonce,
      "oauth_signature_method" => "HMAC-SHA1",
      "oauth_timestamp" => Integer.to_string(timestamp),
      "oauth_token" => credentials.access_token,
      "oauth_version" => "1.0"
    }

    # Add query params to signature base if present
    base_params =
      if opts[:params] do
        opts[:params]
        |> Enum.reduce(base_params, fn {k, v}, acc ->
          Map.put(acc, to_string(k), to_string(v))
        end)
      else
        base_params
      end

    # Create signature
    signature = create_signature(method, url, base_params, credentials)

    # Build Authorization header
    auth_params =
      base_params
      |> Map.put("oauth_signature", signature)
      |> Enum.map(fn {k, v} -> "#{k}=\"#{URI.encode_www_form(v)}\"" end)
      |> Enum.join(", ")

    [
      {"Authorization", "OAuth #{auth_params}"},
      {"Content-Type", "application/json"}
    ]
  end

  defp create_signature(method, url, params, credentials) do
    # Sort params by key
    sorted_params =
      params
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} -> "#{k}=#{URI.encode_www_form(v)}" end)
      |> Enum.join("&")

    # Build signature base string
    base_string =
      [
        String.upcase(to_string(method)),
        URI.encode_www_form(url),
        URI.encode_www_form(sorted_params)
      ]
      |> Enum.join("&")

    # Create signing key
    signing_key =
      "#{URI.encode_www_form(credentials.consumer_secret)}&#{URI.encode_www_form(credentials.access_token_secret)}"

    # Generate signature
    :crypto.mac(:hmac, :sha, signing_key, base_string)
    |> Base.encode64()
  end

  defp generate_nonce do
    :crypto.strong_rand_bytes(16)
    |> Base.encode64(padding: false)
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> String.slice(0, 32)
  end

  defp maybe_add_reply(tweet, nil), do: tweet

  defp maybe_add_reply(tweet, reply_to) when is_binary(reply_to) do
    Map.put(tweet, "reply", %{"in_reply_to_tweet_id" => reply_to})
  end

  defp truncate_text(text) when byte_size(text) <= 280, do: text

  defp truncate_text(text) do
    String.slice(text, 0, 277) <> "..."
  end

  defp get_tweet_id_from_meta(%OutboundPayload{meta: %{tweet_id: id}}), do: id
  defp get_tweet_id_from_meta(%OutboundPayload{meta: %{"tweet_id" => id}}), do: id
  defp get_tweet_id_from_meta(_), do: nil
end
