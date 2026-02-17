defmodule LemonRouter.ToolStatusCoalescer do
  @moduledoc """
  Coalesce tool/action lifecycle events into a single editable "Tool calls" message.

  This is intentionally separate from StreamCoalescer (answer streaming). Tool actions can
  run without producing output deltas, so we want a dedicated status surface.
  """

  use GenServer

  require Logger

  alias LemonRouter.ChannelContext
  alias LemonRouter.ChannelsDelivery

  @default_idle_ms 400
  @default_max_latency_ms 1200

  @max_actions 40
  @cancel_callback_prefix "lemon:cancel"

  defstruct [
    :session_key,
    :channel_id,
    :run_id,
    :actions,
    :order,
    :last_text,
    :first_event_ts,
    :flush_timer,
    :config,
    :meta,
    :seq,
    :finalized,
    # When creating an editable status message lazily, we wait for an outbox
    # delivery ack so we can capture the platform message_id and switch to edits.
    :status_create_ref,
    :deferred_text
  ]

  def start_link(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    channel_id = Keyword.fetch!(opts, :channel_id)
    name = via_tuple(session_key, channel_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  defp via_tuple(session_key, channel_id) do
    {:via, Registry, {LemonRouter.ToolStatusRegistry, {session_key, channel_id}}}
  end

  @doc """
  Ingest an action event into the tool status coalescer.

  Options:
  - `:meta` - may include `:status_msg_id` for edit mode
  """
  def ingest_action(session_key, channel_id, run_id, action_event, opts \\ []) do
    meta = Keyword.get(opts, :meta, %{})

    # Only start the coalescer for relevant events; avoids emitting tool-status
    # surfaces when the only actions are filtered (e.g. high-volume notes).
    case normalize_action_event(action_event) do
      {:skip, _reason} ->
        :ok

      {:ok, _id, _action_data} ->
        case get_or_start_coalescer(session_key, channel_id, meta) do
          {:ok, pid} ->
            GenServer.cast(pid, {:action, run_id, action_event, meta})

          {:error, reason} ->
            Logger.warning("Failed to start tool status coalescer: #{inspect(reason)}")
        end
    end

    :ok
  end

  @doc """
  Force flush the tool status message for a session/channel.
  """
  def flush(session_key, channel_id) do
    case Registry.lookup(LemonRouter.ToolStatusRegistry, {session_key, channel_id}) do
      [{pid, _}] -> GenServer.cast(pid, :flush)
      _ -> :ok
    end
  end

  @doc """
  Finalize the tool status for a run by marking any still-running actions as completed.

  This is a best-effort safeguard for transports like Telegram where the status surface
  is an editable message. If the engine emits `run_completed` before the final action
  completion events arrive (or if they're dropped), the status message can otherwise
  get stuck showing `[running]`.
  """
  def finalize_run(session_key, channel_id, run_id, ok?, opts \\ [])

  def finalize_run(session_key, channel_id, run_id, ok?, opts) when is_binary(run_id) do
    meta = Keyword.get(opts, :meta, %{})

    case get_or_start_coalescer(session_key, channel_id, meta) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, {:finalize_run, run_id, ok?, meta}, 2_000)
        catch
          :exit, _ -> :ok
        end

        :ok

      _ ->
        :ok
    end
  end

  def finalize_run(_session_key, _channel_id, _run_id, _ok?, _opts), do: :ok

  defp get_or_start_coalescer(session_key, channel_id, meta) do
    case Registry.lookup(LemonRouter.ToolStatusRegistry, {session_key, channel_id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {__MODULE__, session_key: session_key, channel_id: channel_id, meta: meta}

        case DynamicSupervisor.start_child(LemonRouter.ToolStatusSupervisor, spec) do
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
      idle_ms: Keyword.get(opts, :idle_ms, @default_idle_ms),
      max_latency_ms: Keyword.get(opts, :max_latency_ms, @default_max_latency_ms)
    }

    state = %__MODULE__{
      session_key: session_key,
      channel_id: channel_id,
      run_id: nil,
      actions: %{},
      order: [],
      last_text: nil,
      first_event_ts: nil,
      flush_timer: nil,
      config: config,
      meta: Keyword.get(opts, :meta, %{}),
      seq: 0,
      finalized: false,
      status_create_ref: nil,
      deferred_text: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:action, run_id, action_event, meta}, state) do
    now = System.system_time(:millisecond)

    state =
      if state.run_id != run_id do
        cancel_timer(state.flush_timer)

        %{
          state
          | run_id: run_id,
            actions: %{},
            order: [],
            last_text: nil,
            first_event_ts: nil,
            flush_timer: nil,
            seq: 0,
            finalized: false,
            # New run: do not carry forward prior run's message ids.
            meta: compact_meta(meta),
            status_create_ref: nil,
            deferred_text: nil
        }
      else
        # Same run: merge meta updates, but never allow nil values to wipe
        # platform message ids (e.g. Telegram status_msg_id).
        %{state | meta: Map.merge(state.meta || %{}, compact_meta(meta))}
      end

    # If we've already finalized this run, ignore late action events.
    if state.finalized == true and state.run_id == run_id do
      {:noreply, state}
    else
      state =
        case normalize_action_event(action_event) do
          {:skip, _reason} ->
            state

          {:ok, id, action_data} ->
            {actions, order} = upsert_action(state.actions, state.order, id, action_data)

            state = %{
              state
              | actions: actions,
                order: order,
                first_event_ts: state.first_event_ts || now
            }

            maybe_flush(state, now)
        end

      {:noreply, state}
    end
  end

  def handle_cast(:flush, state) do
    state = do_flush(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:finalize_run, run_id, ok?, meta}, _from, state) do
    state =
      cond do
        state.run_id == nil ->
          %{
            state
            | run_id: run_id,
              meta: compact_meta(meta),
              actions: %{},
              order: [],
              last_text: nil,
              first_event_ts: nil,
              flush_timer: nil,
              seq: 0,
              finalized: false,
              status_create_ref: nil,
              deferred_text: nil
          }

        state.run_id != run_id ->
          cancel_timer(state.flush_timer)

          %{
            state
            | run_id: run_id,
              actions: %{},
              order: [],
              last_text: nil,
              first_event_ts: nil,
              flush_timer: nil,
              seq: 0,
              finalized: false,
              # New run: do not carry forward prior run's message ids.
              meta: compact_meta(meta),
              status_create_ref: nil,
              deferred_text: nil
          }

        true ->
          %{state | meta: Map.merge(state.meta || %{}, compact_meta(meta))}
      end

    state =
      state
      |> Map.put(:finalized, true)
      |> finalize_running_actions(ok?)
      |> do_flush()

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    state = do_flush(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:outbox_delivered, ref, result}, state) when is_reference(ref) do
    state =
      if state.status_create_ref == ref do
        case extract_message_id_from_delivery(result) do
          nil ->
            %{state | status_create_ref: nil}

          msg_id ->
            meta = Map.put(state.meta || %{}, :status_msg_id, msg_id)
            state = %{state | meta: meta, status_create_ref: nil}

            case state.deferred_text do
              text when is_binary(text) and text != "" ->
                state = %{state | deferred_text: nil, seq: state.seq + 1}
                state = emit_output(state, text)
                %{state | last_text: text}

              _ ->
                state
            end
        end
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Avoid overriding previously-known message ids with nils coming from upstream meta.
  defp compact_meta(meta), do: ChannelContext.compact_meta(meta)

  defp maybe_flush(state, now) do
    time_since_first = now - (state.first_event_ts || now)

    cond do
      time_since_first >= state.config.max_latency_ms ->
        do_flush(state)

      true ->
        cancel_timer(state.flush_timer)
        timer = Process.send_after(self(), :idle_timeout, state.config.idle_ms)
        %{state | flush_timer: timer}
    end
  end

  defp do_flush(state) do
    cancel_timer(state.flush_timer)

    progress_msg_id = (state.meta || %{})[:progress_msg_id]

    text =
      cond do
        state.order == [] and state.finalized == true and is_integer(progress_msg_id) ->
          "Done"

        true ->
          state.channel_id
          |> LemonRouter.ToolStatusRenderer.render(state.actions, state.order)
          |> maybe_prefix_running(state)
      end

    state =
      cond do
        # Only send a tool-status message when we actually have tool/actions to show.
        state.order == [] and not (state.finalized == true and is_integer(progress_msg_id)) ->
          state

        text == state.last_text ->
          state

        true ->
          state = %{state | seq: state.seq + 1}
          state = emit_output(state, text)
          %{state | last_text: text}
      end

    %{state | first_event_ts: nil, flush_timer: nil}
  end

  defp finalize_running_actions(state, ok?) do
    actions =
      Enum.reduce(state.order, state.actions, fn id, acc ->
        case Map.get(acc, id) do
          %{phase: phase} = action when phase in [:started, :updated] ->
            Map.put(acc, id, %{action | phase: :completed, ok: ok?})

          %{"phase" => phase} = action when phase in [:started, :updated] ->
            Map.put(acc, id, Map.merge(action, %{"phase" => :completed, "ok" => ok?}))

          _ ->
            acc
        end
      end)

    %{state | actions: actions}
  end

  defp emit_output(state, text) do
    parsed = parse_session_key(state.session_key)

    status_msg_id = (state.meta || %{})[:status_msg_id]
    progress_msg_id = (state.meta || %{})[:progress_msg_id]
    target_msg_id = status_msg_id || progress_msg_id

    # For Telegram, prefer the Telegram outbox path (coalescing edits by key) via channels delivery.
    if state.channel_id == "telegram" and ChannelsDelivery.telegram_outbox_available?() do
      chat_id = parse_int(parsed.peer_id)
      thread_id = parse_int(parsed.thread_id)
      reply_markup = tool_status_reply_markup(state)

      cond do
        not is_integer(chat_id) ->
          state

        is_nil(target_msg_id) and is_reference(state.status_create_ref) ->
          # Creation is in flight; remember latest desired text and wait for ack.
          %{state | deferred_text: truncate_for_channel(state.channel_id, text)}

        is_integer(target_msg_id) ->
          edit_text = truncate_for_channel(state.channel_id, text)

          telegram_payload =
            if state.finalized == true do
              %{text: edit_text, reply_markup: %{"inline_keyboard" => []}}
            else
              %{text: edit_text}
            end

          fallback_payload =
            struct!(LemonChannels.OutboundPayload,
              channel_id: state.channel_id,
              account_id: parsed.account_id,
              peer: %{
                kind: parsed.peer_kind,
                id: parsed.peer_id,
                thread_id: parsed.thread_id
              },
              kind: :edit,
              content: %{message_id: target_msg_id, text: edit_text},
              reply_to: maybe_reply_to(state),
              idempotency_key: "#{state.run_id}:status:#{state.seq}",
              meta: %{
                run_id: state.run_id,
                session_key: state.session_key,
                status_seq: state.seq,
                reply_markup: tool_status_reply_markup(state)
              }
            )

          case ChannelsDelivery.telegram_enqueue(
                 {chat_id, target_msg_id, :edit},
                 0,
                 {:edit, chat_id, target_msg_id, telegram_payload},
                 fallback_payload,
                 context: %{component: :tool_status_coalescer, phase: :status_edit}
               ) do
            {:ok, _ref} ->
              :ok

            {:error, reason} ->
              Logger.warning("Failed to enqueue tool status edit: #{inspect(reason)}")
          end

          state

        true ->
          # Create the status message and wait for a delivery ack to capture message_id.
          notify_ref = make_ref()
          send_text = truncate_for_channel(state.channel_id, text)

          fallback_payload =
            struct!(LemonChannels.OutboundPayload,
              channel_id: state.channel_id,
              account_id: parsed.account_id,
              peer: %{
                kind: parsed.peer_kind,
                id: parsed.peer_id,
                thread_id: parsed.thread_id
              },
              kind: :text,
              content: send_text,
              reply_to: maybe_reply_to(state),
              idempotency_key: "#{state.run_id}:status:#{state.seq}",
              meta: %{
                run_id: state.run_id,
                session_key: state.session_key,
                status_seq: state.seq,
                reply_markup: tool_status_reply_markup(state)
              }
            )

          case ChannelsDelivery.telegram_enqueue_with_notify(
                 {chat_id, state.run_id, :status_create},
                 0,
                 {:send, chat_id,
                  %{
                    text: send_text,
                    reply_to_message_id: maybe_reply_to(state),
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
              %{state | status_create_ref: notify_ref}

            {:error, :duplicate} ->
              state

            {:error, :channels_outbox_unavailable} ->
              state

            {:error, reason} ->
              Logger.warning("Failed to enqueue tool status create: #{inspect(reason)}")
              state
          end
      end
    else
      cond do
        is_nil(status_msg_id) and is_reference(state.status_create_ref) ->
          # Creation is in flight; remember latest desired text and wait for ack.
          %{state | deferred_text: truncate_for_channel(state.channel_id, text)}

        true ->
          {kind, content, notify_pid, notify_ref} = get_output_kind_and_content(state, text)

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
              reply_to: maybe_reply_to(state),
              idempotency_key: "#{state.run_id}:status:#{state.seq}",
              meta: %{
                run_id: state.run_id,
                session_key: state.session_key,
                status_seq: state.seq,
                reply_markup: tool_status_reply_markup(state)
              },
              notify_pid: notify_pid,
              notify_ref: notify_ref
            )

          case ChannelsDelivery.enqueue(payload,
                 context: %{component: :tool_status_coalescer, phase: :status_output}
               ) do
            {:ok, _ref} ->
              if is_reference(notify_ref),
                do: %{state | status_create_ref: notify_ref},
                else: state

            {:error, :duplicate} ->
              state

            {:error, reason} ->
              Logger.warning("Failed to enqueue tool status output: #{inspect(reason)}")
              state
          end
      end
    end
  rescue
    _ -> state
  end

  defp maybe_prefix_running(text, %__MODULE__{} = state) when is_binary(text) do
    progress_msg_id = (state.meta || %{})[:progress_msg_id]

    if is_integer(progress_msg_id) and any_running_action?(state) do
      "Running…\n\n" <> text
    else
      text
    end
  end

  defp maybe_prefix_running(text, _state), do: text

  defp any_running_action?(%__MODULE__{} = state) do
    actions = state.actions || %{}
    order = state.order || []

    Enum.any?(order, fn id ->
      case Map.get(actions, id) do
        %{phase: phase} when phase in [:started, :updated] -> true
        %{"phase" => phase} when phase in [:started, :updated] -> true
        _ -> false
      end
    end)
  rescue
    _ -> false
  end

  defp get_output_kind_and_content(state, text) do
    supports_edit = channel_supports_edit?(state.channel_id)
    status_msg_id = (state.meta || %{})[:status_msg_id] || (state.meta || %{})[:progress_msg_id]

    cond do
      supports_edit and status_msg_id != nil ->
        {:edit,
         %{
           message_id: status_msg_id,
           text: truncate_for_channel(state.channel_id, text)
         }, nil, nil}

      true ->
        if supports_edit and is_nil(status_msg_id) do
          ref = make_ref()
          {:text, truncate_for_channel(state.channel_id, text), self(), ref}
        else
          {:text, truncate_for_channel(state.channel_id, text), nil, nil}
        end
    end
  end

  defp channel_supports_edit?(channel_id) do
    ChannelContext.channel_supports_edit?(channel_id)
  end

  defp normalize_action_event(ev) when is_map(ev) do
    action = Map.get(ev, :action) || %{}

    kind = Map.get(action, :kind)

    allowed_kinds = [
      "tool",
      "command",
      "file_change",
      "web_search",
      "subagent",
      :tool,
      :command,
      :file_change,
      :web_search,
      :subagent
    ]

    cond do
      # Filter out high-volume "note" actions (e.g. thinking blocks). Tool callers generally want
      # tool/action lifecycle + results.
      kind in ["note", :note] ->
        {:skip, :note}

      kind in allowed_kinds ->
        id = Map.get(action, :id)

        data = %{
          id: id,
          kind: kind,
          caller_engine: Map.get(ev, :engine),
          title: Map.get(action, :title),
          phase: Map.get(ev, :phase),
          ok: Map.get(ev, :ok),
          message: Map.get(ev, :message),
          level: Map.get(ev, :level),
          detail: Map.get(action, :detail)
        }

        if is_binary(id) and id != "" do
          {:ok, id, data}
        else
          {:skip, :missing_id}
        end

      true ->
        {:skip, :irrelevant_kind}
    end
  rescue
    _ -> {:skip, :bad_event}
  end

  defp normalize_action_event(_), do: {:skip, :unknown}

  defp upsert_action(actions, order, id, data) do
    actions = Map.put(actions, id, data)
    order = if id in order, do: order, else: order ++ [id]

    if length(order) > @max_actions do
      drop = length(order) - @max_actions
      {dropped, kept} = Enum.split(order, drop)
      actions = Enum.reduce(dropped, actions, fn old_id, acc -> Map.delete(acc, old_id) end)
      {actions, kept}
    else
      {actions, order}
    end
  end

  defp parse_session_key(session_key) do
    ChannelContext.parse_session_key(session_key)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp maybe_reply_to(state) do
    meta = state.meta || %{}
    meta[:user_msg_id] || meta["user_msg_id"]
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

  defp truncate_for_channel("telegram", text) when is_binary(text) do
    LemonChannels.Telegram.Truncate.truncate_for_telegram(text)
  rescue
    _ -> text
  end

  defp truncate_for_channel(_channel_id, text), do: text

  defp tool_status_reply_markup(%__MODULE__{finalized: true}) do
    %{"inline_keyboard" => []}
  end

  defp tool_status_reply_markup(%__MODULE__{run_id: run_id})
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

  defp tool_status_reply_markup(_), do: nil

  defp parse_int(value), do: ChannelContext.parse_int(value)
end
