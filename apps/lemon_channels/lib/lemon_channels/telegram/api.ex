defmodule LemonChannels.Telegram.API do
  @moduledoc false

  @default_timeout 10_000

  def get_updates(token, offset, timeout_ms) do
    # `timeout_ms` is passed in from polling transports. Historically it has been wired to the
    # poll interval (often 1s), which is too low for TLS handshake / transient network hiccups and
    # results in silent "no replies" behavior. Clamp to a sane minimum for the HTTP request timeout.
    timeout_ms =
      cond do
        is_integer(timeout_ms) and timeout_ms > 0 -> max(timeout_ms, @default_timeout)
        true -> @default_timeout
      end

    params = %{
      "offset" => offset,
      "timeout" => 0
    }

    request(token, "getUpdates", params, timeout_ms)
  end

  def get_me(token) do
    request(token, "getMe", %{}, @default_timeout)
  end

  def delete_webhook(token, opts \\ %{}) do
    opts = if is_map(opts), do: opts, else: Enum.into(opts, %{})

    params =
      %{}
      |> maybe_put(
        "drop_pending_updates",
        opts[:drop_pending_updates] || opts["drop_pending_updates"]
      )

    request(token, "deleteWebhook", params, @default_timeout)
  end

  def get_chat_member(token, chat_id, user_id) do
    params = %{
      "chat_id" => chat_id,
      "user_id" => user_id
    }

    request(token, "getChatMember", params, @default_timeout)
  end

  def send_message(token, chat_id, text, reply_to_or_opts \\ nil, parse_mode \\ nil)

  def send_message(token, chat_id, text, reply_to_or_opts, parse_mode)
      when is_map(reply_to_or_opts) or is_list(reply_to_or_opts) do
    opts =
      if is_map(reply_to_or_opts), do: reply_to_or_opts, else: Enum.into(reply_to_or_opts, %{})

    params =
      %{
        "chat_id" => chat_id,
        "text" => text,
        "disable_web_page_preview" => true
      }
      |> maybe_put(
        "reply_to_message_id",
        opts[:reply_to_message_id] || opts["reply_to_message_id"]
      )
      |> maybe_put("message_thread_id", opts[:message_thread_id] || opts["message_thread_id"])
      |> maybe_put("parse_mode", opts[:parse_mode] || opts["parse_mode"] || parse_mode)
      |> maybe_put("entities", opts[:entities] || opts["entities"])
      |> maybe_put("reply_markup", opts[:reply_markup] || opts["reply_markup"])

    request(token, "sendMessage", params, @default_timeout)
  end

  def send_message(token, chat_id, text, reply_to_message_id, parse_mode) do
    params =
      %{
        "chat_id" => chat_id,
        "text" => text,
        "disable_web_page_preview" => true
      }
      |> maybe_put("reply_to_message_id", reply_to_message_id)
      |> maybe_put("parse_mode", parse_mode)

    request(token, "sendMessage", params, @default_timeout)
  end

  def edit_message_text(token, chat_id, message_id, text, parse_mode_or_opts \\ nil)

  def edit_message_text(token, chat_id, message_id, text, parse_mode_or_opts)
      when is_map(parse_mode_or_opts) or is_list(parse_mode_or_opts) do
    opts =
      if is_map(parse_mode_or_opts),
        do: parse_mode_or_opts,
        else: Enum.into(parse_mode_or_opts, %{})

    params =
      %{
        "chat_id" => chat_id,
        "message_id" => message_id,
        "text" => text,
        "disable_web_page_preview" => true
      }
      |> maybe_put("parse_mode", opts[:parse_mode] || opts["parse_mode"])
      |> maybe_put("entities", opts[:entities] || opts["entities"])
      |> maybe_put("reply_markup", opts[:reply_markup] || opts["reply_markup"])

    request(token, "editMessageText", params, @default_timeout)
  end

  def edit_message_text(token, chat_id, message_id, text, parse_mode) do
    params =
      %{
        "chat_id" => chat_id,
        "message_id" => message_id,
        "text" => text,
        "disable_web_page_preview" => true
      }
      |> maybe_put("parse_mode", parse_mode)

    request(token, "editMessageText", params, @default_timeout)
  end

  def answer_callback_query(token, callback_query_id, opts \\ %{}) do
    opts = if is_map(opts), do: opts, else: Enum.into(opts, %{})

    params =
      %{
        "callback_query_id" => callback_query_id
      }
      |> maybe_put("text", opts[:text] || opts["text"])
      |> maybe_put("show_alert", opts[:show_alert] || opts["show_alert"])

    request(token, "answerCallbackQuery", params, @default_timeout)
  end

  def delete_message(token, chat_id, message_id) do
    params = %{
      "chat_id" => chat_id,
      "message_id" => message_id
    }

    request(token, "deleteMessage", params, @default_timeout)
  end

  @doc """
  Set a reaction emoji on a message.

  `emoji` should be a single emoji character (e.g., "👀", "✅", "❌").
  Setting `emoji` to nil or an empty string removes all reactions.
  """
  def set_message_reaction(token, chat_id, message_id, emoji, opts \\ %{}) do
    opts = if is_map(opts), do: opts, else: Enum.into(opts, %{})

    # Build reaction array - empty array removes reactions
    reaction =
      if is_binary(emoji) and emoji != "" do
        [%{"type" => "emoji", "emoji" => emoji}]
      else
        []
      end

    params =
      %{
        "chat_id" => chat_id,
        "message_id" => message_id,
        "reaction" => reaction
      }
      |> maybe_put("is_big", opts[:is_big] || opts["is_big"])

    request(token, "setMessageReaction", params, @default_timeout)
  end

  def get_file(token, file_id) when is_binary(file_id) do
    params = %{"file_id" => file_id}
    request(token, "getFile", params, @default_timeout)
  end

  def download_file(token, file_path) when is_binary(file_path) do
    url = "https://api.telegram.org/file/bot#{token}/#{file_path}"
    headers = []
    opts = [timeout: 30_000, connect_timeout: 30_000]

    case LemonCore.Httpc.request(:get, {to_charlist(url), headers}, opts, body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _headers, body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Send a document (file) to Telegram.

  `file` may be:
  - `{:path, "/abs/path/to/file"}`
  - `{:binary, "filename.ext", "application/octet-stream", <<bytes>>}`
  """
  def send_document(token, chat_id, file, opts \\ %{}) do
    opts = if is_map(opts), do: opts, else: Enum.into(opts, %{})

    boundary = build_boundary("lemon-doc")

    {body, content_type} =
      build_media_multipart(boundary, chat_id, "document", file, opts, "application/octet-stream")

    url = "https://api.telegram.org/bot#{token}/sendDocument"
    headers = [{~c"content-type", to_charlist(content_type)}]
    http_opts = [timeout: 60_000, connect_timeout: 30_000]

    case LemonCore.Httpc.request(
           :post,
           {to_charlist(url), headers, to_charlist(content_type), body},
           http_opts,
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, resp_body}} ->
        Jason.decode(resp_body)

      {:ok, {{_, status, _}, _headers, resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Send a photo to Telegram.

  `file` may be:
  - `{:path, "/abs/path/to/image.png"}`
  - `{:binary, "image.png", "image/png", <<bytes>>}`
  """
  def send_photo(token, chat_id, file, opts \\ %{}) do
    opts = if is_map(opts), do: opts, else: Enum.into(opts, %{})

    boundary = build_boundary("lemon-photo")

    {body, content_type} =
      build_media_multipart(boundary, chat_id, "photo", file, opts, "image/png")

    url = "https://api.telegram.org/bot#{token}/sendPhoto"
    headers = [{~c"content-type", to_charlist(content_type)}]
    http_opts = [timeout: 60_000, connect_timeout: 30_000]

    case LemonCore.Httpc.request(
           :post,
           {to_charlist(url), headers, to_charlist(content_type), body},
           http_opts,
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, resp_body}} ->
        Jason.decode(resp_body)

      {:ok, {{_, status, _}, _headers, resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Send a photo media group to Telegram.

  `files` is a list of maps with:
  - `path` (required)
  - `caption` (optional)
  """
  def send_media_group(token, chat_id, files, opts \\ %{})

  def send_media_group(token, chat_id, files, opts) when is_list(files) do
    opts = if is_map(opts), do: opts, else: Enum.into(opts, %{})

    with {:ok, normalized_files} <- normalize_media_group_files(files) do
      boundary = build_boundary("lemon-media-group")

      {body, content_type} =
        build_media_group_multipart(boundary, chat_id, normalized_files, opts)

      url = "https://api.telegram.org/bot#{token}/sendMediaGroup"
      headers = [{~c"content-type", to_charlist(content_type)}]
      http_opts = [timeout: 60_000, connect_timeout: 30_000]

      case LemonCore.Httpc.request(
             :post,
             {to_charlist(url), headers, to_charlist(content_type), body},
             http_opts,
             body_format: :binary
           ) do
        {:ok, {{_, 200, _}, _headers, resp_body}} ->
          Jason.decode(resp_body)

        {:ok, {{_, status, _}, _headers, resp_body}} ->
          {:error, {:http_error, status, resp_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def send_media_group(_token, _chat_id, _files, _opts), do: {:error, :invalid_media_group}

  defp build_boundary(prefix) when is_binary(prefix) do
    "----" <> prefix <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp normalize_media_group_files(files) when is_list(files) do
    if files == [] do
      {:error, :invalid_media_group}
    else
      Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
        case normalize_media_group_file(file) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp normalize_media_group_files(_), do: {:error, :invalid_media_group}

  defp normalize_media_group_file(%{} = file) do
    path = Map.get(file, :path) || Map.get(file, "path")
    caption = Map.get(file, :caption) || Map.get(file, "caption")

    cond do
      not is_binary(path) or path == "" ->
        {:error, :invalid_media_group}

      not File.regular?(path) ->
        {:error, :file_not_found}

      not (is_nil(caption) or is_binary(caption)) ->
        {:error, :invalid_media_group}

      true ->
        {:ok, %{path: path, caption: caption}}
    end
  end

  defp normalize_media_group_file(_), do: {:error, :invalid_media_group}

  defp build_media_group_multipart(boundary, chat_id, files, opts) do
    boundary_line = "--" <> boundary <> "\r\n"
    end_boundary = "--" <> boundary <> "--\r\n"

    media_entries =
      files
      |> Enum.with_index()
      |> Enum.map(fn {%{path: path, caption: caption}, idx} ->
        attachment = "media#{idx}"

        media =
          %{
            "type" => "photo",
            "media" => "attach://#{attachment}"
          }
          |> maybe_put("caption", caption)

        %{attachment: attachment, path: path, media: media}
      end)

    media_json = Jason.encode!(Enum.map(media_entries, & &1.media))

    parts = []

    parts =
      parts ++
        [
          boundary_line,
          "Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n",
          to_string(chat_id),
          "\r\n"
        ]

    parts =
      case opts[:reply_to_message_id] || opts["reply_to_message_id"] do
        nil ->
          parts

        v ->
          parts ++
            [
              boundary_line,
              "Content-Disposition: form-data; name=\"reply_to_message_id\"\r\n\r\n",
              to_string(v),
              "\r\n"
            ]
      end

    parts =
      case opts[:message_thread_id] || opts["message_thread_id"] do
        nil ->
          parts

        v ->
          parts ++
            [
              boundary_line,
              "Content-Disposition: form-data; name=\"message_thread_id\"\r\n\r\n",
              to_string(v),
              "\r\n"
            ]
      end

    parts =
      parts ++
        [
          boundary_line,
          "Content-Disposition: form-data; name=\"media\"\r\n\r\n",
          media_json,
          "\r\n"
        ]

    parts =
      parts ++
        Enum.flat_map(media_entries, fn %{attachment: attachment, path: path} ->
          filename = Path.basename(path)
          mime_type = mime_type_for_path(path, "image/png")
          bytes = File.read!(path)

          [
            boundary_line,
            "Content-Disposition: form-data; name=\"",
            attachment,
            "\"; filename=\"",
            filename,
            "\"\r\n",
            "Content-Type: ",
            mime_type,
            "\r\n\r\n",
            bytes,
            "\r\n"
          ]
        end)

    parts = parts ++ [end_boundary]

    {IO.iodata_to_binary(parts), "multipart/form-data; boundary=#{boundary}"}
  end

  defp build_media_multipart(boundary, chat_id, field_name, file, opts, default_mime) do
    boundary_line = "--" <> boundary <> "\r\n"
    end_boundary = "--" <> boundary <> "--\r\n"

    parts = []

    parts =
      parts ++
        [
          boundary_line,
          "Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n",
          to_string(chat_id),
          "\r\n"
        ]

    parts =
      case opts[:reply_to_message_id] || opts["reply_to_message_id"] do
        nil ->
          parts

        v ->
          parts ++
            [
              boundary_line,
              "Content-Disposition: form-data; name=\"reply_to_message_id\"\r\n\r\n",
              to_string(v),
              "\r\n"
            ]
      end

    parts =
      case opts[:message_thread_id] || opts["message_thread_id"] do
        nil ->
          parts

        v ->
          parts ++
            [
              boundary_line,
              "Content-Disposition: form-data; name=\"message_thread_id\"\r\n\r\n",
              to_string(v),
              "\r\n"
            ]
      end

    parts =
      case opts[:caption] || opts["caption"] do
        nil ->
          parts

        v when is_binary(v) and v != "" ->
          parts ++
            [
              boundary_line,
              "Content-Disposition: form-data; name=\"caption\"\r\n\r\n",
              v,
              "\r\n"
            ]

        _ ->
          parts
      end

    {filename, mime_type, bytes} =
      case file do
        {:path, path} when is_binary(path) ->
          {Path.basename(path), mime_type_for_path(path, default_mime), File.read!(path)}

        {:binary, name, ct, b} when is_binary(name) and is_binary(ct) and is_binary(b) ->
          {name, ct, b}

        _ ->
          {"file.bin", default_mime, ""}
      end

    parts =
      parts ++
        [
          boundary_line,
          "Content-Disposition: form-data; name=\"",
          field_name,
          "\"; filename=\"",
          filename,
          "\"\r\n",
          "Content-Type: ",
          mime_type,
          "\r\n\r\n",
          bytes,
          "\r\n",
          end_boundary
        ]

    {IO.iodata_to_binary(parts), "multipart/form-data; boundary=#{boundary}"}
  end

  defp mime_type_for_path(path, default_mime) when is_binary(path) and is_binary(default_mime) do
    case Path.extname(path) |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".bmp" -> "image/bmp"
      ".svg" -> "image/svg+xml"
      _ -> default_mime
    end
  end

  defp request(token, method, params, timeout_ms) do
    url = "https://api.telegram.org/bot#{token}/#{method}"
    body = Jason.encode!(params)

    headers = [
      {~c"content-type", ~c"application/json"}
    ]

    opts = [timeout: timeout_ms, connect_timeout: timeout_ms]

    case LemonCore.Httpc.request(
           :post,
           {to_charlist(url), headers, ~c"application/json", body},
           opts,
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, response_body}} ->
        Jason.decode(response_body)

      {:ok, {{_, status, _}, _headers, response_body}} ->
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
