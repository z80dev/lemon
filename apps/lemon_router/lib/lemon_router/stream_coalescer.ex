defmodule LemonRouter.StreamCoalescer do
  @moduledoc """
  Coalesces streaming deltas for efficient channel output.

  The coalescer buffers incoming deltas and flushes them to channels
  based on configurable thresholds:

  - `min_chars: 48` - Minimum characters before flushing
  - `idle_ms: 400` - Flush after this idle time
  - `max_latency_ms: 1200` - Maximum time before forced flush

  ## Output

  Produces outbound payloads to channels with:
  - Kind `:edit` if channel supports edits
  - Kind `:text` chunks otherwise
  """

  use GenServer

  require Logger

  @default_min_chars 48
  @default_idle_ms 400
  @default_max_latency_ms 1200
  @pending_resume_cleanup_base_ms 2_000
  @pending_resume_cleanup_max_attempts 4
  @pending_resume_cleanup_max_backoff_ms 30_000

  defstruct [
    :session_key,
    :channel_id,
    :run_id,
    :buffer,
    :full_text,
    :last_seq,
    :last_flush_ts,
    :first_delta_ts,
    :flush_timer,
    :config,
    :meta,
    :last_sent_text,
    :pending_resume_indices,
    :finalized
  ]

  def start_link(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    channel_id = Keyword.fetch!(opts, :channel_id)
    name = via_tuple(session_key, channel_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  defp via_tuple(session_key, channel_id) do
    {:via, Registry, {LemonRouter.CoalescerRegistry, {session_key, channel_id}}}
  end

  @doc """
  Ingest a delta into the coalescer.

  ## Options

  - `:meta` - Optional metadata map, can include `:progress_msg_id` for edit mode
  """
  @spec ingest_delta(
          session_key :: binary(),
          channel_id :: binary(),
          run_id :: binary(),
          seq :: non_neg_integer(),
          text :: binary(),
          opts :: keyword()
        ) :: :ok
  def ingest_delta(session_key, channel_id, run_id, seq, text, opts \\ []) do
    meta = Keyword.get(opts, :meta, %{})

    # Start or get coalescer
    case get_or_start_coalescer(session_key, channel_id, meta) do
      {:ok, pid} ->
        GenServer.cast(pid, {:delta, run_id, seq, text, meta})

      {:error, reason} ->
        Logger.warning("Failed to start coalescer: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Finalize a run for a session/channel.

  For Telegram, this sends the final answer as a new message.
  """
  @spec finalize_run(
          session_key :: binary(),
          channel_id :: binary(),
          run_id :: binary(),
          opts :: keyword()
        ) :: :ok
  def finalize_run(session_key, channel_id, run_id, opts \\ [])
      when is_binary(session_key) and is_binary(channel_id) and is_binary(run_id) do
    meta = Keyword.get(opts, :meta, %{})
    final_text = Keyword.get(opts, :final_text)

    case get_or_start_coalescer(session_key, channel_id, meta) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, {:finalize, run_id, meta, final_text}, 5_000)
        catch
          :exit, _ -> :ok
        end

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Force flush the coalescer buffer.
  """
  @spec flush(session_key :: binary(), channel_id :: binary()) :: :ok
  def flush(session_key, channel_id) do
    case Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, channel_id}) do
      [{pid, _}] -> GenServer.cast(pid, :flush)
      _ -> :ok
    end
  end

  defp get_or_start_coalescer(session_key, channel_id, meta) do
    case Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, channel_id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {__MODULE__, session_key: session_key, channel_id: channel_id, meta: meta}

        case DynamicSupervisor.start_child(LemonRouter.CoalescerSupervisor, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  @impl true
  def init(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    channel_id = Keyword.fetch!(opts, :channel_id)

    config = %{
      min_chars: Keyword.get(opts, :min_chars, @default_min_chars),
      idle_ms: Keyword.get(opts, :idle_ms, @default_idle_ms),
      max_latency_ms: Keyword.get(opts, :max_latency_ms, @default_max_latency_ms)
    }

    state = %__MODULE__{
      session_key: session_key,
      channel_id: channel_id,
      run_id: nil,
      buffer: "",
      full_text: "",
      last_seq: 0,
      last_flush_ts: nil,
      first_delta_ts: nil,
      flush_timer: nil,
      config: config,
      meta: Keyword.get(opts, :meta, %{}),
      last_sent_text: nil,
      pending_resume_indices: %{},
      finalized: false
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:delta, run_id, seq, text, meta}, state) do
    now = System.system_time(:millisecond)

    # Reset if run changed
    state =
      if state.run_id != run_id do
        cancel_timer(state.flush_timer)

        %{
          state
          | run_id: run_id,
            buffer: "",
            full_text: "",
            last_seq: 0,
            first_delta_ts: nil,
            flush_timer: nil,
            # New run: do not carry forward prior run's message ids.
            meta: compact_meta(meta),
            last_sent_text: nil,
            # Don't drop pending resume-index entries: final sends can still be in-flight.
            pending_resume_indices: state.pending_resume_indices || %{},
            finalized: false
        }
      else
        # Update meta if provided (e.g., progress_msg_id may come in later)
        # Never let nil values wipe known ids (e.g. progress_msg_id).
        %{state | meta: Map.merge(state.meta || %{}, compact_meta(meta))}
      end

    # If we've already finalized this run, ignore late deltas.
    if state.finalized == true and state.run_id == run_id do
      {:noreply, state}
    else
      # Only accept in-order deltas
      if seq <= state.last_seq do
        {:noreply, state}
      else
        new_full = cap_full_text(state.full_text <> text)

        state = %{
          state
          | buffer: state.buffer <> text,
            full_text: new_full,
            last_seq: seq,
            first_delta_ts: state.first_delta_ts || now
        }

        state = maybe_flush(state, now)
        {:noreply, state}
      end
    end
  end

  # Handle legacy delta messages without meta
  def handle_cast({:delta, run_id, seq, text}, state) do
    handle_cast({:delta, run_id, seq, text, %{}}, state)
  end

  def handle_cast(:flush, state) do
    state = do_flush(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:finalize, run_id, meta, final_text}, _from, state) do
    # Ensure state is aligned with the run we're finalizing.
    state =
      cond do
        state.run_id == nil ->
          %{
            state
            | run_id: run_id,
              meta: compact_meta(meta),
              finalized: false
          }

        state.run_id != run_id ->
          # New run with no streamed deltas yet. Reset to the incoming run so
          # finalization uses the correct run_id/progress_msg_id.
          cancel_timer(state.flush_timer)

          %{
            state
            | run_id: run_id,
              buffer: "",
              full_text: "",
              last_seq: 0,
              first_delta_ts: nil,
              flush_timer: nil,
              meta: compact_meta(meta),
              last_sent_text: nil,
              pending_resume_indices: state.pending_resume_indices || %{},
              finalized: false
          }

        true ->
          %{state | meta: Map.merge(state.meta || %{}, compact_meta(meta))}
      end

    state = do_finalize(state, final_text)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    state = do_flush(state)
    {:noreply, state}
  end

  def handle_info({:outbox_delivered, ref, result}, state) when is_reference(ref) do
    {entry, pending} = Map.pop(state.pending_resume_indices || %{}, ref)

    state =
      case entry do
        %{account_id: account_id, chat_id: chat_id, thread_id: thread_id, resume: resume} ->
          message_id = extract_message_id_from_delivery(result)

          _ =
            maybe_index_resume(
              account_id,
              chat_id,
              thread_id,
              message_id,
              resume
            )

          %{state | pending_resume_indices: pending}

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:pending_resume_cleanup_timeout, ref, attempt}, state)
      when is_reference(ref) and is_integer(attempt) and attempt > 0 do
    pending = state.pending_resume_indices || %{}

    state =
      case Map.get(pending, ref) do
        %{kind: :final_send} = entry ->
          maybe_cleanup_pending_resume_index(state, ref, entry, attempt)

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Avoid overriding previously-known message ids with nils coming from upstream meta.
  defp compact_meta(meta) when is_map(meta) do
    Map.reject(meta, fn {_k, v} -> is_nil(v) end)
  end

  defp compact_meta(_), do: %{}

  defp maybe_flush(state, now) do
    buffer_len = String.length(state.buffer)
    time_since_first = now - (state.first_delta_ts || now)

    cond do
      # Flush if buffer exceeds min_chars
      buffer_len >= state.config.min_chars ->
        do_flush(state)

      # Flush if max latency exceeded
      time_since_first >= state.config.max_latency_ms ->
        do_flush(state)

      # Otherwise, set/reset idle timer
      true ->
        cancel_timer(state.flush_timer)
        timer = Process.send_after(self(), :idle_timeout, state.config.idle_ms)
        %{state | flush_timer: timer}
    end
  end

  defp do_flush(%{buffer: ""} = state), do: state

  defp do_flush(state) do
    # Emit the buffered content
    state = emit_output(state)

    cancel_timer(state.flush_timer)

    %{
      state
      | buffer: "",
        first_delta_ts: nil,
        last_flush_ts: System.system_time(:millisecond),
        flush_timer: nil
    }
  end

  defp emit_output(state) do
    # Parse session key using canonical format
    parsed = parse_session_key(state.session_key)

    # Broadcast to session topic for any local subscribers
    if is_pid(Process.whereis(LemonCore.PubSub)) do
      LemonCore.Bus.broadcast(
        LemonCore.Bus.session_topic(state.session_key),
        %{
          type: :coalesced_output,
          session_key: state.session_key,
          channel_id: state.channel_id,
          run_id: state.run_id,
          text: state.buffer,
          seq: state.last_seq
        }
      )
    end

    # Determine output kind and content based on channel capabilities
    {kind, content} = get_output_kind_and_content(state)

    state =
      case {state.channel_id, kind, content} do
        {"telegram", :edit, %{message_id: msg_id, text: text}}
        when is_integer(msg_id) and is_binary(text) ->
          # Skip redundant edits (saves rate limit + improves perceived snappiness).
          if text == state.last_sent_text do
            state
          else
            chat_id = parse_int(parsed.peer_id)

            if is_integer(chat_id) and is_pid(Process.whereis(LemonGateway.Telegram.Outbox)) do
              key = {chat_id, msg_id, :edit}

              LemonGateway.Telegram.Outbox.enqueue(
                key,
                0,
                {:edit, chat_id, msg_id, %{text: text}}
              )

              %{state | last_sent_text: text}
            else
              state
            end
          end

        _ ->
          state
      end

    skip_channels_outbox? =
      case {state.channel_id, kind, content} do
        {"telegram", :edit, %{message_id: _msg_id, text: _text}} ->
          chat_id = parse_int(parsed.peer_id)
          is_integer(chat_id) and is_pid(Process.whereis(LemonGateway.Telegram.Outbox))

        _ ->
          false
      end

    # Fallback: enqueue to LemonChannels.Outbox (used for non-Telegram channels and as a
    # safety net if the Telegram outbox isn't running).
    if is_pid(Process.whereis(LemonChannels.Outbox)) and not skip_channels_outbox? do
      payload =
        struct!(LemonChannels.OutboundPayload,
          channel_id: state.channel_id,
          account_id: parsed.account_id,
          peer: %{
            kind: parsed.peer_kind,
            id: parsed.peer_id,
            thread_id: parsed.thread_id
          },
          kind: kind,
          content: content,
          idempotency_key: "#{state.run_id}:#{state.last_seq}",
          meta: %{
            run_id: state.run_id,
            session_key: state.session_key,
            seq: state.last_seq
          }
        )

      case LemonChannels.Outbox.enqueue(payload) do
        {:ok, _ref} ->
          :ok

        {:error, :duplicate} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to enqueue coalesced output: #{inspect(reason)}")
      end
    end

    state
  end

  defp do_finalize(state, final_text) do
    cond do
      state.channel_id != "telegram" ->
        # Telegram finalization is special-cased below.
        state

      true ->
        resume = (state.meta || %{})[:resume] || (state.meta || %{})["resume"]

        text =
          cond do
            is_binary(final_text) and final_text != "" -> final_text
            is_binary(state.full_text) and state.full_text != "" -> state.full_text
            is_binary(state.buffer) and state.buffer != "" -> state.buffer
            true -> ""
          end

        # By default keep Telegram output clean; enable the footer in config if desired.
        text =
          if telegram_show_resume_line?(), do: maybe_append_resume_line(text, resume), else: text

        progress_msg_id = (state.meta || %{})[:progress_msg_id]
        reply_to = (state.meta || %{})[:user_msg_id]

        parsed = parse_session_key(state.session_key)

        chat_id = parse_int(parsed.peer_id)
        thread_id = parse_int(parsed.thread_id)
        account_id = parsed.account_id || "default"

        state =
          if is_integer(chat_id) and is_pid(Process.whereis(LemonGateway.Telegram.Outbox)) do
            # Always remove the initial progress message so it can't remain stuck.
            if is_integer(progress_msg_id) do
              LemonGateway.Telegram.Outbox.enqueue(
                {chat_id, progress_msg_id, :delete},
                -1,
                {:delete, chat_id, progress_msg_id}
              )
            end

            state =
              if text != "" do
                notify_ref = make_ref()

                # Also enqueue a notifyable send so we can index the bot's final message_id for reply-based resumes.
                pending = state.pending_resume_indices || %{}

                pending =
                  if resume_token_like?(resume) do
                    normalized_resume = normalize_resume_token(resume)

                    # If finalize is called more than once for the same chat/thread, keep only the latest pending index.
                    pending =
                      pending
                      |> Enum.reject(fn
                        {_ref,
                         %{kind: :final_send, account_id: acc, chat_id: cid, thread_id: tid}}
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

                LemonGateway.Telegram.Outbox.enqueue_with_notify(
                  {chat_id, state.run_id, :final_send},
                  1,
                  {:send, chat_id,
                   %{
                     text: text,
                     reply_to_message_id: reply_to,
                     message_thread_id: thread_id
                   }},
                  self(),
                  notify_ref,
                  :outbox_delivered
                )

                %{state | pending_resume_indices: pending}
              else
                state
              end

            state
          else
            if is_pid(Process.whereis(LemonChannels.Outbox)) do
              # Always remove the initial progress message so it can't remain stuck.
              if progress_msg_id != nil do
                delete_payload =
                  struct!(LemonChannels.OutboundPayload,
                    channel_id: state.channel_id,
                    account_id: parsed.account_id,
                    peer: %{
                      kind: parsed.peer_kind,
                      id: parsed.peer_id,
                      thread_id: parsed.thread_id
                    },
                    kind: :delete,
                    content: %{message_id: progress_msg_id},
                    idempotency_key: "#{state.run_id}:final:delete",
                    meta: %{
                      run_id: state.run_id,
                      session_key: state.session_key,
                      final: true
                    }
                  )

                _ = LemonChannels.Outbox.enqueue(delete_payload)
              end

              if text != "" do
                send_payload =
                  struct!(LemonChannels.OutboundPayload,
                    channel_id: state.channel_id,
                    account_id: parsed.account_id,
                    peer: %{
                      kind: parsed.peer_kind,
                      id: parsed.peer_id,
                      thread_id: parsed.thread_id
                    },
                    kind: :text,
                    content: text,
                    reply_to: reply_to,
                    idempotency_key: "#{state.run_id}:final:send",
                    meta: %{
                      run_id: state.run_id,
                      session_key: state.session_key,
                      final: true
                    }
                  )

                _ = LemonChannels.Outbox.enqueue(send_payload)
              end
            end

            state
          end

        state = maybe_enqueue_auto_send_files(state, parsed, reply_to)

        cancel_timer(state.flush_timer)

        %{
          state
          | buffer: "",
            full_text: "",
            first_delta_ts: nil,
            flush_timer: nil,
            last_sent_text: nil,
            finalized: true
        }
    end
  rescue
    _ ->
      state
  end

  defp normalize_resume_token(nil), do: nil

  defp normalize_resume_token(%LemonGateway.Types.ResumeToken{} = tok), do: tok

  defp normalize_resume_token(%{engine: engine, value: value})
       when is_binary(engine) and is_binary(value) do
    %LemonGateway.Types.ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume_token(%{"engine" => engine, "value" => value})
       when is_binary(engine) and is_binary(value) do
    %LemonGateway.Types.ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume_token(_), do: nil

  defp resume_token_like?(%LemonGateway.Types.ResumeToken{engine: e, value: v})
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
    case AgentCore.CliRunners.Types.ResumeToken.extract_resume(text) do
      %AgentCore.CliRunners.Types.ResumeToken{} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp format_resume_line(%LemonGateway.Types.ResumeToken{engine: engine, value: value})
       when is_binary(engine) and is_binary(value) do
    engine = String.downcase(engine)

    AgentCore.CliRunners.Types.ResumeToken.new(engine, value)
    |> AgentCore.CliRunners.Types.ResumeToken.format()
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

  defp maybe_cleanup_pending_resume_index(state, ref, entry, attempt) do
    pending = state.pending_resume_indices || %{}

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
      state
    else
      Logger.warning(
        "Cleaning stale pending resume index after missing :outbox_delivered " <>
          "(chat_id=#{inspect(Map.get(entry, :chat_id))} thread_id=#{inspect(Map.get(entry, :thread_id))} " <>
          "attempt=#{attempt}/#{@pending_resume_cleanup_max_attempts} " <>
          "age_ms=#{pending_entry_age_ms(entry)})"
      )

      %{state | pending_resume_indices: Map.delete(pending, ref)}
    end
  end

  defp schedule_pending_resume_cleanup(ref, attempt)
       when is_reference(ref) and is_integer(attempt) and attempt > 0 do
    Process.send_after(
      self(),
      {:pending_resume_cleanup_timeout, ref, attempt},
      pending_resume_cleanup_delay_ms(attempt)
    )

    :ok
  end

  defp pending_resume_cleanup_delay_ms(attempt) when is_integer(attempt) and attempt > 0 do
    delay_ms = trunc(@pending_resume_cleanup_base_ms * :math.pow(2, attempt - 1))
    min(delay_ms, @pending_resume_cleanup_max_backoff_ms)
  end

  defp pending_entry_age_ms(entry) when is_map(entry) do
    now = System.system_time(:millisecond)
    inserted_at_ms = Map.get(entry, :inserted_at_ms, now)
    max(now - inserted_at_ms, 0)
  end

  # Determine output kind and content based on channel capabilities
  # For :edit kind, content must be %{message_id, text} per Telegram outbound contract
  defp get_output_kind_and_content(state) do
    supports_edit = channel_supports_edit?(state.channel_id)
    progress_msg_id = (state.meta || %{})[:progress_msg_id]

    cond do
      supports_edit and progress_msg_id != nil ->
        # Edit mode requires message_id and text
        {:edit,
         %{
           message_id: progress_msg_id,
           text: truncate_for_channel(state.channel_id, state.full_text)
         }}

      supports_edit ->
        # Edit mode but no message_id yet - send as text first
        {:text, state.buffer}

      true ->
        {:text, state.buffer}
    end
  end

  # Check if channel supports editing messages
  defp channel_supports_edit?(channel_id) do
    if is_pid(Process.whereis(LemonChannels.Registry)) do
      case LemonChannels.Registry.get_capabilities(channel_id) do
        # Use the correct capability key: edit_support (not supports_edit)
        %{edit_support: true} -> true
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp parse_session_key(session_key) do
    case LemonRouter.SessionKey.parse(session_key) do
      {:error, _} -> fallback_parse_session_key(session_key)
      parsed -> parsed
    end
  end

  defp telegram_show_resume_line? do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      case LemonGateway.Config.get(:telegram) do
        %{} = cfg -> cfg[:show_resume_line] || cfg["show_resume_line"] || false
        _ -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp parse_int(nil), do: nil

  defp parse_int(v) when is_integer(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp maybe_enqueue_auto_send_files(state, parsed, reply_to) do
    files = auto_send_files_from_meta(state.meta)

    if files == [] or not is_pid(Process.whereis(LemonChannels.Outbox)) do
      state
    else
      Enum.with_index(files)
      |> Enum.each(fn {file, idx} ->
        payload =
          struct!(LemonChannels.OutboundPayload,
            channel_id: state.channel_id,
            account_id: parsed.account_id,
            peer: %{
              kind: parsed.peer_kind,
              id: parsed.peer_id,
              thread_id: parsed.thread_id
            },
            kind: :file,
            content: %{
              path: file.path,
              filename: file.filename,
              caption: file.caption
            },
            reply_to: if(idx == 0, do: reply_to, else: nil),
            idempotency_key: "#{state.run_id}:final:file:#{idx}",
            meta: %{
              run_id: state.run_id,
              session_key: state.session_key,
              final: true,
              auto_send_generated: true
            }
          )

        case LemonChannels.Outbox.enqueue(payload) do
          {:ok, _ref} ->
            :ok

          {:error, :duplicate} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to enqueue auto-sent file: #{inspect(reason)}")
        end
      end)

      state
    end
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

  # Fallback parsing for when SessionKey module is not available
  defp fallback_parse_session_key(session_key) do
    case String.split(session_key, ":") do
      # Canonical format: agent:<agent_id>:<channel_id>:<account_id>:<peer_kind>:<peer_id>[:thread:<thread_id>]
      ["agent", agent_id, channel_id, account_id, peer_kind, peer_id | rest] ->
        thread_id = extract_thread_id(rest)

        %{
          agent_id: agent_id,
          kind: :channel_peer,
          channel_id: channel_id,
          account_id: account_id,
          peer_kind: safe_to_atom(peer_kind),
          peer_id: peer_id,
          thread_id: thread_id
        }

      # Main session format: agent:<agent_id>:main
      ["agent", agent_id, "main"] ->
        %{
          agent_id: agent_id,
          kind: :main,
          channel_id: nil,
          account_id: agent_id,
          peer_kind: :main,
          peer_id: "main",
          thread_id: nil
        }

      # Legacy format: channel:telegram:bot:<chat_id>[:thread:<thread_id>]
      ["channel", "telegram", transport, chat_id | rest] ->
        thread_id = extract_thread_id(rest)

        %{
          agent_id: "default",
          kind: :channel_peer,
          channel_id: "telegram",
          account_id: transport,
          peer_kind: :dm,
          peer_id: chat_id,
          thread_id: thread_id
        }

      _ ->
        # Unknown format - use session_key as fallback
        %{
          agent_id: "unknown",
          kind: :unknown,
          channel_id: nil,
          account_id: "unknown",
          peer_kind: :unknown,
          peer_id: session_key,
          thread_id: nil
        }
    end
  end

  defp extract_thread_id(["thread", thread_id | _]), do: thread_id
  defp extract_thread_id(_), do: nil

  # Allowed peer_kind values - whitelist to prevent atom exhaustion
  # Mirrors LemonRouter.SessionKey.@allowed_peer_kinds
  @allowed_peer_kinds %{
    "dm" => :dm,
    "group" => :group,
    "channel" => :channel,
    "main" => :main,
    "unknown" => :unknown
  }

  # Safely convert peer_kind string to atom using whitelist
  # Falls back to :unknown for unrecognized values instead of creating new atoms
  defp safe_to_atom(str) when is_binary(str) do
    Map.get(@allowed_peer_kinds, str, :unknown)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  # Prevent unbounded memory growth for long streaming runs.
  @max_full_text 100_000
  defp cap_full_text(text) when is_binary(text) and byte_size(text) > @max_full_text do
    # Keep the tail; Telegram edits are truncated anyway.
    keep = @max_full_text
    String.slice(text, String.length(text) - keep, keep)
  end

  defp cap_full_text(text), do: text

  defp truncate_for_channel("telegram", text) when is_binary(text) do
    LemonGateway.Telegram.Truncate.truncate_for_telegram(text)
  rescue
    _ -> text
  end

  defp truncate_for_channel(_channel_id, text), do: text
end
