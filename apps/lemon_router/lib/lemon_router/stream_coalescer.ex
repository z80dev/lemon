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

  For Telegram, this converts the last update into:
  1) delete the initial "Running..." progress message
  2) send the final answer as a new message

  This ensures the final answer appears *after* any tool-call/status messages
  that were sent as separate messages during the run.
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
          %{state | run_id: run_id, meta: compact_meta(meta), finalized: false}

        state.run_id != run_id ->
          # Different run in this coalescer; don't try to finalize it.
          state

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
    emit_output(state)

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

    # Also enqueue to LemonChannels.Outbox for delivery
    if is_pid(Process.whereis(LemonChannels.Outbox)) do
      # Determine output kind and content based on channel capabilities
      {kind, content} = get_output_kind_and_content(state)

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

        # Already delivered
        {:error, :duplicate} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to enqueue coalesced output: #{inspect(reason)}")
      end
    end
  end

  defp do_finalize(state, final_text) do
    cond do
      state.channel_id != "telegram" ->
        # Only Telegram needs the "delete Running... then send final" behavior.
        state

      true ->
        text =
          cond do
            is_binary(final_text) and final_text != "" -> final_text
            is_binary(state.full_text) and state.full_text != "" -> state.full_text
            is_binary(state.buffer) and state.buffer != "" -> state.buffer
            true -> ""
          end

        progress_msg_id = (state.meta || %{})[:progress_msg_id]
        reply_to = (state.meta || %{})[:user_msg_id]

        parsed = parse_session_key(state.session_key)

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

        cancel_timer(state.flush_timer)

        %{
          state
          | buffer: "",
            full_text: "",
            first_delta_ts: nil,
            flush_timer: nil,
            finalized: true
        }
    end
  rescue
    _ ->
      state
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
