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

  @upload_base "https://upload.twitter.com/1.1"
  # 5 MB per chunk — the X API maximum for APPEND segments
  @chunk_size 5 * 1024 * 1024

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
  Post a tweet with media attachment.

  ## Parameters

    * `text` - Tweet text content (optional, can be empty string)
    * `media_path` - Path to the media file to upload
    * `opts` - Options including:
      * `:reply_to` - Tweet ID to reply to
      * `:mime_type` - MIME type of the media (auto-detected if not provided)

  ## Returns

    * `{:ok, %{tweet_id: id, media_id: media_id}}` on success
    * `{:error, reason}` on failure
  """
  def post_with_media(text, media_path, opts \\ []) when is_binary(media_path) do
    case LemonChannels.Adapters.XAPI.auth_method() do
      :oauth1 ->
        {:error, :media_upload_not_implemented}

      :oauth2 ->
        with {:ok, token} <- get_access_token(),
             {:ok, media_data} <- read_media_file(media_path),
             mime_type <- opts[:mime_type] || detect_mime_type(media_path),
             {:ok, media_id} <- upload_media(%{data: media_data, mime_type: mime_type}, token),
             {:ok, tweet} <- build_tweet_with_media_data(text, media_id, opts[:reply_to]),
             {:ok, result} <- post_tweet(tweet, token) do
          {:ok, %{tweet_id: result["data"]["id"], media_id: media_id}}
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

  defp build_tweet_with_media_data(text, media_id, reply_to) do
    tweet =
      %{
        "text" => truncate_text(text || ""),
        "media" => %{
          "media_ids" => [media_id]
        }
      }
      |> maybe_add_reply(reply_to)

    {:ok, tweet}
  end

  defp read_media_file(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:file_read_error, reason, path}}
    end
  end

  defp detect_mime_type(path) do
    ext = path |> Path.extname() |> String.downcase()

    case ext do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".mp4" -> "video/mp4"
      ".mov" -> "video/quicktime"
      _ -> "application/octet-stream"
    end
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

  defp upload_media(%{data: data, mime_type: mime_type}, token) do
    total_bytes = byte_size(data)

    with {:ok, media_id} <- upload_init(total_bytes, mime_type, token),
         :ok <- upload_append_chunks(media_id, data, token),
         {:ok, media_id} <- upload_finalize(media_id, token) do
      {:ok, media_id}
    end
  end

  # ── Chunked upload helpers ────────────────────────────────────────────

  defp upload_init(total_bytes, mime_type, token) do
    form_body =
      URI.encode_query(%{
        "command" => "INIT",
        "total_bytes" => total_bytes,
        "media_type" => mime_type
      })

    case upload_request(:post, "#{@upload_base}/media/upload.json", token,
           body: form_body,
           content_type: "application/x-www-form-urlencoded"
         ) do
      {:ok, %{status: status, body: %{"media_id_string" => media_id}}}
      when status in [200, 201, 202] ->
        {:ok, media_id}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[XAPI] Media INIT failed: HTTP #{status} - #{inspect(body)}")
        {:error, {:upload_init_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upload_append_chunks(media_id, data, token) do
    chunks = chunk_binary(data, @chunk_size)

    chunks
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {chunk, index}, :ok ->
      case upload_append(media_id, chunk, index, token) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp upload_append(media_id, chunk, segment_index, token) do
    boundary = "----ElixirMultipart#{System.unique_integer([:positive])}"
    body = build_multipart_body(boundary, media_id, segment_index, chunk)
    content_type = "multipart/form-data; boundary=#{boundary}"

    case upload_request(:post, "#{@upload_base}/media/upload.json", token,
           body: body,
           content_type: content_type
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error(
          "[XAPI] Media APPEND (segment #{segment_index}) failed: HTTP #{status} - #{inspect(resp_body)}"
        )

        {:error, {:upload_append_failed, segment_index, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_multipart_body(boundary, media_id, segment_index, chunk) do
    parts = [
      multipart_text_field(boundary, "command", "APPEND"),
      multipart_text_field(boundary, "media_id", media_id),
      multipart_text_field(boundary, "segment_index", to_string(segment_index)),
      multipart_file_field(boundary, "media_data", chunk)
    ]

    IO.iodata_to_binary([parts, "--#{boundary}--\r\n"])
  end

  defp multipart_text_field(boundary, name, value) do
    "--#{boundary}\r\n" <>
      "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n" <>
      "#{value}\r\n"
  end

  defp multipart_file_field(boundary, name, data) do
    "--#{boundary}\r\n" <>
      "Content-Disposition: form-data; name=\"#{name}\"; filename=\"blob\"\r\n" <>
      "Content-Type: application/octet-stream\r\n\r\n" <>
      data <>
      "\r\n"
  end

  defp upload_finalize(media_id, token) do
    form_body =
      URI.encode_query(%{
        "command" => "FINALIZE",
        "media_id" => media_id
      })

    case upload_request(:post, "#{@upload_base}/media/upload.json", token,
           body: form_body,
           content_type: "application/x-www-form-urlencoded"
         ) do
      {:ok, %{status: status, body: %{"media_id_string" => finalized_id}}}
      when status in [200, 201] ->
        {:ok, finalized_id}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[XAPI] Media FINALIZE failed: HTTP #{status} - #{inspect(body)}")
        {:error, {:upload_finalize_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def chunk_binary(data, chunk_size) when is_binary(data) and is_integer(chunk_size) and chunk_size > 0 do
    do_chunk_binary(data, chunk_size, [])
  end

  defp do_chunk_binary(<<>>, _chunk_size, acc), do: Enum.reverse(acc)

  defp do_chunk_binary(data, chunk_size, acc) when byte_size(data) <= chunk_size do
    Enum.reverse([data | acc])
  end

  defp do_chunk_binary(data, chunk_size, acc) do
    <<chunk::binary-size(chunk_size), rest::binary>> = data
    do_chunk_binary(rest, chunk_size, [chunk | acc])
  end

  defp upload_request(method, url, token, opts) do
    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", opts[:content_type] || "application/x-www-form-urlencoded"}
    ]

    req_opts = [
      method: method,
      url: url,
      headers: headers,
      body: opts[:body],
      retry: false
    ]

    Req.request(req_opts)
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
