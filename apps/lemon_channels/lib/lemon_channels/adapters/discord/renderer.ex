defmodule LemonChannels.Adapters.Discord.Renderer do
  @moduledoc """
  Discord renderer for semantic delivery intents.
  """

  alias LemonChannels.Adapters.Discord.StatusRenderer
  alias LemonChannels.{OutboundPayload, Outbox, PresentationState}
  alias LemonCore.{DeliveryIntent, DeliveryRoute}

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
         text_hash = text_hash({text, components}) do
      if duplicate?(state, seq, text_hash) do
        :ok
      else
        send_text(intent, route, state, surface, seq, text_hash, text, components)
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
            maybe_dispatch_auto_send_files(intent)

          {:error, :duplicate} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
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
      caption: file[:caption]
    }
  end

  defp normalize_attachment(%{"path" => path} = file) when is_binary(path) and path != "" do
    %{
      path: path,
      filename: file["filename"] || Path.basename(path),
      caption: file["caption"]
    }
  end

  defp normalize_attachment(_), do: nil

  defp duplicate?(state, seq, text_hash) do
    state.last_seq == seq and state.last_text_hash == text_hash
  end

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

    case meta[:auto_send_files] || meta["auto_send_files"] do
      files when is_list(files) ->
        files
        |> Enum.map(&normalize_attachment/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp pending_resume(%DeliveryIntent{} = intent) do
    meta = intent.meta || %{}

    meta[:resume] || meta["resume"] || get_in(intent.body || %{}, [:resume]) ||
      get_in(intent.body || %{}, ["resume"])
  end
end
