defmodule LemonChannels.Adapters.Telegram.Renderer do
  @moduledoc """
  Telegram renderer for semantic delivery intents.
  """

  alias LemonChannels.Adapters.Telegram.{FileBatcher, StatusRenderer}
  alias LemonChannels.{GatewayConfig, OutboundPayload, Outbox, PresentationState}
  alias LemonChannels.Telegram.{ResumeIndexStore, Truncate}
  alias LemonCore.{DeliveryIntent, DeliveryRoute, ResumeToken}

  @default_max_download_bytes 50 * 1024 * 1024

  @spec dispatch(DeliveryIntent.t()) :: :ok | {:error, term()}
  def dispatch(%DeliveryIntent{} = intent) do
    case intent.kind do
      kind
      when kind in [
             :stream_snapshot,
             :stream_finalize,
             :tool_status_snapshot,
             :tool_status_finalize,
             :final_text,
             :watchdog_prompt
           ] ->
        dispatch_text(intent)

      :file_batch ->
        dispatch_files(intent)

      _ ->
        :ok
    end
  end

  defp dispatch_text(%DeliveryIntent{route: %DeliveryRoute{} = route} = intent) do
    with {:ok, text} <- extract_text(intent),
         surface <- surface_for(intent),
         seq <- extract_seq(intent),
         chunks <- normalize_text(intent, text),
         state <- PresentationState.get(route, intent.run_id, surface),
         text_hash = text_hash({chunks, status_reply_markup(intent)}) do
      if duplicate?(state, seq, text_hash) do
        :ok
      else
        case send_text_chunks(intent, route, state, surface, seq, text_hash, chunks) do
          :ok ->
            maybe_dispatch_auto_send_files(intent)

          other ->
            other
        end
      end
    end
  end

  # Send the first chunk through the normal edit/create flow, then send
  # any additional chunks as separate new messages.
  defp send_text_chunks(intent, route, state, surface, seq, text_hash, [single]) do
    send_text(intent, route, state, surface, seq, text_hash, single)
  end

  defp send_text_chunks(intent, route, state, surface, _seq, text_hash, [first | rest]) do
    reply_markup = status_reply_markup(intent)
    meta = intent_meta(intent, reply_markup)

    # When a message create is pending, we must defer ALL chunks together
    # to avoid follow-ups arriving before the first chunk is created.
    if is_reference(state.pending_create_ref) do
      full_text = Enum.join([first | rest], "\n")
      seq = extract_seq(intent)
      PresentationState.defer_text(route, intent.run_id, surface, full_text, seq, text_hash, meta)
      :ok
    else
      # Send the first chunk via the normal edit/create flow
      case send_text_single(intent, route, state, surface, text_hash, first, meta) do
        :ok ->
          # Send remaining chunks as follow-up messages (no reply_to, no status markup)
          send_followup_chunks(intent, route, rest, meta)

        other ->
          other
      end
    end
  end

  # Backward-compat: single-chunk path (same as original send_text)
  defp send_text(intent, route, state, surface, _seq, text_hash, text) do
    reply_markup = status_reply_markup(intent)
    meta = intent_meta(intent, reply_markup)
    send_text_single(intent, route, state, surface, text_hash, text, meta)
  end

  defp send_text_single(intent, route, state, surface, text_hash, text, meta) do
    seq = extract_seq(intent)

    cond do
      present_message_id?(state.platform_message_id) ->
        payload =
          OutboundPayload.edit(
            "telegram",
            route.account_id,
            peer(route),
            to_string(state.platform_message_id),
            text,
            idempotency_key: intent.intent_id,
            meta: meta
          )

        case Outbox.enqueue(payload) do
          {:ok, _ref} ->
            PresentationState.mark_sent(
              route,
              intent.run_id,
              surface,
              seq,
              text_hash,
              state.platform_message_id
            )

            maybe_index_resume(intent, route, state.platform_message_id)
            :ok

          {:error, :duplicate} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      is_reference(state.pending_create_ref) ->
        PresentationState.defer_text(route, intent.run_id, surface, text, seq, text_hash, meta)
        :ok

      true ->
        notify_ref = make_ref()

        # Register the pending ref BEFORE enqueueing so that the delivery
        # notification (which may arrive quickly) finds the ref in
        # PresentationState instead of being silently dropped.
        PresentationState.register_pending_create(
          route,
          intent.run_id,
          surface,
          notify_ref,
          seq,
          text_hash,
          pending_resume(intent)
        )

        payload =
          OutboundPayload.text(
            "telegram",
            route.account_id,
            peer(route),
            text,
            idempotency_key: intent.intent_id,
            reply_to: optional_reply_to(intent),
            meta: Map.put(meta, :notify_tag, PresentationState.notify_tag()),
            notify_pid: Process.whereis(PresentationState),
            notify_ref: notify_ref
          )

        case Outbox.enqueue(payload) do
          {:ok, _ref} ->
            :ok

          {:error, :duplicate} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Send follow-up chunks as new text messages (no reply_to, no status markup)
  defp send_followup_chunks(_intent, _route, [], _meta), do: :ok

  defp send_followup_chunks(intent, route, [chunk | rest], meta) do
    payload =
      OutboundPayload.text(
        "telegram",
        route.account_id,
        peer(route),
        chunk,
        idempotency_key: "#{intent.intent_id}:chunk:#{:erlang.unique_integer([:positive])}",
        meta: Map.drop(meta, [:reply_markup, :controls, :notify_tag])
      )

    _ = Outbox.enqueue(payload)
    send_followup_chunks(intent, route, rest, meta)
  end

  defp dispatch_files(
         %DeliveryIntent{route: %DeliveryRoute{} = route, attachments: attachments} = intent
       )
       when is_list(attachments) do
    files =
      attachments
      |> Enum.map(&normalize_attachment/1)
      |> Enum.reject(&is_nil/1)

    files
    |> FileBatcher.batch()
    |> Enum.with_index()
    |> Enum.each(fn {batch, idx} ->
      content = build_file_content(batch)

      payload =
        %OutboundPayload{
          channel_id: "telegram",
          account_id: route.account_id,
          peer: peer(route),
          kind: :file,
          content: content,
          reply_to: if(idx == 0, do: optional_reply_to(intent), else: nil),
          idempotency_key: "#{intent.intent_id}:file:#{idx}",
          meta: intent_meta(intent, nil)
        }

      _ = Outbox.enqueue(payload)
    end)

    :ok
  end

  defp dispatch_files(_intent), do: :ok

  defp maybe_dispatch_auto_send_files(%DeliveryIntent{kind: kind} = intent)
       when kind in [:stream_finalize, :final_text] do
    files = auto_send_files(intent)

    if files == [] do
      :ok
    else
      dispatch_files(%{intent | attachments: files})
    end
  end

  defp maybe_dispatch_auto_send_files(_intent), do: :ok

  defp normalize_text(%DeliveryIntent{kind: :stream_finalize} = intent, text) do
    text =
      if show_resume_line?() do
        maybe_append_resume_line(text, pending_resume(intent))
      else
        text
      end

    Truncate.split_messages(text)
  rescue
    _ -> [text]
  end

  defp normalize_text(%DeliveryIntent{kind: kind}, text)
       when kind in [:stream_snapshot, :tool_status_snapshot] do
    # Streaming snapshots edit a single message in-place. If we split into
    # multiple chunks here, send_text_chunks will create NEW follow-up messages
    # for the overflow on every snapshot — producing a spam of progressively
    # longer messages. Truncate to a single message instead; the finalize
    # intent will split properly.
    [Truncate.truncate_for_telegram(text)]
  rescue
    _ -> [text]
  end

  defp normalize_text(_intent, text) do
    Truncate.split_messages(text)
  rescue
    _ -> [text]
  end

  defp extract_text(%DeliveryIntent{body: body}) when is_map(body) do
    case body[:text] || body["text"] do
      text when is_binary(text) and text != "" -> {:ok, text}
      _ -> {:error, :missing_text}
    end
  end

  defp extract_text(_), do: {:error, :missing_text}

  defp extract_seq(%DeliveryIntent{body: body}) when is_map(body) do
    seq = body[:seq] || body["seq"]
    if is_integer(seq) and seq >= 0, do: seq, else: 0
  end

  defp extract_seq(_), do: 0

  defp surface_for(%DeliveryIntent{} = intent) do
    meta = intent.meta || %{}
    surface = meta[:surface] || meta["surface"]

    cond do
      not is_nil(surface) -> surface
      intent.kind in [:tool_status_snapshot, :tool_status_finalize, :watchdog_prompt] -> :status
      true -> :answer
    end
  end

  defp status_reply_markup(%DeliveryIntent{} = intent) do
    StatusRenderer.reply_markup(intent)
  end

  defp intent_meta(%DeliveryIntent{} = intent, reply_markup) do
    %{
      run_id: intent.run_id,
      session_key: intent.session_key,
      intent_kind: intent.kind,
      controls: intent.controls,
      intent_meta: intent.meta,
      reply_markup: reply_markup
    }
  end

  defp optional_reply_to(%DeliveryIntent{} = intent) do
    meta = intent.meta || %{}
    value = meta[:user_msg_id] || meta["user_msg_id"] || meta[:reply_to] || meta["reply_to"]

    case value do
      nil -> nil
      id -> to_string(id)
    end
  end

  defp normalize_attachment(%{path: path} = file) when is_binary(path) and path != "" do
    %{
      path: path,
      filename: file[:filename] || Path.basename(path),
      caption: file[:caption],
      source: file[:source]
    }
  end

  defp normalize_attachment(%{"path" => path} = file) when is_binary(path) and path != "" do
    %{
      path: path,
      filename: file["filename"] || Path.basename(path),
      caption: file["caption"],
      source: file["source"]
    }
  end

  defp normalize_attachment(_), do: nil

  defp build_file_content([file]) do
    %{path: file.path, filename: file.filename, caption: file.caption}
  end

  defp build_file_content(files) when is_list(files) do
    %{
      files:
        Enum.map(files, fn file ->
          %{path: file.path, filename: file.filename, caption: file.caption}
        end)
    }
  end

  defp maybe_index_resume(intent, route, message_id) do
    resume = pending_resume(intent)

    if intent.kind in [:stream_finalize, :final_text] do
      chat_id = parse_int(route.peer_id)
      thread_id = parse_int(route.thread_id)
      msg_id = parse_int(message_id)

      if is_integer(chat_id) and is_integer(msg_id) and resume_token_like?(resume) do
        ResumeIndexStore.put_resume(
          route.account_id || "default",
          chat_id,
          thread_id,
          msg_id,
          resume
        )
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp pending_resume(%DeliveryIntent{} = intent) do
    meta = intent.meta || %{}
    body = intent.body || %{}

    meta[:resume] || meta["resume"] || body[:resume] || body["resume"]
  end

  defp auto_send_files(%DeliveryIntent{} = intent) do
    meta = intent.meta || %{}
    cfg = auto_send_generated_config()

    case meta[:auto_send_files] || meta["auto_send_files"] do
      files when is_list(files) -> filter_auto_send_files(files, cfg)
      _ -> []
    end
  end

  defp filter_auto_send_files(files, cfg) when is_list(files) do
    {explicit, generated} =
      files
      |> Enum.map(&normalize_attachment/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.split_with(&(attachment_source(&1) == :explicit))

    generated =
      if cfg.enabled do
        generated
        |> Enum.take(-cfg.max_files)
        |> Enum.filter(&file_size_within_limit?(&1.path, cfg.max_bytes))
      else
        []
      end

    explicit ++ generated
  end

  defp filter_auto_send_files(_files, _cfg), do: []

  defp attachment_source(%{source: source}) when source in [:explicit, :generated], do: source
  defp attachment_source(%{"source" => source}) when source in [:explicit, :generated], do: source
  defp attachment_source(_file), do: :explicit

  defp file_size_within_limit?(path, max_bytes)
       when is_binary(path) and is_integer(max_bytes) and max_bytes > 0 do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> size <= max_bytes
      _ -> false
    end
  rescue
    _ -> false
  end

  defp file_size_within_limit?(_path, _max_bytes), do: false

  defp show_resume_line? do
    case GatewayConfig.get(:telegram, %{}) do
      %{} = cfg -> cfg[:show_resume_line] || cfg["show_resume_line"] || false
      _ -> false
    end
  rescue
    _ -> false
  end

  defp maybe_append_resume_line(text, nil), do: text

  defp maybe_append_resume_line(text, resume) when is_binary(text) do
    case normalize_resume(resume) do
      nil ->
        text

      %ResumeToken{} = tok ->
        text = String.trim_trailing(text)
        line = format_resume_line(tok)

        if String.contains?(text, tok.value) do
          text
        else
          if text == "" do
            line
          else
            text <> "\n\n" <> line
          end
        end
    end
  rescue
    _ -> text
  end

  defp normalize_resume(%ResumeToken{} = resume), do: resume

  defp normalize_resume(%{engine: engine, value: value})
       when is_binary(engine) and is_binary(value) do
    %ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume(%{"engine" => engine, "value" => value})
       when is_binary(engine) and is_binary(value) do
    %ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume(_), do: nil

  defp format_resume_line(%ResumeToken{} = resume) do
    ResumeToken.format_plain(resume)
  rescue
    _ -> "#{resume.engine} resume #{resume.value}"
  end

  defp resume_token_like?(%ResumeToken{engine: e, value: v}) when is_binary(e) and is_binary(v),
    do: true

  defp resume_token_like?(%{engine: e, value: v}) when is_binary(e) and is_binary(v), do: true

  defp resume_token_like?(%{"engine" => e, "value" => v}) when is_binary(e) and is_binary(v),
    do: true

  defp resume_token_like?(_), do: false

  defp duplicate?(state, seq, text_hash) do
    state.last_seq == seq and state.last_text_hash == text_hash
  end

  defp text_hash(value), do: :erlang.phash2(value)

  defp present_message_id?(id) when is_integer(id), do: true
  defp present_message_id?(id) when is_binary(id), do: id != ""
  defp present_message_id?(_), do: false

  defp peer(%DeliveryRoute{} = route) do
    %{
      kind: normalize_peer_kind(route.peer_kind),
      id: to_string(route.peer_id),
      thread_id: route.thread_id
    }
  end

  defp normalize_peer_kind(kind) when kind in [:dm, :group, :channel], do: kind
  defp normalize_peer_kind("dm"), do: :dm
  defp normalize_peer_kind("group"), do: :group
  defp normalize_peer_kind("channel"), do: :channel
  defp normalize_peer_kind(_), do: :dm

  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {value, _} -> value
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  @spec auto_send_generated_config() :: %{
          enabled: boolean(),
          max_files: pos_integer(),
          max_bytes: pos_integer()
        }
  def auto_send_generated_config do
    telegram_cfg = GatewayConfig.get(:telegram, %{}) || %{}
    files_cfg = (telegram_cfg[:files] || telegram_cfg["files"] || %{}) |> normalize_map()

    %{
      enabled:
        truthy?(files_cfg[:enabled] || files_cfg["enabled"]) and
          truthy?(
            files_cfg[:auto_send_generated_images] || files_cfg["auto_send_generated_images"]
          ),
      max_files:
        positive_int_or(
          files_cfg[:auto_send_generated_max_files] || files_cfg["auto_send_generated_max_files"],
          3
        ),
      max_bytes:
        positive_int_or(
          files_cfg[:max_download_bytes] || files_cfg["max_download_bytes"],
          @default_max_download_bytes
        )
    }
  rescue
    _ -> %{enabled: false, max_files: 3, max_bytes: @default_max_download_bytes}
  end

  defp normalize_map(value) when is_map(value), do: value

  defp normalize_map(value) when is_list(value) do
    if Keyword.keyword?(value), do: Enum.into(value, %{}), else: %{}
  end

  defp normalize_map(_), do: %{}

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  defp positive_int_or(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int_or(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_int_or(_value, default), do: default
end
