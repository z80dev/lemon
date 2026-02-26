defmodule LemonRouter.ChannelAdapter.Generic do
  @moduledoc """
  Generic channel adapter for non-Telegram channels.

  Uses the channels outbox for all output, with no truncation,
  no file batching, and no reply markup.
  """

  @behaviour LemonRouter.ChannelAdapter

  require Logger

  alias LemonRouter.{ChannelContext, ChannelsDelivery}

  @default_max_download_bytes 50 * 1024 * 1024

  # ---- Stream output ----

  @impl true
  def emit_stream_output(snapshot) do
    parsed = ChannelContext.parse_session_key(snapshot.session_key)

    {kind, content} = get_output_kind_and_content(snapshot)

    payload =
      struct!(LemonChannels.OutboundPayload,
        channel_id: snapshot.channel_id,
        account_id: parsed.account_id,
        peer: %{
          kind: parsed.peer_kind,
          id: parsed.peer_id,
          thread_id: parsed.thread_id
        },
        kind: kind,
        content: content,
        idempotency_key: "#{snapshot.run_id}:#{snapshot.last_seq}",
        meta: %{
          run_id: snapshot.run_id,
          session_key: snapshot.session_key,
          seq: snapshot.last_seq
        }
      )

    case ChannelsDelivery.enqueue(payload,
           context: %{component: :stream_coalescer, phase: :emit_output}
         ) do
      {:ok, _ref} -> :ok
      {:error, :duplicate} -> :ok
      {:error, reason} -> Logger.warning("Failed to enqueue coalesced output: #{inspect(reason)}")
    end

    {:ok, %{}}
  end

  # ---- Finalize stream ----

  @impl true
  def finalize_stream(_snapshot, _final_text), do: :skip

  # ---- Tool status ----

  @impl true
  def emit_tool_status(snapshot, text) do
    parsed = ChannelContext.parse_session_key(snapshot.session_key)
    status_msg_id = snapshot.meta[:status_msg_id]

    cond do
      is_nil(status_msg_id) and is_reference(snapshot.status_create_ref) ->
        {:ok, %{deferred_text: text}}

      true ->
        {kind, content, notify_pid, notify_ref} =
          get_status_output_kind_and_content(snapshot, text)

        payload =
          struct!(LemonChannels.OutboundPayload,
            channel_id: snapshot.channel_id,
            account_id: parsed.account_id,
            peer: %{
              kind: parsed.peer_kind,
              id: parsed.peer_id,
              thread_id: parsed.thread_id
            },
            kind: kind,
            content: content,
            reply_to: snapshot.meta[:user_msg_id] || snapshot.meta["user_msg_id"],
            idempotency_key: "#{snapshot.run_id}:status:#{snapshot.seq}",
            meta: %{
              run_id: snapshot.run_id,
              session_key: snapshot.session_key,
              status_seq: snapshot.seq,
              reply_markup: nil
            },
            notify_pid: notify_pid,
            notify_ref: notify_ref
          )

        case ChannelsDelivery.enqueue(payload,
               context: %{component: :tool_status_coalescer, phase: :status_output}
             ) do
          {:ok, _ref} ->
            if is_reference(notify_ref),
              do: {:ok, %{status_create_ref: notify_ref}},
              else: {:ok, %{}}

          {:error, :duplicate} ->
            {:ok, %{}}

          {:error, reason} ->
            Logger.warning("Failed to enqueue tool status output: #{inspect(reason)}")
            {:ok, %{}}
        end
    end
  rescue
    _ -> {:ok, %{}}
  end

  # ---- Delivery ack ----

  @impl true
  def handle_delivery_ack(_snapshot, _ref, _result), do: %{}

  # ---- Text/file helpers ----

  @impl true
  def truncate(text), do: text

  @impl true
  def batch_files(files), do: Enum.map(files, &[&1])

  @impl true
  def tool_status_reply_markup(_snapshot), do: nil

  # ---- Output tracker flags ----

  @impl true
  def skip_non_streaming_final_emit?, do: false

  @impl true
  def should_finalize_stream?, do: false

  @impl true
  def auto_send_config do
    %{enabled: false, max_files: 3, max_bytes: @default_max_download_bytes}
  end

  @impl true
  def files_max_download_bytes, do: @default_max_download_bytes

  # ---- Renderer ----

  @impl true
  def limit_order(order), do: {order, 0}

  @impl true
  def format_action_extra(_action, _rendered_title), do: nil

  # ---- Private ----

  defp get_output_kind_and_content(snapshot) do
    supports_edit = ChannelContext.channel_supports_edit?(snapshot.channel_id)
    answer_msg_id = snapshot.meta[:answer_msg_id] || snapshot.meta["answer_msg_id"]

    cond do
      supports_edit and answer_msg_id != nil ->
        {:edit, %{message_id: answer_msg_id, text: snapshot.full_text}}

      true ->
        {:text, snapshot.buffer}
    end
  end

  defp get_status_output_kind_and_content(snapshot, text) do
    supports_edit = ChannelContext.channel_supports_edit?(snapshot.channel_id)
    status_msg_id = snapshot.meta[:status_msg_id]

    cond do
      supports_edit and status_msg_id != nil ->
        {:edit, %{message_id: status_msg_id, text: text}, nil, nil}

      true ->
        if supports_edit and is_nil(status_msg_id) do
          ref = make_ref()
          {:text, text, self(), ref}
        else
          {:text, text, nil, nil}
        end
    end
  end
end
