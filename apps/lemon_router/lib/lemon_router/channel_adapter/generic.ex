defmodule LemonRouter.ChannelAdapter.Generic do
  @moduledoc """
  Generic channel adapter for non-Telegram channels.

  Uses the channels outbox for all output, with no truncation,
  no file batching, and no reply markup.

  Emits `LemonCore.OutputIntent` structs and dispatches them via
  `LemonChannels.Dispatcher` for channel-agnostic delivery.
  """

  @behaviour LemonRouter.ChannelAdapter

  require Logger

  alias LemonCore.{ChannelRoute, OutputIntent}
  alias LemonChannels.Dispatcher
  alias LemonRouter.ChannelContext

  @default_max_download_bytes 50 * 1024 * 1024

  # ---- Stream output ----

  @impl true
  def emit_stream_output(snapshot) do
    parsed = ChannelContext.parse_session_key(snapshot.session_key)
    route = route_from_parsed(parsed)

    {op, body} = get_output_op_and_body(snapshot)

    intent = %OutputIntent{
      route: route,
      op: op,
      body: body,
      meta: %{
        idempotency_key: "#{snapshot.run_id}:#{snapshot.last_seq}",
        run_id: snapshot.run_id,
        session_key: snapshot.session_key,
        seq: snapshot.last_seq
      }
    }

    case Dispatcher.dispatch(intent) do
      :ok -> :ok
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
        route = route_from_parsed(parsed)
        {op, body, notify_pid, notify_ref} = get_status_op_and_body(snapshot, text)

        intent = %OutputIntent{
          route: route,
          op: op,
          body: body,
          meta: %{
            reply_to: snapshot.meta[:user_msg_id] || snapshot.meta["user_msg_id"],
            idempotency_key: "#{snapshot.run_id}:status:#{snapshot.seq}",
            run_id: snapshot.run_id,
            session_key: snapshot.session_key,
            status_seq: snapshot.seq,
            reply_markup: nil,
            notify_pid: notify_pid,
            notify_ref: notify_ref
          }
        }

        case Dispatcher.dispatch(intent) do
          :ok ->
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

  defp route_from_parsed(parsed) do
    %ChannelRoute{
      channel_id: parsed.channel_id,
      account_id: parsed.account_id || "default",
      peer_kind: parsed.peer_kind,
      peer_id: parsed.peer_id,
      thread_id: parsed.thread_id
    }
  end

  defp get_output_op_and_body(snapshot) do
    supports_edit = ChannelContext.channel_supports_edit?(snapshot.channel_id)
    answer_msg_id = snapshot.meta[:answer_msg_id] || snapshot.meta["answer_msg_id"]

    cond do
      supports_edit and answer_msg_id != nil ->
        {:stream_replace, %{message_id: answer_msg_id, text: snapshot.full_text}}

      true ->
        {:stream_append, %{text: snapshot.buffer}}
    end
  end

  defp get_status_op_and_body(snapshot, text) do
    supports_edit = ChannelContext.channel_supports_edit?(snapshot.channel_id)
    status_msg_id = snapshot.meta[:status_msg_id]

    cond do
      supports_edit and status_msg_id != nil ->
        {:stream_replace, %{message_id: status_msg_id, text: text}, nil, nil}

      true ->
        if supports_edit and is_nil(status_msg_id) do
          ref = make_ref()
          {:tool_status, %{text: text}, self(), ref}
        else
          {:tool_status, %{text: text}, nil, nil}
        end
    end
  end
end
