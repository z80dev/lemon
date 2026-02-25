defmodule LemonRouter.ChannelAdapter.Telegram do
  @moduledoc """
  Telegram channel adapter.

  Encapsulates all Telegram-specific output strategy logic that was previously
  scattered across StreamCoalescer, ToolStatusCoalescer, ToolStatusRenderer,
  and OutputTracker.

  Manages the dual-message model (progress message + answer message),
  resume token tracking, media group batching, and Telegram API constraints.
  """

  @behaviour LemonRouter.ChannelAdapter

  require Logger

  alias LemonCore.ResumeToken
  alias LemonRouter.{ChannelContext, ChannelsDelivery}

  @cancel_callback_prefix "lemon:cancel"
  @telegram_media_group_max_items 10
  @telegram_recent_action_limit 5
  @image_extensions MapSet.new(~w(.png .jpg .jpeg .gif .webp .bmp .svg .tif .tiff .heic .heif))
  @pending_resume_cleanup_base_ms 2_000
  @pending_resume_cleanup_max_attempts 4
  @pending_resume_cleanup_max_backoff_ms 30_000
  @default_auto_send_generated_max_files 3
  @default_max_download_bytes 50 * 1024 * 1024

  # ===========================================================================
  # Stream output
  # ===========================================================================

  @impl true
  def emit_stream_output(snapshot) do
    parsed = ChannelContext.parse_session_key(snapshot.session_key)
    emit_telegram_answer_output(snapshot, parsed)
  end

  defp emit_telegram_answer_output(snapshot, parsed) do
    chat_id = parse_int(parsed.peer_id)
    thread_id = parse_int(parsed.thread_id)

    reply_to = meta_get(snapshot, :user_msg_id)
    answer_msg_id = meta_get(snapshot, :answer_msg_id)

    text = truncate(snapshot.full_text)

    cond do
      not is_integer(chat_id) ->
        :skip

      is_integer(answer_msg_id) ->
        emit_telegram_answer_edit(snapshot, parsed, chat_id, answer_msg_id, text)

      is_reference(snapshot.answer_create_ref) ->
        {:ok, %{deferred_answer_text: text}}

      true ->
        emit_telegram_answer_create(snapshot, parsed, chat_id, thread_id, text, reply_to)
    end
  rescue
    _ -> :skip
  end

  defp emit_telegram_answer_edit(snapshot, parsed, chat_id, answer_msg_id, text) do
    if text == snapshot.last_sent_text do
      {:ok, %{}}
    else
      payload =
        build_telegram_payload(
          parsed,
          :edit,
          %{message_id: answer_msg_id, text: text},
          "#{snapshot.run_id}:answer:#{snapshot.last_seq}",
          %{
            meta: %{
              run_id: snapshot.run_id,
              session_key: snapshot.session_key,
              seq: snapshot.last_seq
            }
          }
        )

      case ChannelsDelivery.telegram_enqueue(
             {chat_id, answer_msg_id, :edit},
             0,
             {:edit, chat_id, answer_msg_id, %{text: text}},
             payload,
             context: %{component: :stream_coalescer, phase: :answer_edit}
           ) do
        {:ok, _ref} -> :ok
        {:error, reason} -> Logger.warning("Failed to enqueue answer edit: #{inspect(reason)}")
      end

      {:ok, %{last_sent_text: text}}
    end
  end

  defp emit_telegram_answer_create(snapshot, parsed, chat_id, thread_id, text, reply_to) do
    notify_ref = make_ref()

    payload =
      build_telegram_payload(
        parsed,
        :text,
        text,
        "#{snapshot.run_id}:answer:create",
        %{
          reply_to: reply_to,
          meta: %{
            run_id: snapshot.run_id,
            session_key: snapshot.session_key,
            seq: snapshot.last_seq
          }
        }
      )

    case ChannelsDelivery.telegram_enqueue_with_notify(
           {chat_id, snapshot.run_id, :answer_create},
           1,
           {:send, chat_id,
            %{
              text: text,
              reply_to_message_id: reply_to,
              message_thread_id: thread_id
            }},
           payload,
           self(),
           notify_ref,
           :outbox_delivered,
           context: %{component: :stream_coalescer, phase: :answer_create}
         ) do
      {:ok, _ref} ->
        {:ok, %{answer_create_ref: notify_ref}}

      {:error, :duplicate} ->
        {:ok, %{}}

      {:error, :channels_outbox_unavailable} ->
        {:ok, %{}}

      {:error, reason} ->
        Logger.warning("Failed to enqueue answer create: #{inspect(reason)}")
        {:ok, %{}}
    end
  end

  # ===========================================================================
  # Finalize stream
  # ===========================================================================

  @impl true
  def finalize_stream(snapshot, final_text) do
    resume = meta_get(snapshot, :resume)

    text =
      cond do
        is_binary(final_text) and final_text != "" -> final_text
        is_binary(snapshot.full_text) and snapshot.full_text != "" -> snapshot.full_text
        is_binary(snapshot.buffer) and snapshot.buffer != "" -> snapshot.buffer
        true -> "Done"
      end

    text = if show_resume_line?(), do: maybe_append_resume_line(text, resume), else: text

    reply_to = meta_get(snapshot, :user_msg_id)
    answer_msg_id = meta_get(snapshot, :answer_msg_id)

    parsed = ChannelContext.parse_session_key(snapshot.session_key)

    chat_id = parse_int(parsed.peer_id)
    thread_id = parse_int(parsed.thread_id)
    account_id = parsed.account_id || "default"

    updates =
      cond do
        is_integer(chat_id) and is_integer(answer_msg_id) ->
          finalize_edit_answer(
            snapshot,
            parsed,
            chat_id,
            thread_id,
            account_id,
            answer_msg_id,
            text,
            resume
          )

        is_integer(chat_id) and is_reference(snapshot.answer_create_ref) ->
          %{deferred_answer_text: truncate(text)}

        text != "" ->
          finalize_send_answer(
            snapshot,
            parsed,
            chat_id,
            thread_id,
            account_id,
            text,
            reply_to,
            resume
          )

        true ->
          %{}
      end

    file_updates = enqueue_auto_send_files(snapshot, parsed, reply_to)
    updates = Map.merge(updates, file_updates)

    updates =
      Map.merge(updates, %{
        buffer: "",
        full_text: "",
        first_delta_ts: nil,
        flush_timer: nil,
        last_sent_text: nil,
        finalized: true
      })

    {:ok, updates}
  rescue
    _ -> {:ok, %{finalized: true}}
  end

  defp finalize_edit_answer(
         snapshot,
         parsed,
         chat_id,
         thread_id,
         account_id,
         answer_msg_id,
         text,
         resume
       ) do
    edit_text = truncate(text)

    payload =
      build_telegram_payload(
        parsed,
        :edit,
        %{message_id: answer_msg_id, text: edit_text},
        "#{snapshot.run_id}:final:answer_edit",
        %{
          meta: %{
            run_id: snapshot.run_id,
            session_key: snapshot.session_key,
            final: true
          }
        }
      )

    case ChannelsDelivery.telegram_enqueue(
           {chat_id, answer_msg_id, :edit},
           0,
           {:edit, chat_id, answer_msg_id, %{text: edit_text}},
           payload,
           context: %{component: :stream_coalescer, phase: :final_answer_edit}
         ) do
      {:ok, _ref} -> :ok
      {:error, reason} -> Logger.warning("Failed to enqueue final answer edit: #{inspect(reason)}")
    end

    _ = maybe_index_resume(account_id, chat_id, thread_id, answer_msg_id, resume)
    %{last_sent_text: edit_text}
  end

  defp finalize_send_answer(snapshot, parsed, chat_id, thread_id, account_id, text, reply_to, resume) do
    send_text = truncate(text)
    notify_ref = make_ref()
    base_pending = snapshot.pending_resume_indices || %{}

    pending = fn ->
      maybe_track_pending_resume(
        base_pending,
        notify_ref,
        account_id,
        chat_id,
        thread_id,
        resume
      )
    end

    payload =
      build_telegram_payload(
        parsed,
        :text,
        text,
        "#{snapshot.run_id}:final:send",
        %{
          reply_to: reply_to,
          meta: %{
            run_id: snapshot.run_id,
            session_key: snapshot.session_key,
            final: true
          }
        }
      )

    delivery_result =
      if is_integer(chat_id) do
        ChannelsDelivery.telegram_enqueue_with_notify(
          {chat_id, snapshot.run_id, :final_send},
          1,
          {:send, chat_id,
           %{
             text: send_text,
             reply_to_message_id: reply_to,
             message_thread_id: thread_id
           }},
          payload,
          self(),
          notify_ref,
          :outbox_delivered,
          context: %{component: :stream_coalescer, phase: :final_send}
        )
      else
        payload
        |> Map.put(:notify_pid, self())
        |> Map.put(:notify_ref, notify_ref)
        |> ChannelsDelivery.enqueue(context: %{component: :stream_coalescer, phase: :final_send})
      end

    case delivery_result do
      {:ok, _ref} ->
        %{pending_resume_indices: pending.()}

      {:error, :duplicate} ->
        Logger.debug(
          "Skipping pending resume index tracking for duplicate final answer send " <>
            "(chat_id=#{inspect(chat_id)} thread_id=#{inspect(thread_id)} run_id=#{inspect(snapshot.run_id)})"
        )

        %{}

      {:error, :channels_outbox_unavailable} ->
        %{}

      {:error, reason} ->
        Logger.warning("Failed to enqueue final answer send: #{inspect(reason)}")
        %{}
    end
  end

  # ===========================================================================
  # Tool status output
  # ===========================================================================

  @impl true
  def emit_tool_status(snapshot, text) do
    if not ChannelsDelivery.telegram_outbox_available?() do
      # Fall back to generic path when Telegram outbox is down
      LemonRouter.ChannelAdapter.Generic.emit_tool_status(snapshot, text)
    else
      parsed = ChannelContext.parse_session_key(snapshot.session_key)
      chat_id = parse_int(parsed.peer_id)
      thread_id = parse_int(parsed.thread_id)
      reply_markup = tool_status_reply_markup(snapshot)

      target_msg_id = snapshot.meta[:status_msg_id]

      cond do
        not is_integer(chat_id) ->
          {:ok, %{}}

        is_nil(target_msg_id) and is_reference(snapshot.status_create_ref) ->
          {:ok, %{deferred_text: truncate(text)}}

        is_integer(target_msg_id) ->
          edit_text = truncate(text)

          telegram_payload =
            if snapshot.finalized == true do
              %{text: edit_text, reply_markup: %{"inline_keyboard" => []}}
            else
              %{text: edit_text}
            end

          reply_to = snapshot.meta[:user_msg_id] || snapshot.meta["user_msg_id"]

          fallback_payload =
            struct!(LemonChannels.OutboundPayload,
              channel_id: snapshot.channel_id,
              account_id: parsed.account_id,
              peer: %{
                kind: parsed.peer_kind,
                id: parsed.peer_id,
                thread_id: parsed.thread_id
              },
              kind: :edit,
              content: %{message_id: target_msg_id, text: edit_text},
              reply_to: reply_to,
              idempotency_key: "#{snapshot.run_id}:status:#{snapshot.seq}",
              meta: %{
                run_id: snapshot.run_id,
                session_key: snapshot.session_key,
                status_seq: snapshot.seq,
                reply_markup: reply_markup
              }
            )

          case ChannelsDelivery.telegram_enqueue(
                 {chat_id, target_msg_id, :edit},
                 0,
                 {:edit, chat_id, target_msg_id, telegram_payload},
                 fallback_payload,
                 context: %{component: :tool_status_coalescer, phase: :status_edit}
               ) do
            {:ok, _ref} -> :ok
            {:error, reason} -> Logger.warning("Failed to enqueue tool status edit: #{inspect(reason)}")
          end

          {:ok, %{}}

        true ->
          notify_ref = make_ref()
          send_text = truncate(text)
          reply_to = snapshot.meta[:user_msg_id] || snapshot.meta["user_msg_id"]

          fallback_payload =
            struct!(LemonChannels.OutboundPayload,
              channel_id: snapshot.channel_id,
              account_id: parsed.account_id,
              peer: %{
                kind: parsed.peer_kind,
                id: parsed.peer_id,
                thread_id: parsed.thread_id
              },
              kind: :text,
              content: send_text,
              reply_to: reply_to,
              idempotency_key: "#{snapshot.run_id}:status:#{snapshot.seq}",
              meta: %{
                run_id: snapshot.run_id,
                session_key: snapshot.session_key,
                status_seq: snapshot.seq,
                reply_markup: reply_markup
              }
            )

          case ChannelsDelivery.telegram_enqueue_with_notify(
                 {chat_id, snapshot.run_id, :status_create},
                 0,
                 {:send, chat_id,
                  %{
                    text: send_text,
                    reply_to_message_id: reply_to,
                    message_thread_id: thread_id,
                    reply_markup: reply_markup
                  }},
                 fallback_payload,
                 self(),
                 notify_ref,
                 :outbox_delivered,
                 context: %{component: :tool_status_coalescer, phase: :status_create}
               ) do
            {:ok, _ref} ->
              {:ok, %{status_create_ref: notify_ref}}

            {:error, :duplicate} ->
              {:ok, %{}}

            {:error, :channels_outbox_unavailable} ->
              {:ok, %{}}

            {:error, reason} ->
              Logger.warning("Failed to enqueue tool status create: #{inspect(reason)}")
              {:ok, %{}}
          end
      end
    end
  rescue
    _ -> {:ok, %{}}
  end

  # ===========================================================================
  # Delivery ack handling (StreamCoalescer)
  # ===========================================================================

  @impl true
  def handle_delivery_ack(snapshot, ref, result) do
    cond do
      snapshot.answer_create_ref == ref ->
        handle_answer_create_ack(snapshot, result)

      true ->
        handle_pending_resume_ack(snapshot, ref, result)
    end
  end

  defp handle_answer_create_ack(snapshot, result) do
    parsed = ChannelContext.parse_session_key(snapshot.session_key)
    chat_id = parse_int(parsed.peer_id)
    thread_id = parse_int(parsed.thread_id)
    account_id = parsed.account_id || "default"
    message_id = extract_message_id_from_delivery(result)

    updates =
      if is_integer(message_id) do
        meta = Map.put(snapshot.meta || %{}, :answer_msg_id, message_id)
        %{meta: meta, answer_create_ref: nil}
      else
        %{answer_create_ref: nil}
      end

    updates =
      case {chat_id, message_id, snapshot.deferred_answer_text} do
        {cid, mid, text}
        when is_integer(cid) and is_integer(mid) and is_binary(text) and text != "" ->
          payload =
            build_telegram_payload(
              parsed,
              :edit,
              %{message_id: mid, text: text},
              "#{snapshot.run_id}:answer:deferred",
              %{
                meta: %{
                  run_id: snapshot.run_id,
                  session_key: snapshot.session_key,
                  seq: snapshot.last_seq
                }
              }
            )

          case ChannelsDelivery.telegram_enqueue(
                 {cid, mid, :edit},
                 0,
                 {:edit, cid, mid, %{text: text}},
                 payload,
                 context: %{
                   component: :stream_coalescer,
                   phase: :deferred_answer_edit,
                   run_id: snapshot.run_id
                 }
               ) do
            {:ok, _ref} -> :ok
            {:error, reason} -> Logger.warning("Failed to enqueue deferred answer edit: #{inspect(reason)}")
          end

          Map.merge(updates, %{deferred_answer_text: nil, last_sent_text: text})

        _ ->
          updates
      end

    resume = meta_get(snapshot, :resume)

    if snapshot.finalized == true and is_integer(chat_id) and is_integer(message_id) and
         resume_token_like?(resume) do
      _ = maybe_index_resume(account_id, chat_id, thread_id, message_id, resume)
    end

    updates
  end

  defp handle_pending_resume_ack(snapshot, ref, result) do
    {entry, pending} = Map.pop(snapshot.pending_resume_indices || %{}, ref)

    case entry do
      %{account_id: account_id, chat_id: chat_id, thread_id: thread_id, resume: resume} ->
        message_id = extract_message_id_from_delivery(result)
        _ = maybe_index_resume(account_id, chat_id, thread_id, message_id, resume)
        %{pending_resume_indices: pending}

      _ ->
        %{}
    end
  end

  # ===========================================================================
  # Text / file helpers
  # ===========================================================================

  @impl true
  def truncate(text) when is_binary(text) do
    LemonChannels.Telegram.Truncate.truncate_for_telegram(text)
  rescue
    _ -> text
  end

  def truncate(text), do: text

  @impl true
  def batch_files(files) when is_list(files) do
    {batches_rev, pending_images_rev} =
      Enum.reduce(files, {[], []}, fn file, {batches, pending_images} ->
        if image_file?(file.path) do
          pending_images = [file | pending_images]

          if length(pending_images) >= @telegram_media_group_max_items do
            {[Enum.reverse(pending_images) | batches], []}
          else
            {batches, pending_images}
          end
        else
          batches = flush_image_batch(batches, pending_images)
          {[[file] | batches], []}
        end
      end)

    batches_rev
    |> flush_image_batch(pending_images_rev)
    |> Enum.reverse()
  end

  def batch_files(_), do: []

  @impl true
  def tool_status_reply_markup(%{finalized: true}) do
    %{"inline_keyboard" => []}
  end

  def tool_status_reply_markup(%{run_id: run_id})
      when is_binary(run_id) and run_id != "" do
    %{
      "inline_keyboard" => [
        [
          %{
            "text" => "cancel",
            "callback_data" => @cancel_callback_prefix <> ":" <> run_id
          }
        ]
      ]
    }
  end

  def tool_status_reply_markup(_), do: nil

  # ===========================================================================
  # OutputTracker flags
  # ===========================================================================

  @impl true
  def skip_non_streaming_final_emit?, do: true

  @impl true
  def should_finalize_stream?, do: true

  @impl true
  def auto_send_config do
    telegram_cfg = LemonChannels.GatewayConfig.get(:telegram, %{}) || %{}
    telegram_cfg = normalize_map(telegram_cfg)

    files_cfg = fetch(telegram_cfg, :files)
    files_cfg = normalize_map(files_cfg)

    enabled? =
      truthy?(fetch(files_cfg, :enabled)) and
        truthy?(fetch(files_cfg, :auto_send_generated_images))

    %{
      enabled: enabled?,
      max_files:
        positive_int_or(
          fetch(files_cfg, :auto_send_generated_max_files),
          @default_auto_send_generated_max_files
        ),
      max_bytes:
        positive_int_or(fetch(files_cfg, :max_download_bytes), @default_max_download_bytes)
    }
  rescue
    _ ->
      %{
        enabled: false,
        max_files: @default_auto_send_generated_max_files,
        max_bytes: @default_max_download_bytes
      }
  end

  @impl true
  def files_max_download_bytes do
    telegram_cfg = LemonChannels.GatewayConfig.get(:telegram, %{}) || %{}
    telegram_cfg = normalize_map(telegram_cfg)
    files_cfg = fetch(telegram_cfg, :files) |> normalize_map()

    positive_int_or(fetch(files_cfg, :max_download_bytes), @default_max_download_bytes)
  rescue
    _ -> @default_max_download_bytes
  end

  # ===========================================================================
  # ToolStatusRenderer callbacks
  # ===========================================================================

  @impl true
  def limit_order(order) when is_list(order) do
    if length(order) > @telegram_recent_action_limit do
      display_order = Enum.take(order, -@telegram_recent_action_limit)
      omitted_count = length(order) - length(display_order)
      {display_order, omitted_count}
    else
      {order, 0}
    end
  end

  @impl true
  def format_action_extra(action, rendered_title) do
    [
      format_task_extra(action, rendered_title),
      format_command_extra(action, rendered_title)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("")
    |> case do
      "" -> nil
      text -> text
    end
  end

  # ===========================================================================
  # Pending resume cleanup (called by StreamCoalescer handle_info)
  # ===========================================================================

  @doc """
  Handle pending resume cleanup timeout. Called by StreamCoalescer's handle_info.
  Returns updated pending_resume_indices map.
  """
  def handle_pending_resume_cleanup(pending_resume_indices, ref, entry, attempt) do
    if attempt < @pending_resume_cleanup_max_attempts do
      next_attempt = attempt + 1
      next_delay_ms = pending_resume_cleanup_delay_ms(next_attempt)

      Logger.warning(
        "Timed out waiting for :outbox_delivered for pending resume index " <>
          "(chat_id=#{inspect(Map.get(entry, :chat_id))} thread_id=#{inspect(Map.get(entry, :thread_id))} " <>
          "attempt=#{attempt}/#{@pending_resume_cleanup_max_attempts}); " <>
          "retrying cleanup in #{next_delay_ms}ms"
      )

      _ = schedule_pending_resume_cleanup(ref, next_attempt)
      pending_resume_indices
    else
      Logger.warning(
        "Cleaning stale pending resume index after missing :outbox_delivered " <>
          "(chat_id=#{inspect(Map.get(entry, :chat_id))} thread_id=#{inspect(Map.get(entry, :thread_id))} " <>
          "attempt=#{attempt}/#{@pending_resume_cleanup_max_attempts} " <>
          "age_ms=#{pending_entry_age_ms(entry)})"
      )

      Map.delete(pending_resume_indices, ref)
    end
  end

  def schedule_pending_resume_cleanup(ref, attempt)
      when is_reference(ref) and is_integer(attempt) and attempt > 0 do
    Process.send_after(
      self(),
      {:pending_resume_cleanup_timeout, ref, attempt},
      pending_resume_cleanup_delay_ms(attempt)
    )

    :ok
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp enqueue_auto_send_files(snapshot, parsed, reply_to) do
    files = auto_send_files_from_meta(snapshot.meta)

    if files == [] do
      %{}
    else
      peer = %{
        kind: parsed.peer_kind,
        id: parsed.peer_id,
        thread_id: parsed.thread_id
      }

      payload_files = batch_files(files)

      Enum.with_index(payload_files)
      |> Enum.each(fn {file, idx} ->
        payload =
          struct!(LemonChannels.OutboundPayload,
            channel_id: snapshot.channel_id,
            account_id: parsed.account_id,
            peer: peer,
            kind: :file,
            content: build_auto_send_file_content(file),
            reply_to: if(idx == 0, do: reply_to, else: nil),
            idempotency_key: "#{snapshot.run_id}:final:file:#{idx}",
            meta: %{
              run_id: snapshot.run_id,
              session_key: snapshot.session_key,
              final: true,
              auto_send_generated: true
            }
          )

        case ChannelsDelivery.enqueue(payload,
               context: %{component: :stream_coalescer, phase: :auto_send_file}
             ) do
          {:ok, _ref} -> :ok
          {:error, :duplicate} -> :ok
          {:error, reason} -> Logger.warning("Failed to enqueue auto-sent file: #{inspect(reason)}")
        end
      end)

      %{}
    end
  end

  defp build_auto_send_file_content([file]) do
    %{path: file.path, filename: file.filename, caption: file.caption}
  end

  defp build_auto_send_file_content(files) when is_list(files) do
    %{
      files:
        Enum.map(files, fn file ->
          %{path: file.path, filename: file.filename, caption: file.caption}
        end)
    }
  end

  defp auto_send_files_from_meta(meta) when is_map(meta) do
    value = Map.get(meta, :auto_send_files) || Map.get(meta, "auto_send_files")

    case value do
      list when is_list(list) ->
        list
        |> Enum.map(&normalize_auto_send_file/1)
        |> Enum.flat_map(fn
          {:ok, file} -> [file]
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp auto_send_files_from_meta(_), do: []

  defp normalize_auto_send_file(%{} = raw) do
    path = Map.get(raw, :path) || Map.get(raw, "path")
    filename = Map.get(raw, :filename) || Map.get(raw, "filename")
    caption = Map.get(raw, :caption) || Map.get(raw, "caption")

    cond do
      not is_binary(path) or path == "" ->
        :error

      not File.regular?(path) ->
        :error

      not (is_nil(caption) or is_binary(caption)) ->
        :error

      true ->
        {:ok,
         %{
           path: path,
           filename:
             case filename do
               x when is_binary(x) and x != "" -> x
               _ -> Path.basename(path)
             end,
           caption: caption
         }}
    end
  end

  defp normalize_auto_send_file(_), do: :error

  defp build_telegram_payload(parsed, kind, content, idempotency_key, opts) do
    struct!(LemonChannels.OutboundPayload,
      channel_id: "telegram",
      account_id: parsed.account_id || "default",
      peer: %{
        kind: parsed.peer_kind,
        id: parsed.peer_id,
        thread_id: parsed.thread_id
      },
      kind: kind,
      content: content,
      idempotency_key: idempotency_key,
      reply_to: Map.get(opts, :reply_to),
      meta: Map.get(opts, :meta, %{})
    )
  end

  defp meta_get(snapshot, key) when is_atom(key) do
    meta = snapshot.meta || %{}
    meta[key] || meta[Atom.to_string(key)]
  end

  defp parse_int(value), do: ChannelContext.parse_int(value)

  defp flush_image_batch(batches, []), do: batches
  defp flush_image_batch(batches, pending_images), do: [Enum.reverse(pending_images) | batches]

  defp image_file?(path) when is_binary(path),
    do:
      path |> Path.extname() |> String.downcase() |> then(&MapSet.member?(@image_extensions, &1))

  defp image_file?(_), do: false

  # ---- Resume token helpers ----

  defp show_resume_line? do
    case LemonChannels.GatewayConfig.get(:telegram, %{}) do
      %{} = cfg -> cfg[:show_resume_line] || cfg["show_resume_line"] || false
      _ -> false
    end
  rescue
    _ -> false
  end

  defp normalize_resume_token(nil), do: nil

  defp normalize_resume_token(%ResumeToken{} = tok), do: tok

  defp normalize_resume_token(%{engine: engine, value: value})
       when is_binary(engine) and is_binary(value) do
    %ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume_token(%{"engine" => engine, "value" => value})
       when is_binary(engine) and is_binary(value) do
    %ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume_token(_), do: nil

  defp resume_token_like?(%ResumeToken{engine: e, value: v})
       when is_binary(e) and is_binary(v),
       do: true

  defp resume_token_like?(%{engine: e, value: v}) when is_binary(e) and is_binary(v), do: true

  defp resume_token_like?(%{"engine" => e, "value" => v}) when is_binary(e) and is_binary(v),
    do: true

  defp resume_token_like?(_), do: false

  defp maybe_append_resume_line(text, nil), do: text

  defp maybe_append_resume_line(text, resume) when is_binary(text) do
    resume = normalize_resume_token(resume)

    if is_nil(resume) do
      text
    else
      text = String.trim_trailing(text)

      if resume_token_present?(text) do
        text
      else
        line = format_resume_line(resume)

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

  defp maybe_append_resume_line(text, _resume), do: text

  defp resume_token_present?(text) when is_binary(text) do
    match?({:ok, %ResumeToken{}}, LemonChannels.EngineRegistry.extract_resume(text))
  rescue
    _ -> false
  end

  defp format_resume_line(%ResumeToken{engine: engine, value: value})
       when is_binary(engine) and is_binary(value) do
    LemonChannels.EngineRegistry.format_resume(%ResumeToken{
      engine: String.downcase(engine),
      value: value
    })
  rescue
    _ -> "`#{engine} resume #{value}`"
  end

  defp extract_message_id_from_delivery({:ok, result}),
    do: extract_message_id_from_delivery(result)

  defp extract_message_id_from_delivery({:error, _}), do: nil
  defp extract_message_id_from_delivery(result) when is_integer(result), do: result

  defp extract_message_id_from_delivery(result) when is_binary(result) do
    case Integer.parse(result) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp extract_message_id_from_delivery(%{message_id: id}),
    do: extract_message_id_from_delivery(id)

  defp extract_message_id_from_delivery(%{"message_id" => id}),
    do: extract_message_id_from_delivery(id)

  defp extract_message_id_from_delivery(%{"result" => %{"message_id" => id}}),
    do: extract_message_id_from_delivery(id)

  defp extract_message_id_from_delivery(_), do: nil

  defp maybe_index_resume(_account_id, _chat_id, _thread_id, nil, _resume), do: :ok

  defp maybe_index_resume(account_id, chat_id, thread_id, message_id, resume) do
    resume = normalize_resume_token(resume)

    if resume_token_like?(resume) and Code.ensure_loaded?(LemonCore.Store) and
         function_exported?(LemonCore.Store, :put, 3) do
      key = {account_id || "default", chat_id, thread_id, message_id}
      LemonCore.Store.put(:telegram_msg_resume, key, resume)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_track_pending_resume(pending, notify_ref, account_id, chat_id, thread_id, resume)
       when is_reference(notify_ref) do
    pending = pending || %{}

    if resume_token_like?(resume) do
      normalized_resume = normalize_resume_token(resume)

      pending =
        pending
        |> Enum.reject(fn
          {_ref, %{kind: :final_send, account_id: acc, chat_id: cid, thread_id: tid}}
          when acc == account_id and cid == chat_id and tid == thread_id ->
            true

          _ ->
            false
        end)
        |> Map.new()

      pending =
        Map.put(pending, notify_ref, %{
          kind: :final_send,
          account_id: account_id,
          chat_id: chat_id,
          thread_id: thread_id,
          resume: normalized_resume,
          inserted_at_ms: System.system_time(:millisecond)
        })

      _ = schedule_pending_resume_cleanup(notify_ref, 1)
      pending
    else
      pending
    end
  end

  defp maybe_track_pending_resume(pending, _notify_ref, _account_id, _chat_id, _thread_id, _resume),
    do: pending || %{}

  defp pending_resume_cleanup_delay_ms(attempt) when is_integer(attempt) and attempt > 0 do
    delay_ms = trunc(@pending_resume_cleanup_base_ms * :math.pow(2, attempt - 1))
    min(delay_ms, @pending_resume_cleanup_max_backoff_ms)
  end

  defp pending_entry_age_ms(entry) when is_map(entry) do
    now = System.system_time(:millisecond)
    inserted_at_ms = Map.get(entry, :inserted_at_ms, now)
    max(now - inserted_at_ms, 0)
  end

  # ---- Task extra (ToolStatusRenderer) ----

  defp format_task_extra(action, rendered_title) do
    kind = normalize_kind(action[:kind] || action["kind"])
    detail = action[:detail] || action["detail"] || %{}
    args = extract_args(detail)
    tool_name = normalize_optional_string(map_get_any(detail, [:name, "name"]))

    task_like? =
      kind == "subagent" or
        String.downcase(tool_name || "") == "task" or
        generic_task_title?(rendered_title)

    if not task_like? do
      nil
    else
      task_engine =
        cond do
          is_map(args) and map_size(args) > 0 ->
            normalize_optional_string(map_get_any(args, [:engine, "engine"])) || "internal"

          kind == "subagent" ->
            "internal"

          true ->
            nil
        end

      role = normalize_optional_string(map_get_any(args, [:role, "role"]))
      desc = normalize_optional_string(map_get_any(args, [:description, "description"]))
      prompt = normalize_optional_string(map_get_any(args, [:prompt, "prompt"]))
      async = map_get_any(args, [:async, "async"])
      task_id = normalize_optional_string(map_get_any(args, [:task_id, "task_id"]))

      caller_engine = normalize_optional_string(action[:caller_engine] || action["caller_engine"])

      meta =
        []
        |> maybe_add_kv("engine", task_engine)
        |> maybe_add_kv("role", role)
        |> maybe_add_flag("async", async == true)
        |> maybe_add_kv("task_id", task_id)
        |> maybe_add_via(caller_engine, task_engine)
        |> Enum.join(" ")

      snippet =
        if generic_task_title?(rendered_title) do
          cond do
            is_binary(desc) and desc != "" ->
              " desc: " <> quote_snip(desc, 120)

            is_binary(prompt) and prompt != "" ->
              " prompt: " <> quote_snip(prompt, 120)

            true ->
              ""
          end
        else
          ""
        end

      if meta == "" and snippet == "" do
        nil
      else
        " (" <> meta <> ")" <> snippet
      end
    end
  rescue
    _ -> nil
  end

  # ---- Command extra (ToolStatusRenderer) ----

  defp format_command_extra(action, rendered_title) do
    kind = normalize_kind(action[:kind] || action["kind"])
    phase = action[:phase] || action["phase"]
    detail = action[:detail] || action["detail"] || %{}

    tool_name =
      normalize_optional_string(map_get_any(detail, [:name, "name"]))
      |> case do
        s when is_binary(s) -> String.downcase(s)
        _ -> ""
      end

    command_like? =
      kind == "command" or
        tool_name in ["bash", "shell", "killshell", "command", "exec"]

    if not command_like? do
      nil
    else
      cmd = extract_command_text(detail)
      status = normalize_optional_string(map_get_any(detail, [:status, "status"]))
      exit_code = map_get_any(detail, [:exit_code, "exit_code"])

      status_meta =
        []
        |> maybe_add_kv("status", status)
        |> maybe_add_kv("exit", normalize_exit_code(exit_code))
        |> Enum.join(" ")

      status_part =
        if status_meta == "" or phase not in [:completed, "completed"],
          do: "",
          else: " (#{status_meta})"

      cmd_part =
        cond do
          not is_binary(cmd) or String.trim(cmd) == "" ->
            ""

          title_already_shows_command?(rendered_title, cmd) ->
            ""

          true ->
            " cmd: " <> quote_snip(cmd, 120)
        end

      out = status_part <> cmd_part
      if out == "", do: nil, else: out
    end
  rescue
    _ -> nil
  end

  defp extract_command_text(detail) when is_map(detail) do
    args = map_get_any(detail, [:args, "args"])
    input = map_get_any(detail, [:input, "input"])
    arguments = map_get_any(detail, [:arguments, "arguments"])

    command =
      map_get_any(detail, [:command, "command"]) ||
        map_get_any(detail, [:cmd, "cmd"]) ||
        (is_map(args) &&
           (map_get_any(args, [:command, "command"]) || map_get_any(args, [:cmd, "cmd"]))) ||
        (is_map(input) &&
           (map_get_any(input, [:command, "command"]) || map_get_any(input, [:cmd, "cmd"]))) ||
        (is_map(arguments) &&
           (map_get_any(arguments, [:command, "command"]) || map_get_any(arguments, [:cmd, "cmd"])))

    normalize_optional_string(command)
  end

  defp extract_command_text(_), do: nil

  defp normalize_exit_code(code) when is_integer(code), do: Integer.to_string(code)

  defp normalize_exit_code(code) when is_binary(code) do
    code = String.trim(code)
    if code == "", do: nil, else: code
  end

  defp normalize_exit_code(_), do: nil

  defp title_already_shows_command?(title, cmd) when is_binary(title) and is_binary(cmd) do
    normalized_title = String.downcase(String.trim_leading(title, "$ ") |> String.trim())
    normalized_cmd = String.downcase(cmd |> truncate_one_line(120))

    normalized_title != "" and normalized_cmd != "" and
      (String.contains?(normalized_title, normalized_cmd) or
         String.starts_with?(normalized_title, String.slice(normalized_cmd, 0, 30)))
  rescue
    _ -> false
  end

  defp title_already_shows_command?(_, _), do: false

  # ---- Shared rendering helpers ----

  defp maybe_add_kv(parts, _k, v) when v in [nil, ""], do: parts
  defp maybe_add_kv(parts, k, v), do: parts ++ ["#{k}=#{v}"]

  defp maybe_add_flag(parts, _flag, false), do: parts
  defp maybe_add_flag(parts, flag, true), do: parts ++ [flag]

  defp maybe_add_via(parts, nil, _task_engine), do: parts

  defp maybe_add_via(parts, caller_engine, nil) do
    if caller_engine != "" do
      parts ++ ["via=#{caller_engine}"]
    else
      parts
    end
  end

  defp maybe_add_via(parts, caller_engine, task_engine) do
    if caller_engine != "" and caller_engine != task_engine do
      parts ++ ["via=#{caller_engine}"]
    else
      parts
    end
  end

  defp extract_args(detail) when is_map(detail) do
    args = map_get_any(detail, [:args, "args"])
    if is_map(args), do: args, else: %{}
  end

  defp extract_args(_), do: %{}

  defp generic_task_title?(title) when is_binary(title) do
    t = title |> String.trim()
    down = String.downcase(t)
    down == "task" or down == "task:" or down == "task tool" or down == "run task"
  end

  defp generic_task_title?(_), do: false

  defp quote_snip(text, max_len) when is_binary(text) do
    snip = truncate_one_line(text, max_len)
    "\"" <> snip <> "\""
  end

  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: kind
  defp normalize_kind(_), do: ""

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(s) when is_binary(s), do: String.trim(s)

  defp normalize_optional_string(other) do
    (LemonRouter.ToolPreview.to_text(other) || inspect(other))
    |> String.trim()
  rescue
    _ -> inspect(other) |> String.trim()
  end

  defp truncate_one_line(text, max_len) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, max_len)
  end

  defp truncate_one_line(other, _max_len) do
    LemonRouter.ToolPreview.to_text(other) || inspect(other)
  rescue
    _ -> inspect(other)
  end

  defp map_get_any(map, [k1, k2]) when is_map(map) do
    Map.get(map, k1) || Map.get(map, k2)
  end

  defp map_get_any(_map, _keys), do: nil

  # ---- Config helpers ----

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_, _), do: nil

  defp normalize_map(value) when is_map(value), do: value

  defp normalize_map(value) when is_list(value) do
    if Keyword.keyword?(value) do
      Enum.into(value, %{})
    else
      %{}
    end
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
