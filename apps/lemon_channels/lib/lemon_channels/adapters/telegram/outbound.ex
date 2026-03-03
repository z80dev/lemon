defmodule LemonChannels.Adapters.Telegram.Outbound do
  @moduledoc """
  Outbound message delivery for Telegram.

  Wraps the existing LemonChannels.Telegram.API for message delivery.
  """

  require Logger

  alias LemonChannels.OutboundPayload
  alias LemonChannels.Telegram.Formatter
  @telegram_media_group_max_items 10
  @default_telegram_outbound_send_delay_ms 1_000
  @default_retry_after_ms 1_000
  @default_transient_backoff_ms 500
  @max_rate_limit_retries 5
  @max_transient_retries 3

  @doc """
  Deliver an outbound payload to Telegram.
  """
  @spec deliver(OutboundPayload.t()) :: {:ok, term()} | {:error, term()}
  def deliver(%OutboundPayload{kind: :text} = payload) do
    Logger.debug(
      "Telegram outbound delivering text: chat_id=#{payload.peer.id} " <>
        "text_length=#{String.length(payload.content || "")}"
    )

    chat_id = String.to_integer(payload.peer.id)
    {text, md_opts} = format_text(payload.content, telegram_use_markdown())
    opts = build_send_opts(payload, md_opts)
    {token, api_mod} = telegram_config()

    # Use existing Telegram API if available
    if Code.ensure_loaded?(api_mod) do
      with token when is_binary(token) and token != "" <- token do
        case api_mod.send_message(token, chat_id, text, opts, nil) do
          {:ok, result} ->
            Logger.debug("Telegram outbound text sent successfully: chat_id=#{chat_id}")
            {:ok, result}

          {:error, reason} ->
            Logger.warning(
              "Telegram outbound text failed: chat_id=#{chat_id} reason=#{inspect(reason)}"
            )

            {:error, reason}
        end
      else
        _ ->
          Logger.error("Telegram outbound text failed: no bot token configured")
          {:error, :telegram_not_configured}
      end
    else
      Logger.error("Telegram outbound text failed: API module not available")
      {:error, :telegram_api_not_available}
    end
  end

  def deliver(
        %OutboundPayload{kind: :edit, content: %{message_id: message_id, text: text}} = payload
      ) do
    Logger.debug(
      "Telegram outbound editing message: chat_id=#{payload.peer.id} message_id=#{message_id}"
    )

    chat_id = String.to_integer(payload.peer.id)
    msg_id = parse_message_id(message_id)
    {formatted_text, md_opts} = format_text(text, telegram_use_markdown())
    reply_markup = extract_reply_markup(payload.meta)
    md_opts = maybe_merge_reply_markup(md_opts, reply_markup)
    {token, api_mod} = telegram_config()

    if Code.ensure_loaded?(api_mod) do
      with token when is_binary(token) and token != "" <- token do
        case api_mod.edit_message_text(token, chat_id, msg_id, formatted_text, md_opts) do
          {:ok, result} ->
            Logger.debug(
              "Telegram outbound edit successful: chat_id=#{chat_id} message_id=#{msg_id}"
            )

            {:ok, result}

          {:error, reason} ->
            Logger.warning(
              "Telegram outbound edit failed: chat_id=#{chat_id} message_id=#{msg_id} " <>
                "reason=#{inspect(reason)}"
            )

            {:error, reason}
        end
      else
        _ ->
          Logger.error("Telegram outbound edit failed: no bot token configured")
          {:error, :telegram_not_configured}
      end
    else
      Logger.error("Telegram outbound edit failed: API module not available")
      {:error, :telegram_api_not_available}
    end
  end

  def deliver(%OutboundPayload{kind: :delete, content: %{message_id: message_id}} = payload) do
    Logger.debug(
      "Telegram outbound deleting message: chat_id=#{payload.peer.id} message_id=#{message_id}"
    )

    chat_id = String.to_integer(payload.peer.id)
    msg_id = parse_message_id(message_id)
    {token, api_mod} = telegram_config()

    if Code.ensure_loaded?(api_mod) do
      with token when is_binary(token) and token != "" <- token do
        case api_mod.delete_message(token, chat_id, msg_id) do
          {:ok, result} ->
            Logger.debug(
              "Telegram outbound delete successful: chat_id=#{chat_id} message_id=#{msg_id}"
            )

            {:ok, result}

          # Telegram deleteMessage is effectively idempotent for our purposes. If the progress
          # message was already deleted (or never existed due to a race), Telegram returns 400
          # "message to delete not found". Treat as success so the Outbox won't retry.
          {:error, {:http_error, 400, body}} when is_binary(body) ->
            if telegram_delete_not_found?(body) do
              Logger.debug(
                "Telegram outbound delete message already deleted: chat_id=#{chat_id} " <>
                  "message_id=#{msg_id}"
              )

              {:ok, :already_deleted}
            else
              Logger.warning(
                "Telegram outbound delete failed: chat_id=#{chat_id} message_id=#{msg_id} " <>
                  "reason=400_bad_request"
              )

              {:error, {:http_error, 400, body}}
            end

          {:error, reason} ->
            Logger.warning(
              "Telegram outbound delete failed: chat_id=#{chat_id} message_id=#{msg_id} " <>
                "reason=#{inspect(reason)}"
            )

            {:error, reason}
        end
      else
        _ ->
          Logger.error("Telegram outbound delete failed: no bot token configured")
          {:error, :telegram_not_configured}
      end
    else
      Logger.error("Telegram outbound delete failed: API module not available")
      {:error, :telegram_api_not_available}
    end
  end

  def deliver(%OutboundPayload{kind: :file, content: content} = payload) do
    Logger.debug("Telegram outbound delivering file: chat_id=#{payload.peer.id}")

    chat_id = String.to_integer(payload.peer.id)
    {token, api_mod} = telegram_config()

    with {:ok, normalized_content} <- normalize_file_content(content) do
      if Code.ensure_loaded?(api_mod) do
        with token when is_binary(token) and token != "" <- token do
          opts = build_send_opts(payload, nil)

          file_count = length(normalized_content.files)
          Logger.debug("Telegram outbound sending #{file_count} file(s): chat_id=#{chat_id}")

          result = send_normalized_file(api_mod, token, chat_id, normalized_content, opts)

          case result do
            {:ok, _} ->
              Logger.debug("Telegram outbound file sent successfully: chat_id=#{chat_id}")

            {:error, reason} ->
              Logger.warning(
                "Telegram outbound file failed: chat_id=#{chat_id} reason=#{inspect(reason)}"
              )
          end

          result
        else
          _ ->
            Logger.error("Telegram outbound file failed: no bot token configured")
            {:error, :telegram_not_configured}
        end
      else
        Logger.error("Telegram outbound file failed: API module not available")
        {:error, :telegram_api_not_available}
      end
    else
      {:error, reason} ->
        Logger.warning(
          "Telegram outbound file normalization failed: chat_id=#{chat_id} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  def deliver(%OutboundPayload{kind: kind}) do
    Logger.error("Telegram outbound unsupported payload kind: #{inspect(kind)}")
    {:error, {:unsupported_kind, kind}}
  end

  defp build_send_opts(payload, md_opts) do
    reply_markup = extract_reply_markup(payload.meta)

    opts =
      %{}
      |> maybe_put(:reply_to_message_id, parse_optional_message_id(payload.reply_to))
      |> maybe_put(:message_thread_id, parse_optional_thread_id(payload.peer.thread_id))
      |> maybe_put(:reply_markup, reply_markup)

    case md_opts do
      nil -> opts
      m when is_map(m) -> Map.merge(opts, m)
      _ -> opts
    end
  end

  defp maybe_merge_reply_markup(nil, nil), do: nil

  defp maybe_merge_reply_markup(md_opts, nil), do: md_opts

  defp maybe_merge_reply_markup(nil, reply_markup) when is_map(reply_markup) do
    %{:reply_markup => reply_markup}
  end

  defp maybe_merge_reply_markup(md_opts, reply_markup)
       when is_map(md_opts) and is_map(reply_markup) do
    Map.put(md_opts, :reply_markup, reply_markup)
  end

  defp maybe_merge_reply_markup(md_opts, _reply_markup), do: md_opts

  defp extract_reply_markup(meta) when is_map(meta) do
    meta[:reply_markup] || meta["reply_markup"]
  rescue
    _ -> nil
  end

  defp extract_reply_markup(_), do: nil

  defp parse_message_id(id) when is_binary(id), do: String.to_integer(id)
  defp parse_message_id(id) when is_integer(id), do: id
  defp parse_optional_message_id(nil), do: nil
  defp parse_optional_message_id(id), do: parse_message_id(id)

  defp parse_optional_thread_id(nil), do: nil
  defp parse_optional_thread_id(id) when is_binary(id), do: String.to_integer(id)
  defp parse_optional_thread_id(id) when is_integer(id), do: id

  defp format_text(text, true) do
    normalized = normalize_text(text)
    Formatter.prepare_for_telegram(normalized)
  end

  defp format_text(text, _use_markdown) do
    {normalize_text(text), nil}
  end

  defp normalize_text(text) when is_binary(text), do: text
  defp normalize_text(nil), do: ""
  defp normalize_text(text), do: to_string(text)

  defp telegram_delete_not_found?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"description" => desc}} when is_binary(desc) ->
        String.contains?(String.downcase(desc), "message to delete not found")

      _ ->
        String.contains?(String.downcase(body), "message to delete not found")
    end
  end

  defp normalize_file_content(%{} = content) do
    files = Map.get(content, :files) || Map.get(content, "files")

    case files do
      list when is_list(list) ->
        normalize_file_batch_content(list)

      nil ->
        normalize_single_file_content(content)

      _ ->
        {:error, :invalid_file_payload}
    end
  end

  defp normalize_file_content(_), do: {:error, :invalid_file_payload}

  defp normalize_single_file_content(%{} = content) do
    path = Map.get(content, :path) || Map.get(content, "path")
    caption = Map.get(content, :caption) || Map.get(content, "caption")

    cond do
      not is_binary(path) or path == "" ->
        {:error, :invalid_file_payload}

      not File.regular?(path) ->
        {:error, :file_not_found}

      not (is_nil(caption) or is_binary(caption)) ->
        {:error, :invalid_file_payload}

      true ->
        {:ok, %{files: [%{path: path, caption: caption}]}}
    end
  end

  defp normalize_file_batch_content(files) when is_list(files) do
    if files == [] do
      {:error, :invalid_file_payload}
    else
      Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
        case normalize_batch_file_entry(file) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, normalized_files} ->
          {:ok, %{files: Enum.reverse(normalized_files)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp normalize_file_batch_content(_), do: {:error, :invalid_file_payload}

  defp normalize_batch_file_entry(%{} = content) do
    path = Map.get(content, :path) || Map.get(content, "path")
    caption = Map.get(content, :caption) || Map.get(content, "caption")

    cond do
      not is_binary(path) or path == "" ->
        {:error, :invalid_file_payload}

      not File.regular?(path) ->
        {:error, :file_not_found}

      not (is_nil(caption) or is_binary(caption)) ->
        {:error, :invalid_file_payload}

      true ->
        {:ok, %{path: path, caption: caption}}
    end
  end

  defp normalize_batch_file_entry(_), do: {:error, :invalid_file_payload}

  defp send_normalized_file(api_mod, token, chat_id, %{files: [file]}, opts) do
    send_file_with_retry(
      api_mod,
      token,
      chat_id,
      file.path,
      maybe_put(opts, :caption, file.caption)
    )
  end

  defp send_normalized_file(api_mod, token, chat_id, %{files: files}, opts) when is_list(files) do
    send_file_batch(api_mod, token, chat_id, files, opts)
  end

  defp send_normalized_file(_api_mod, _token, _chat_id, _content, _opts) do
    {:error, :invalid_file_payload}
  end

  defp send_file_batch(api_mod, token, chat_id, files, opts) do
    cond do
      files == [] ->
        {:error, :invalid_file_payload}

      all_image_files?(files) and function_exported?(api_mod, :send_media_group, 4) ->
        send_image_batches(api_mod, token, chat_id, files, opts)

      true ->
        send_files_sequentially(api_mod, token, chat_id, files, opts)
    end
  end

  defp send_image_batches(api_mod, token, chat_id, files, opts) do
    send_delay_ms = telegram_outbound_send_delay_ms()

    files
    |> Enum.chunk_every(@telegram_media_group_max_items)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {batch, idx}, {:ok, acc} ->
      batch_opts = maybe_remove_reply_to(opts, idx)
      maybe_delay_between_sends(idx, send_delay_ms)

      case send_media_group_with_retry(api_mod, token, chat_id, batch, batch_opts) do
        {:ok, result} ->
          {:cont, {:ok, [result | acc]}}

        {:error, _reason} ->
          # If media-group delivery is rejected by Telegram, retry this batch as
          # individual sends to preserve image delivery.
          case send_files_sequentially(api_mod, token, chat_id, batch, batch_opts) do
            {:ok, result} -> {:cont, {:ok, [result | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_files_sequentially(api_mod, token, chat_id, files, opts) do
    send_delay_ms = telegram_outbound_send_delay_ms()

    Enum.with_index(files)
    |> Enum.reduce_while({:ok, []}, fn {file, idx}, {:ok, acc} ->
      maybe_delay_between_sends(idx, send_delay_ms)

      file_opts =
        opts
        |> maybe_put(:caption, file.caption)
        |> maybe_remove_reply_to(idx)

      case send_file_with_retry(api_mod, token, chat_id, file.path, file_opts) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_media_group_with_retry(api_mod, token, chat_id, batch, opts) do
    with_retry(fn -> api_mod.send_media_group(token, chat_id, batch, opts) end)
  end

  defp send_file_with_retry(api_mod, token, chat_id, path, opts) do
    with_retry(fn -> send_file(api_mod, token, chat_id, path, opts) end)
  end

  defp with_retry(fun) when is_function(fun, 0), do: with_retry(fun, 0, 0)

  defp with_retry(fun, rate_limit_attempts, transient_attempts) when is_function(fun, 0) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        case retry_decision(reason, rate_limit_attempts, transient_attempts) do
          {:rate_limit, wait_ms} ->
            Logger.debug(
              "Telegram outbound rate limit retry #{rate_limit_attempts + 1}: waiting #{wait_ms}ms"
            )

            maybe_sleep(wait_ms)
            with_retry(fun, rate_limit_attempts + 1, transient_attempts)

          {:transient, wait_ms} ->
            Logger.debug(
              "Telegram outbound transient retry #{transient_attempts + 1}: waiting #{wait_ms}ms"
            )

            maybe_sleep(wait_ms)
            with_retry(fun, rate_limit_attempts, transient_attempts + 1)

          :stop ->
            {:error, reason}
        end
    end
  end

  defp retry_decision(reason, rate_limit_attempts, transient_attempts) do
    cond do
      rate_limited_reason?(reason) and rate_limit_attempts < @max_rate_limit_retries ->
        {:rate_limit, retry_after_ms(reason)}

      transient_reason?(reason) and transient_attempts < @max_transient_retries ->
        {:transient, transient_backoff_ms(transient_attempts)}

      true ->
        :stop
    end
  end

  defp rate_limited_reason?({:http_error, 429, _body}), do: true
  defp rate_limited_reason?(_), do: false

  defp retry_after_ms({:http_error, 429, body}) do
    body =
      case body do
        b when is_binary(b) -> b
        b when is_list(b) -> to_string(b)
        _ -> ""
      end

    case Jason.decode(body) do
      {:ok, %{"parameters" => %{"retry_after" => seconds}}} when is_number(seconds) ->
        max(trunc(seconds * 1000), @default_retry_after_ms)

      _ ->
        @default_retry_after_ms
    end
  rescue
    _ -> @default_retry_after_ms
  end

  defp retry_after_ms(_reason), do: @default_retry_after_ms

  defp transient_reason?({:http_error, status, _body}) when status >= 500 and status < 600,
    do: true

  defp transient_reason?(:timeout), do: true
  defp transient_reason?({:failed_connect, _reason}), do: true
  defp transient_reason?({:closed, _reason}), do: true
  defp transient_reason?(_), do: false

  defp transient_backoff_ms(attempt) when is_integer(attempt) and attempt >= 0 do
    multiplier = trunc(:math.pow(2, attempt))
    @default_transient_backoff_ms * max(multiplier, 1)
  end

  defp maybe_sleep(ms) when is_integer(ms) and ms > 0 do
    Process.sleep(ms)
    :ok
  end

  defp maybe_sleep(_ms), do: :ok

  defp maybe_delay_between_sends(idx, send_delay_ms) when idx > 0 do
    maybe_sleep(send_delay_ms)
  end

  defp maybe_delay_between_sends(_idx, _send_delay_ms), do: :ok

  defp send_file(api_mod, token, chat_id, path, opts) do
    cond do
      image_file?(path) and function_exported?(api_mod, :send_photo, 4) ->
        api_mod.send_photo(token, chat_id, {:path, path}, opts)

      video_file?(path) and function_exported?(api_mod, :send_video, 4) ->
        api_mod.send_video(token, chat_id, {:path, path}, opts)

      function_exported?(api_mod, :send_document, 4) ->
        api_mod.send_document(token, chat_id, {:path, path}, opts)

      true ->
        {:error, :telegram_send_document_not_available}
    end
  end

  defp maybe_remove_reply_to(opts, 0), do: opts

  defp maybe_remove_reply_to(opts, _idx) when is_map(opts) do
    opts
    |> Map.delete(:reply_to_message_id)
    |> Map.delete("reply_to_message_id")
  end

  defp maybe_remove_reply_to(opts, _idx), do: opts

  defp all_image_files?(files) when is_list(files) do
    Enum.all?(files, fn
      %{path: path} when is_binary(path) -> image_file?(path)
      _ -> false
    end)
  end

  defp telegram_outbound_send_delay_ms do
    cfg = telegram_files_config()
    raw = cfg[:outbound_send_delay_ms] || cfg["outbound_send_delay_ms"]

    case parse_non_neg_int(raw) do
      n when is_integer(n) -> n
      _ -> @default_telegram_outbound_send_delay_ms
    end
  rescue
    _ -> @default_telegram_outbound_send_delay_ms
  end

  defp image_file?(path) when is_binary(path) do
    case Path.extname(path) |> String.downcase() do
      ".png" -> true
      ".jpg" -> true
      ".jpeg" -> true
      ".gif" -> true
      ".webp" -> true
      ".bmp" -> true
      ".svg" -> true
      ".tif" -> true
      ".tiff" -> true
      ".heic" -> true
      ".heif" -> true
      _ -> false
    end
  end

  defp video_file?(path) when is_binary(path) do
    case Path.extname(path) |> String.downcase() do
      ".mp4" -> true
      ".mov" -> true
      ".webm" -> true
      ".avi" -> true
      _ -> false
    end
  end

  # Transport merges runtime overrides from `Application.get_env(:lemon_channels, :telegram)`;
  # do the same here so tests can inject a mock api module without hitting the network.
  defp telegram_config do
    config = telegram_runtime_config()
    token = config[:bot_token] || config["bot_token"]

    api_mod =
      case fetch_config(config, :api_mod) do
        {:ok, value} -> value
        :error -> LemonChannels.Telegram.API
      end
      |> normalize_api_mod()

    {token, api_mod}
  end

  defp telegram_use_markdown do
    config = telegram_runtime_config()

    case fetch_config(config, :use_markdown) do
      {:ok, nil} -> true
      {:ok, v} -> v
      :error -> true
    end
  end

  defp telegram_files_config do
    config = telegram_runtime_config()
    files = config[:files] || config["files"] || %{}
    if is_map(files), do: files, else: %{}
  end

  defp telegram_runtime_config do
    base = LemonChannels.GatewayConfig.get(:telegram, %{}) || %{}

    overrides =
      case Application.get_env(:lemon_channels, :telegram) do
        nil ->
          %{}

        m when is_map(m) ->
          m

        kw when is_list(kw) ->
          if Keyword.keyword?(kw) do
            Enum.into(kw, %{})
          else
            %{}
          end

        _ ->
          %{}
      end

    Map.merge(base, overrides)
  end

  defp fetch_config(config, key) when is_map(config) and is_atom(key) do
    case Map.fetch(config, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Map.fetch(config, Atom.to_string(key))
    end
  end

  defp parse_non_neg_int(value) when is_integer(value) and value >= 0, do: value

  defp parse_non_neg_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp parse_non_neg_int(_), do: nil

  defp normalize_api_mod(mod) when is_atom(mod), do: mod
  defp normalize_api_mod(""), do: LemonChannels.Telegram.API

  defp normalize_api_mod(mod) when is_binary(mod) do
    try do
      if String.starts_with?(mod, "Elixir.") do
        String.to_existing_atom(mod)
      else
        String.to_existing_atom("Elixir." <> mod)
      end
    rescue
      _ -> LemonChannels.Telegram.API
    end
  end

  defp normalize_api_mod(_), do: LemonChannels.Telegram.API

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
