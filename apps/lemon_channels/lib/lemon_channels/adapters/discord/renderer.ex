defmodule LemonChannels.Adapters.Discord.Renderer do
  @moduledoc """
  Discord renderer for semantic delivery intents.
  """

  alias LemonChannels.Adapters.Discord.StatusRenderer
  alias LemonChannels.GatewayConfig
  alias LemonChannels.{OutboundPayload, Outbox, PresentationState}
  alias LemonChannels.Outbox.Chunker
  alias LemonCore.{DeliveryIntent, DeliveryRoute}

  @default_max_download_bytes 25 * 1024 * 1024
  @safe_text_chunk_chars 1_900

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
         state <- PresentationState.get(route, intent.run_id, surface),
         components = StatusRenderer.components(intent),
         chunks <- normalize_text(intent, text),
         text_hash = text_hash({chunks, components, final_file_signature(intent)}) do
      if duplicate?(state, intent.kind, seq, text_hash) do
        :ok
      else
        case send_text_chunks(intent, route, state, surface, seq, text_hash, chunks, components) do
          :ok ->
            maybe_dispatch_auto_send_files(intent)

          other ->
            other
        end
      end
    end
  end

  defp send_text_chunks(intent, route, state, surface, seq, text_hash, [single], components) do
    send_text(intent, route, state, surface, seq, text_hash, single, components)
  end

  defp send_text_chunks(intent, route, state, surface, seq, text_hash, [first | rest], components) do
    meta =
      intent
      |> intent_meta(components)
      |> put_followup_reply_to(optional_reply_to(intent))

    if is_reference(state.pending_create_ref) or is_reference(state.pending_edit_ref) do
      PresentationState.defer_chunks(
        route,
        intent.run_id,
        surface,
        [first | rest],
        seq,
        text_hash,
        meta
      )
    else
      case send_text(intent, route, state, surface, seq, text_hash, first, components) do
        :ok -> PresentationState.stage_followups(route, intent.run_id, surface, rest, meta)
        other -> other
      end
    end
  end

  defp send_text(intent, route, state, surface, seq, text_hash, text, components) do
    meta = intent_meta(intent, components)

    cond do
      present_message_id?(state.platform_message_id) ->
        payload =
          OutboundPayload.edit(
            route.channel_id,
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

          {:error, :duplicate} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      is_reference(state.pending_create_ref) ->
        PresentationState.defer_text(route, intent.run_id, surface, text, seq, text_hash, meta)

      true ->
        notify_ref = make_ref()

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
            route.channel_id,
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

  defp normalize_text(%DeliveryIntent{kind: kind}, text)
       when kind in [:stream_snapshot, :tool_status_snapshot] do
    [truncate_text(text)]
  rescue
    _ -> [text]
  end

  defp normalize_text(_intent, text) do
    Chunker.chunk(text, chunk_size: text_chunk_size())
  rescue
    _ -> [text]
  end

  defp truncate_text(text) do
    chunk_size = text_chunk_size()

    if String.length(text) <= chunk_size do
      text
    else
      String.slice(text, 0, chunk_size)
    end
  end

  defp text_chunk_size do
    min(Chunker.chunk_size_for("discord"), @safe_text_chunk_chars)
  end

  defp dispatch_files(
         %DeliveryIntent{route: %DeliveryRoute{} = route, attachments: attachments} = intent
       )
       when is_list(attachments) do
    attachments
    |> Enum.map(&normalize_attachment/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.with_index()
    |> Enum.each(fn {file, idx} ->
      payload =
        %OutboundPayload{
          channel_id: route.channel_id,
          account_id: route.account_id,
          peer: peer(route),
          kind: :file,
          content: file,
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

  defp intent_meta(%DeliveryIntent{} = intent, components) do
    base = %{
      run_id: intent.run_id,
      session_key: intent.session_key,
      intent_kind: intent.kind,
      controls: intent.controls,
      intent_meta: intent.meta
    }

    if is_list(components), do: Map.put(base, :components, components), else: base
  end

  defp put_followup_reply_to(meta, nil), do: meta
  defp put_followup_reply_to(meta, reply_to), do: Map.put(meta, :followup_reply_to, reply_to)

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

  defp final_file_signature(%DeliveryIntent{kind: kind} = intent)
       when kind in [:stream_finalize, :final_text] do
    meta = intent.meta || %{}

    case meta[:auto_send_files] || meta["auto_send_files"] do
      files when is_list(files) ->
        files
        |> Enum.map(&normalize_attachment/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn file -> {file.path, file.filename, file.source} end)

      _ ->
        []
    end
  end

  defp final_file_signature(_intent), do: []

  defp duplicate?(state, kind, seq, text_hash) do
    (state.last_seq == seq and state.last_text_hash == text_hash) or
      finalize_repeat?(state, kind, seq, text_hash)
  end

  defp finalize_repeat?(state, kind, seq, text_hash)
       when kind in [:stream_finalize, :final_text] do
    state.last_text_hash == text_hash and is_integer(state.last_seq) and seq >= state.last_seq
  end

  defp finalize_repeat?(_state, _kind, _seq, _text_hash), do: false

  defp text_hash(value), do: :erlang.phash2(value)

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

  defp present_message_id?(id) when is_integer(id), do: true
  defp present_message_id?(id) when is_binary(id), do: id != ""
  defp present_message_id?(_), do: false

  defp auto_send_files(%DeliveryIntent{} = intent) do
    meta = intent.meta || %{}
    cfg = auto_send_generated_config()

    case meta[:auto_send_files] || meta["auto_send_files"] do
      files when is_list(files) ->
        filter_auto_send_files(files, cfg)

      _ ->
        []
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
  defp attachment_source(%{source: "explicit"}), do: :explicit
  defp attachment_source(%{source: "generated"}), do: :generated
  defp attachment_source(%{"source" => source}) when source in [:explicit, :generated], do: source
  defp attachment_source(%{"source" => "explicit"}), do: :explicit
  defp attachment_source(%{"source" => "generated"}), do: :generated
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

  defp auto_send_generated_config do
    discord_cfg = GatewayConfig.get(:discord, %{}) || %{}
    files_cfg = (discord_cfg[:files] || discord_cfg["files"] || %{}) |> normalize_map()

    %{
      enabled:
        truthy?(files_cfg[:enabled] || files_cfg["enabled"]) and
          truthy?(
            files_cfg[:auto_send_generated_files] ||
              files_cfg["auto_send_generated_files"] ||
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

  defp pending_resume(%DeliveryIntent{} = intent) do
    meta = intent.meta || %{}

    meta[:resume] || meta["resume"] || get_in(intent.body || %{}, [:resume]) ||
      get_in(intent.body || %{}, ["resume"])
  end
end
