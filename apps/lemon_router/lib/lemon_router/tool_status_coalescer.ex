defmodule LemonRouter.ToolStatusCoalescer do
  @moduledoc """
  Coalesce tool/action lifecycle events into a single editable "Tool calls" message.

  This is intentionally separate from StreamCoalescer (answer streaming). Tool actions can
  run without producing output deltas, so we want a dedicated status surface.

  Channel-specific presentation is handled by `LemonChannels.Dispatcher`.

  ## Lifetime and retention

  A coalescer exists per surface only while it has work: finalizing a run
  without one starts nothing, finalizing drops the run's actions, and an idle
  coalescer whose run is finalized, never started or has no live producer
  (`RunProcess` or async task-surface subscriber) stops normally after the
  retirement grace (`LemonRouter.CoalescerIngress`). A segment retains at most
  64 actions, keeping only the detail fields rendering needs.
  """

  use GenServer, restart: :transient

  require Logger

  alias LemonChannels.Dispatcher
  alias LemonCore.DeliveryIntent
  alias LemonRouter.ChannelContext
  alias LemonRouter.CoalescerIngress
  alias LemonRouter.DeliveryRouteResolver

  @default_idle_ms 400
  @default_max_latency_ms 1200
  @status_text_max_length 4096

  # Retained actions per segment. A status message is one 4,096-character
  # message (`@status_text_max_length`) of action lines titled up to 80
  # characters, so it can display fewer than 64 lines; older lines are already
  # summarized as "(N tools omitted)". Evicted actions keep counting there.
  @max_retained_actions 64
  # Failed-action result previews render at most 140 characters after
  # whitespace collapsing; keep a bounded prefix instead of the whole result.
  @retained_preview_chars 1_024
  @failure_meta_keys [
    :error_type,
    :tool_name,
    :reason,
    :errors,
    :timeout_ms,
    :exit_code,
    :exception,
    :message,
    :status
  ]

  defstruct [
    :session_key,
    :channel_id,
    :surface,
    :run_id,
    :actions,
    :order,
    :prefix_text,
    :last_text,
    :last_kind,
    :first_event_ts,
    :flush_timer,
    :config,
    :meta,
    :seq,
    :finalized,
    :run_started_at,
    :delivery,
    :retire_after_ms,
    :last_activity_ms,
    omitted_actions: 0,
    overflowed: false
  ]

  def start_link(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    channel_id = Keyword.fetch!(opts, :channel_id)
    surface = Keyword.get(opts, :surface, :status)
    name = via_tuple(session_key, channel_id, surface)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  defp via_tuple(session_key, channel_id, surface) do
    {:via, Registry,
     {LemonRouter.ToolStatusRegistry, registry_key(session_key, channel_id, surface)}}
  end

  @doc """
  Ingest an action event into the tool status coalescer.

  Options:
  - `:meta` - semantic delivery metadata (for example `:user_msg_id`)
  - `:surface` - semantic presentation surface, defaults to `:status`
  """
  def ingest_action(session_key, channel_id, run_id, action_event, opts \\ []) do
    meta = Keyword.get(opts, :meta, %{})
    surface = Keyword.get(opts, :surface, :status)

    case normalize_action_event(action_event) do
      {:skip, _reason} ->
        :ok

      {:ok, _id, action_data} ->
        if chat_visible_action?(channel_id, action_data) do
          start_action_coalescer(session_key, channel_id, run_id, action_event, meta, surface)
        end
    end

    :ok
  end

  defp start_action_coalescer(session_key, channel_id, run_id, action_event, meta, surface) do
    case CoalescerIngress.push(
           LemonRouter.ToolStatusRegistry,
           registry_key(session_key, channel_id, surface),
           run_id,
           {:action, run_id, action_event, meta},
           fn -> start_coalescer(session_key, channel_id, surface, meta) end
         ) do
      {:error, reason} ->
        Logger.warning("Failed to start tool status coalescer: #{inspect(reason)}")

      :ok ->
        :ok
    end
  end

  @doc """
  Ingest a projected child action into a parent-owned task surface.

  This is a narrow wrapper over normal action ingestion so callers can be
  explicit that the event originated from a bridged child run rather than the
  parent run's native engine event stream.
  """
  def ingest_projected_child_action(
        session_key,
        channel_id,
        parent_run_id,
        surface,
        projected_event,
        opts \\ []
      ) do
    ingest_action(
      session_key,
      channel_id,
      parent_run_id,
      projected_event,
      Keyword.merge(opts, surface: surface)
    )
  end

  @doc """
  Force flush the tool status message for a session/channel.
  """
  def flush(session_key, channel_id, opts \\ []) do
    surface = Keyword.get(opts, :surface, :status)

    CoalescerIngress.push(
      LemonRouter.ToolStatusRegistry,
      registry_key(session_key, channel_id, surface),
      nil,
      :flush
    )
  end

  defp equivalent_action_id(actions, data) when is_map(actions) and is_map(data) do
    Enum.find_value(actions, fn {existing_id, existing_data} ->
      if equivalent_action?(existing_data, data), do: existing_id, else: nil
    end)
  end

  defp equivalent_action_id(_, _), do: nil

  defp equivalent_action?(existing, incoming) when is_map(existing) and is_map(incoming) do
    existing_detail = existing[:detail] || %{}
    incoming_detail = incoming[:detail] || %{}

    existing_child_run_id = existing_detail[:child_run_id] || existing_detail["child_run_id"]
    incoming_child_run_id = incoming_detail[:child_run_id] || incoming_detail["child_run_id"]

    existing_parent =
      existing_detail[:parent_tool_use_id] || existing_detail["parent_tool_use_id"]

    incoming_parent =
      incoming_detail[:parent_tool_use_id] || incoming_detail["parent_tool_use_id"]

    is_binary(existing_child_run_id) and is_binary(incoming_child_run_id) and
      existing_child_run_id == incoming_child_run_id and existing_parent == incoming_parent and
      normalize_embedded_kind(to_string(existing[:kind])) ==
        normalize_embedded_kind(to_string(incoming[:kind])) and
      normalize_title(existing[:title]) == normalize_title(incoming[:title])
  end

  defp equivalent_action?(_, _), do: false

  defp normalize_title(title) when is_binary(title), do: String.trim(title)
  defp normalize_title(title), do: title |> to_string() |> String.trim()

  @doc """
  Attach subsequent tool status updates to the latest assistant text chunk.
  """
  def anchor_segment(session_key, channel_id, run_id, prefix_text, opts \\ [])

  def anchor_segment(session_key, channel_id, run_id, prefix_text, opts)
      when is_binary(run_id) and is_binary(prefix_text) do
    meta = Keyword.get(opts, :meta, %{})
    surface = Keyword.get(opts, :surface, :status)

    _ =
      call(
        registry_key(session_key, channel_id, surface),
        {:anchor_segment, run_id, prefix_text, meta},
        fn -> start_coalescer(session_key, channel_id, surface, meta) end
      )

    :ok
  catch
    :exit, _ -> :ok
  end

  def anchor_segment(_session_key, _channel_id, _run_id, _prefix_text, _opts), do: :ok

  @doc """
  Finalize the current tool-status segment without marking running actions complete.
  """
  def commit_segment(session_key, channel_id, run_id, opts \\ [])

  def commit_segment(session_key, channel_id, run_id, opts) when is_binary(run_id) do
    meta = Keyword.get(opts, :meta, %{})
    surface = Keyword.get(opts, :surface, :status)
    _ = call(registry_key(session_key, channel_id, surface), {:commit_segment, run_id, meta})
    :ok
  catch
    :exit, _ -> :ok
  end

  def commit_segment(_session_key, _channel_id, _run_id, _opts), do: :ok

  @doc """
  Finalize the tool status for a run by marking any still-running actions as
  completed. A surface without a coalescer has nothing to finalize and none is
  started for it.
  """
  def finalize_run(session_key, channel_id, run_id, ok?, opts \\ [])

  def finalize_run(session_key, channel_id, run_id, ok?, opts) when is_binary(run_id) do
    meta = Keyword.get(opts, :meta, %{})
    surface = Keyword.get(opts, :surface, :status)
    _ = call(registry_key(session_key, channel_id, surface), {:finalize_run, run_id, ok?, meta})
    :ok
  catch
    :exit, _ -> :ok
  end

  def finalize_run(_session_key, _channel_id, _run_id, _ok?, _opts), do: :ok

  defp call(key, request, start \\ nil) do
    CoalescerIngress.call(LemonRouter.ToolStatusRegistry, key, request, 2_000, start)
  end

  defp start_coalescer(session_key, channel_id, surface, meta) do
    spec =
      {__MODULE__, session_key: session_key, channel_id: channel_id, surface: surface, meta: meta}

    case DynamicSupervisor.start_child(LemonRouter.ToolStatusSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    session_key = Keyword.fetch!(opts, :session_key)
    channel_id = Keyword.fetch!(opts, :channel_id)
    surface = Keyword.get(opts, :surface, :status)

    config = %{
      idle_ms: Keyword.get(opts, :idle_ms, @default_idle_ms),
      max_latency_ms: Keyword.get(opts, :max_latency_ms, @default_max_latency_ms)
    }

    delivery =
      LemonRouter.CoalescerIngress.register(
        LemonRouter.ToolStatusRegistry,
        registry_key(session_key, channel_id, surface),
        opts
      )

    retire_after_ms = CoalescerIngress.retire_after_ms(opts)
    CoalescerIngress.schedule_retire_check(retire_after_ms)

    state = %__MODULE__{
      session_key: session_key,
      channel_id: channel_id,
      surface: surface,
      run_id: nil,
      actions: %{},
      order: [],
      prefix_text: nil,
      last_text: nil,
      last_kind: nil,
      first_event_ts: nil,
      flush_timer: nil,
      config: config,
      meta: Keyword.get(opts, :meta, %{}),
      seq: 0,
      finalized: false,
      delivery: delivery,
      run_started_at: nil,
      retire_after_ms: retire_after_ms,
      last_activity_ms: now_ms()
    }

    {:ok, state}
  end

  @impl true
  def handle_cast(message, state), do: cast(message, touch(state))

  defp cast({:action, _, _, _}, %{overflowed: true} = state), do: {:noreply, state}

  defp cast({:action, run_id, action_event, meta}, state) do
    now = System.system_time(:millisecond)

    state =
      if state.run_id != run_id do
        cancel_timer(state.flush_timer)

        %{
          state
          | run_id: run_id,
            actions: %{},
            order: [],
            prefix_text: nil,
            last_text: nil,
            last_kind: nil,
            first_event_ts: nil,
            flush_timer: nil,
            seq: 0,
            finalized: false,
            omitted_actions: 0,
            meta: ChannelContext.compact_meta(meta),
            run_started_at: now
        }
      else
        %{state | meta: Map.merge(state.meta || %{}, ChannelContext.compact_meta(meta))}
      end

    if state.finalized == true and state.run_id == run_id do
      {:noreply, state}
    else
      state =
        case normalize_action_event(action_event) do
          {:skip, _reason} ->
            state

          {:ok, _id, action_data} ->
            action_data
            |> expand_embedded_actions()
            |> Enum.filter(&chat_visible_action?(state.channel_id, &1))
            |> Enum.reduce(
              {state.actions, state.order, state.omitted_actions},
              fn data, {actions, order, omitted} ->
                upsert_action(actions, order, omitted, data.id, data)
              end
            )
            |> then(fn {actions, order, omitted} ->
              state = %{
                state
                | actions: actions,
                  order: order,
                  omitted_actions: omitted,
                  first_event_ts: state.first_event_ts || now,
                  run_started_at: state.run_started_at || now
              }

              maybe_flush(state, now)
            end)
        end

      {:noreply, state}
    end
  end

  defp cast(:flush, state) do
    state = do_flush(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(request, from, state), do: handle_request(request, from, touch(state))

  defp handle_request({:anchor_segment, _, _, _}, _from, %{overflowed: true} = state),
    do: {:reply, :ok, state}

  defp handle_request({:anchor_segment, run_id, prefix_text, meta}, _from, state) do
    state =
      cond do
        state.run_id == nil ->
          %{state | run_id: run_id, meta: ChannelContext.compact_meta(meta)}

        state.run_id != run_id ->
          cancel_timer(state.flush_timer)

          %{
            state
            | run_id: run_id,
              actions: %{},
              order: [],
              prefix_text: nil,
              last_text: nil,
              last_kind: nil,
              first_event_ts: nil,
              flush_timer: nil,
              finalized: false,
              meta: ChannelContext.compact_meta(meta),
              run_started_at: nil
          }

        true ->
          %{state | meta: Map.merge(state.meta || %{}, ChannelContext.compact_meta(meta))}
      end

    state =
      state
      |> finalize_segment()
      |> reset_segment()
      |> Map.put(:prefix_text, prefix_text)

    {:reply, :ok, state}
  end

  defp handle_request({:commit_segment, _, _}, _from, %{overflowed: true} = state),
    do: {:reply, :ok, state}

  defp handle_request({:commit_segment, run_id, meta}, _from, state) do
    state =
      if state.run_id == run_id do
        state
        |> Map.put(:meta, Map.merge(state.meta || %{}, ChannelContext.compact_meta(meta)))
        |> finalize_segment()
        |> reset_segment()
      else
        state
      end

    {:reply, :ok, state}
  end

  defp handle_request({:finalize_run, run_id, ok?, meta}, _from, state) do
    if LemonRouter.CoalescerIngress.completed?(
         LemonRouter.ToolStatusRegistry,
         registry_key(state.session_key, state.channel_id, state.surface),
         run_id
       ) do
      {:reply, :ok, state}
    else
      finalize_run_state(run_id, ok?, meta, state)
    end
  end

  defp finalize_run_state(run_id, ok?, meta, state) do
    state =
      cond do
        state.run_id == nil ->
          %{
            state
            | run_id: run_id,
              meta: ChannelContext.compact_meta(meta),
              actions: %{},
              order: [],
              prefix_text: nil,
              last_text: nil,
              last_kind: nil,
              first_event_ts: nil,
              flush_timer: nil,
              seq: 0,
              finalized: false,
              run_started_at: nil
          }

        state.run_id != run_id ->
          cancel_timer(state.flush_timer)

          %{
            state
            | run_id: run_id,
              actions: %{},
              order: [],
              prefix_text: nil,
              last_text: nil,
              last_kind: nil,
              first_event_ts: nil,
              flush_timer: nil,
              seq: 0,
              finalized: false,
              meta: ChannelContext.compact_meta(meta),
              run_started_at: nil
          }

        true ->
          %{state | meta: Map.merge(state.meta || %{}, ChannelContext.compact_meta(meta))}
      end

    state =
      state
      |> LemonRouter.CoalescerIngress.observe_overflow()
      |> Map.put(:finalized, true)
      |> finalize_running_actions(ok?)
      |> do_flush()

    delivery =
      LemonRouter.CoalescerIngress.complete(
        LemonRouter.ToolStatusRegistry,
        registry_key(state.session_key, state.channel_id, state.surface),
        state.delivery,
        run_id
      )

    # The finalized run's actions are no longer needed once its final status is
    # out; only the identity that fences late messages remains.
    state = %{
      state
      | delivery: delivery,
        overflowed: false,
        actions: %{},
        order: [],
        omitted_actions: 0,
        prefix_text: nil,
        last_text: nil,
        last_kind: nil,
        first_event_ts: nil,
        run_started_at: nil,
        meta: %{}
    }

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:lemon_bus_delivery, gate, message}, state) do
    if LemonCore.Bus.Delivery.matches?(state.delivery, gate) do
      case message do
        {:stream_resync, :overflow} ->
          {:noreply, LemonRouter.CoalescerIngress.observe_overflow(state)}

        _ ->
          handle_cast(message, state)
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(:idle_timeout, state) do
    state = do_flush(state)
    {:noreply, state}
  end

  def handle_info(:retire_check, state) do
    case CoalescerIngress.retire_check(
           state,
           LemonRouter.ToolStatusRegistry,
           registry_key(state.session_key, state.channel_id, state.surface),
           &retirable?/1
         ) do
      {:stop, state} -> {:stop, :normal, state}
      {:keep, state, admitted} -> {:noreply, Enum.reduce(admitted, state, &cast_admitted/2)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp cast_admitted(message, state) do
    {:noreply, state} = handle_cast(message, state)
    state
  end

  # ---- Internal ----

  defp touch(state), do: %{state | last_activity_ms: now_ms()}

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Nothing a live producer still needs: the run is finalized, never started,
  # or neither its RunProcess nor an async subscriber for this surface remains.
  defp retirable?(%__MODULE__{run_id: nil}), do: true
  defp retirable?(%__MODULE__{finalized: true}), do: true

  defp retirable?(%__MODULE__{run_id: run_id, surface: surface}),
    do: not CoalescerIngress.producer_alive?(run_id, surface)

  defp dispatcher do
    Application.get_env(:lemon_router, :dispatcher, Dispatcher)
  end

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

  defp do_flush(%{overflowed: true, finalized: false} = state), do: state

  defp do_flush(state) do
    cancel_timer(state.flush_timer)

    opts = %{
      elapsed_ms: elapsed_since(state.run_started_at),
      action_count: length(state.order) + state.omitted_actions,
      omitted_count: state.omitted_actions
    }

    text =
      if state.overflowed do
        "Progress updates were interrupted. Refresh session state for current tool results."
      else
        state.channel_id
        |> LemonRouter.ToolStatusRenderer.render(state.actions, state.order, opts)
        |> maybe_prefix_running(state)
        |> maybe_prefix_text(state)
      end

    kind = if state.finalized == true, do: :tool_status_finalize, else: :tool_status_snapshot

    state =
      cond do
        state.order == [] and not state.overflowed ->
          state

        text == state.last_text and kind == state.last_kind ->
          state

        true ->
          state = %{state | seq: state.seq + 1}
          state = emit_output(state, kind, text)
          %{state | last_text: text, last_kind: kind}
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

  defp finalize_segment(%__MODULE__{order: []} = state), do: state

  defp finalize_segment(%__MODULE__{} = state) do
    state
    |> Map.put(:finalized, true)
    |> do_flush()
  end

  defp reset_segment(%__MODULE__{} = state) do
    cancel_timer(state.flush_timer)

    %{
      state
      | actions: %{},
        order: [],
        prefix_text: nil,
        last_text: nil,
        last_kind: nil,
        first_event_ts: nil,
        flush_timer: nil,
        finalized: false,
        omitted_actions: 0
    }
  end

  # Reasoning remains available to Web/TUI/monitoring consumers, but ordinary chat
  # status bubbles should describe only actions the user can meaningfully follow.
  defp chat_visible_action?(channel_id, action) when is_map(action) do
    not (chat_channel?(channel_id) and action[:kind] in [:reasoning, "reasoning"])
  end

  defp chat_visible_action?(_channel_id, _action), do: true

  defp chat_channel?(channel_id) when is_binary(channel_id) do
    Enum.any?(["telegram", "discord"], &String.starts_with?(channel_id, &1))
  end

  defp chat_channel?(_channel_id), do: false

  defp emit_output(state, kind, text) do
    case build_intent(state, kind, text) do
      {:ok, intent} ->
        _ = dispatcher().dispatch(intent)
        state

      :error ->
        state
    end
  end

  defp build_intent(state, kind, text) do
    case DeliveryRouteResolver.resolve(state.session_key, state.channel_id, state.meta || %{}) do
      {:ok, route} ->
        body =
          %{text: text, seq: state.seq}
          |> maybe_put_tool_failures(state)

        {:ok,
         %DeliveryIntent{
           intent_id:
             "#{state.run_id}:status:#{surface_token(state.surface)}:#{state.seq}:#{Atom.to_string(kind)}",
           run_id: state.run_id,
           session_key: state.session_key,
           route: route,
           kind: kind,
           body: body,
           controls: %{allow_cancel?: state.finalized != true},
           meta: Map.put(state.meta || %{}, :surface, state.surface)
         }}

      _ ->
        :error
    end
  end

  defp maybe_put_tool_failures(body, state) do
    case tool_failures(state.actions, state.order) do
      [] -> body
      failures -> Map.put(body, :tool_failures, failures)
    end
  end

  defp tool_failures(actions, order) when is_map(actions) and is_list(order) do
    order
    |> Enum.map(&Map.get(actions, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn action ->
      case tool_failure(action) do
        nil -> []
        failure -> [failure]
      end
    end)
  end

  defp tool_failures(_actions, _order), do: []

  defp tool_failure(action) when is_map(action) do
    detail = map_value(action, :detail) || %{}
    result_meta = map_value(detail, :result_meta) || %{}
    error_type = map_value(result_meta, :error_type)

    if is_nil(error_type) do
      nil
    else
      %{}
      |> maybe_put(:id, map_value(action, :id))
      |> maybe_put(:title, map_value(action, :title))
      |> maybe_put(:kind, map_value(action, :kind))
      |> maybe_put(:ok, map_value(action, :ok))
      |> maybe_put(:error_type, error_type)
      |> maybe_put(:tool_name, map_value(result_meta, :tool_name))
      |> maybe_put(:reason, map_value(result_meta, :reason))
      |> maybe_put(:errors, map_value(result_meta, :errors))
      |> maybe_put(:timeout_ms, map_value(result_meta, :timeout_ms))
      |> maybe_put(:exit_code, map_value(result_meta, :exit_code))
      |> maybe_put(:exception, map_value(result_meta, :exception))
      |> maybe_put(:message, map_value(result_meta, :message))
      |> maybe_put(:status, map_value(result_meta, :status))
    end
  end

  defp tool_failure(_action), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_prefix_running(text, %__MODULE__{} = state) when is_binary(text) do
    show_running_prefix? =
      (state.meta || %{})[:show_running_prefix?] == true or
        (state.meta || %{})["show_running_prefix?"] == true

    if show_running_prefix? and any_running_action?(state) do
      "Running…\n\n" <> text
    else
      text
    end
  end

  defp maybe_prefix_running(text, _state), do: text

  defp maybe_prefix_text(text, %__MODULE__{prefix_text: prefix})
       when is_binary(text) and is_binary(prefix) do
    trimmed = String.trim(prefix)

    if trimmed == "" do
      text
    else
      combine_prefix_and_status(trimmed, text)
    end
  end

  defp maybe_prefix_text(text, _state), do: text

  # Keep the current tool-status snapshot visible even when the handed-off
  # assistant prefix is long. Telegram truncation preserves the start of a
  # message, so without budgeting the prefix separately we can hide the tool
  # lines entirely.
  defp combine_prefix_and_status(prefix, text) when is_binary(prefix) and is_binary(text) do
    separator = "\n\n"
    max_len = telegram_max_length()
    combined = prefix <> separator <> text

    cond do
      String.length(combined) <= max_len ->
        combined

      String.length(text) + String.length(separator) >= max_len ->
        text

      true ->
        available_for_prefix = max_len - String.length(text) - String.length(separator) - 1

        if available_for_prefix <= 0 do
          text
        else
          prefix_head = String.slice(prefix, 0, available_for_prefix)
          prefix_head <> "…" <> separator <> text
        end
    end
  end

  defp telegram_max_length do
    @status_text_max_length
  end

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
  end

  defp registry_key(session_key, channel_id, :status), do: {session_key, channel_id}
  defp registry_key(session_key, channel_id, surface), do: {session_key, channel_id, surface}

  defp surface_token(surface) do
    surface
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  defp normalize_action_event(%{action: action} = ev) when is_map(action) do
    kind = Map.get(action, :kind)

    allowed_kinds = [
      "tool",
      "command",
      "file_change",
      "web_search",
      "subagent",
      "reasoning",
      "approval",
      :tool,
      :command,
      :file_change,
      :web_search,
      :subagent,
      :reasoning,
      :approval
    ]

    cond do
      kind in ["note", :note] ->
        case normalize_note_reasoning(action, ev) do
          {:ok, data} -> {:ok, data.id, data}
          :skip -> {:skip, :note}
        end

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
  end

  defp normalize_action_event(_), do: {:skip, :unknown}

  defp normalize_note_reasoning(action, ev) when is_map(action) and is_map(ev) do
    detail = Map.get(action, :detail) || Map.get(action, "detail") || %{}
    reasoning = reasoning_from_detail(detail)
    id = Map.get(action, :id)
    title = Map.get(action, :title)

    cond do
      not (is_binary(id) and id != "") ->
        :skip

      is_map(reasoning) ->
        text = reasoning[:text] || reasoning["text"] || title || ""

        {:ok,
         %{
           id: id,
           kind: "reasoning",
           caller_engine: Map.get(ev, :engine),
           title: text,
           phase: Map.get(ev, :phase),
           ok: Map.get(ev, :ok),
           message: Map.get(ev, :message),
           level: Map.get(ev, :level),
           detail: %{reasoning: reasoning}
         }}

      reasoning_note_id?(id) ->
        text = note_text(detail) || title || ""

        {:ok,
         %{
           id: id,
           kind: "reasoning",
           caller_engine: Map.get(ev, :engine),
           title: text,
           phase: Map.get(ev, :phase),
           ok: Map.get(ev, :ok),
           message: Map.get(ev, :message),
           level: Map.get(ev, :level),
           detail: %{reasoning: %{text: text, source: "runner_note"}}
         }}

      true ->
        :skip
    end
  end

  defp normalize_note_reasoning(_action, _ev), do: :skip

  defp reasoning_from_detail(detail) when is_map(detail) do
    reasoning = Map.get(detail, :reasoning) || Map.get(detail, "reasoning")

    cond do
      is_map(reasoning) ->
        reasoning

      is_binary(Map.get(detail, :text)) ->
        %{text: Map.get(detail, :text), source: "runner_note"}

      is_binary(Map.get(detail, "text")) ->
        %{text: Map.get(detail, "text"), source: "runner_note"}

      true ->
        nil
    end
  end

  defp reasoning_from_detail(_detail), do: nil

  defp note_text(detail) when is_map(detail) do
    Map.get(detail, :text) || Map.get(detail, "text")
  end

  defp note_text(_detail), do: nil

  defp reasoning_note_id?(id) when is_binary(id) do
    id = String.downcase(id)
    String.contains?(id, "thinking") or String.contains?(id, "reasoning")
  end

  defp expand_embedded_actions(action_data) when is_map(action_data) do
    case {skip_parent_action?(action_data), embedded_child_action(action_data)} do
      {true, nil} -> []
      {true, child} -> [child]
      {false, nil} -> [action_data]
      {false, child} -> [action_data, child]
    end
  end

  defp skip_parent_action?(action_data) when is_map(action_data) do
    detail = action_data[:detail] || %{}
    args = Map.get(detail, :args) || Map.get(detail, "args") || %{}
    name = Map.get(detail, :name) || Map.get(detail, "name")
    action_name = Map.get(args, :action) || Map.get(args, "action")

    action_data[:kind] in ["subagent", :subagent] and name == "task" and
      action_name in ["poll", "join"]
  end

  defp embedded_child_action(action_data) when is_map(action_data) do
    detail = action_data[:detail] || %{}

    parent_id =
      Map.get(detail, :parent_tool_use_id) || Map.get(detail, "parent_tool_use_id") ||
        action_data[:id]

    with true <- is_binary(parent_id) and parent_id != "",
         %{title: title, kind: kind, phase: phase} <- current_action(detail),
         true <- allowed_embedded_kind?(kind),
         child_id when is_binary(child_id) <- embedded_child_id(parent_id, kind, title) do
      %{
        id: child_id,
        kind: normalize_embedded_kind(kind),
        caller_engine: embedded_engine(detail) || action_data[:caller_engine],
        title: title,
        phase: normalize_embedded_phase(phase),
        ok: embedded_ok(phase),
        message: nil,
        level: nil,
        detail:
          (embedded_action_detail(detail) || %{})
          |> Map.put_new(:parent_tool_use_id, parent_id)
      }
    else
      _ -> nil
    end
  end

  defp current_action(detail) when is_map(detail) do
    current_action_from_partial_result(detail) || current_action_from_result_meta(detail)
  end

  defp current_action_from_partial_result(detail) when is_map(detail) do
    partial_result = Map.get(detail, :partial_result) || Map.get(detail, "partial_result")

    with true <- is_map(partial_result),
         details when is_map(details) <-
           Map.get(partial_result, :details) || Map.get(partial_result, "details"),
         current when is_map(current) <-
           Map.get(details, :current_action) || Map.get(details, "current_action"),
         title when is_binary(title) and title != "" <-
           Map.get(current, :title) || Map.get(current, "title"),
         kind when is_binary(kind) and kind != "" <-
           Map.get(current, :kind) || Map.get(current, "kind"),
         phase when is_binary(phase) and phase != "" <-
           Map.get(current, :phase) || Map.get(current, "phase") do
      %{title: title, kind: kind, phase: phase}
    else
      _ -> nil
    end
  end

  defp current_action_from_result_meta(detail) when is_map(detail) do
    result_meta = Map.get(detail, :result_meta) || Map.get(detail, "result_meta")

    with true <- is_map(result_meta),
         current when is_map(current) <-
           Map.get(result_meta, :current_action) || Map.get(result_meta, "current_action"),
         title when is_binary(title) and title != "" <-
           Map.get(current, :title) || Map.get(current, "title"),
         kind when is_binary(kind) and kind != "" <-
           Map.get(current, :kind) || Map.get(current, "kind"),
         phase when is_binary(phase) and phase != "" <-
           Map.get(current, :phase) || Map.get(current, "phase") do
      %{title: title, kind: kind, phase: phase}
    else
      _ -> nil
    end
  end

  defp embedded_action_detail(detail) when is_map(detail) do
    embedded_action_detail_from_partial_result(detail) ||
      embedded_action_detail_from_result_meta(detail)
  end

  defp embedded_action_detail_from_partial_result(detail) when is_map(detail) do
    partial_result = Map.get(detail, :partial_result) || Map.get(detail, "partial_result")

    with true <- is_map(partial_result),
         details when is_map(details) <-
           Map.get(partial_result, :details) || Map.get(partial_result, "details"),
         action_detail when is_map(action_detail) <-
           Map.get(details, :action_detail) || Map.get(details, "action_detail") do
      action_detail
    else
      _ -> nil
    end
  end

  defp embedded_action_detail_from_result_meta(detail) when is_map(detail) do
    result_meta = Map.get(detail, :result_meta) || Map.get(detail, "result_meta")

    with true <- is_map(result_meta),
         action_detail when is_map(action_detail) <-
           Map.get(result_meta, :action_detail) || Map.get(result_meta, "action_detail") do
      action_detail
    else
      _ -> nil
    end
  end

  defp embedded_engine(detail) when is_map(detail) do
    embedded_engine_from_partial_result(detail) || embedded_engine_from_result_meta(detail)
  end

  defp embedded_engine_from_partial_result(detail) when is_map(detail) do
    partial_result = Map.get(detail, :partial_result) || Map.get(detail, "partial_result")

    with true <- is_map(partial_result),
         details when is_map(details) <-
           Map.get(partial_result, :details) || Map.get(partial_result, "details"),
         engine when is_binary(engine) and engine != "" <-
           Map.get(details, :engine) || Map.get(details, "engine") do
      engine
    else
      _ -> nil
    end
  end

  defp embedded_engine_from_result_meta(detail) when is_map(detail) do
    result_meta = Map.get(detail, :result_meta) || Map.get(detail, "result_meta")

    with true <- is_map(result_meta),
         engine when is_binary(engine) and engine != "" <-
           Map.get(result_meta, :engine) || Map.get(result_meta, "engine") do
      engine
    else
      _ -> nil
    end
  end

  defp embedded_child_id(parent_id, kind, title)
       when is_binary(parent_id) and is_binary(kind) and is_binary(title) do
    digest =
      "#{kind}:#{title}"
      |> :erlang.md5()
      |> Base.encode16(case: :lower)

    "#{parent_id}:#{digest}"
  end

  defp normalize_embedded_kind(kind) when is_binary(kind) do
    case String.downcase(kind) do
      "tool" -> "tool"
      "command" -> "command"
      "file_change" -> "file_change"
      "web_search" -> "web_search"
      "subagent" -> "subagent"
      other -> other
    end
  end

  defp normalize_embedded_kind(kind), do: kind

  defp allowed_embedded_kind?(kind) when is_binary(kind) do
    normalize_embedded_kind(kind) in [
      "tool",
      "command",
      "file_change",
      "web_search",
      "browser",
      "subagent",
      "reasoning"
    ]
  end

  defp normalize_embedded_phase(phase) when is_binary(phase) do
    case String.downcase(phase) do
      "started" -> :started
      "updated" -> :updated
      "completed" -> :completed
      _ -> :updated
    end
  end

  defp embedded_ok(phase) when is_binary(phase) do
    case String.downcase(phase) do
      "completed" -> true
      _ -> nil
    end
  end

  defp upsert_action(actions, order, omitted, id, data) do
    id = equivalent_action_id(actions, data) || id
    actions = Map.put(actions, id, Map.update(data, :detail, nil, &retained_detail(&1, data)))

    if id in order,
      do: {actions, order, omitted},
      else: evict_overflow(actions, order ++ [id], omitted)
  end

  # Evict the oldest completed action (else the oldest) beyond the cap; the
  # renderer reports evicted actions as omitted.
  defp evict_overflow(actions, order, omitted) when length(order) <= @max_retained_actions,
    do: {actions, order, omitted}

  defp evict_overflow(actions, order, omitted) do
    victim = Enum.find(order, &completed_action?(Map.get(actions, &1))) || hd(order)
    {Map.delete(actions, victim), List.delete(order, victim), omitted + 1}
  end

  defp completed_action?(action) when is_map(action),
    do: map_value(action, :phase) in [:completed, "completed"]

  defp completed_action?(_action), do: false

  # Keep only what rendering, failure reporting and child-action matching read;
  # args, partial results and full results are not retained.
  defp retained_detail(detail, data) when is_map(detail) do
    detail
    |> Map.take([:parent_tool_use_id, "parent_tool_use_id", :child_run_id, "child_run_id"])
    |> maybe_put(:result_preview, failure_preview(detail, data))
    |> maybe_put(:result_meta, failure_meta(map_value(detail, :result_meta)))
  end

  defp retained_detail(detail, _data), do: detail

  # The renderer shows a result preview only for a completed, failed action.
  defp failure_preview(detail, data) do
    with true <- data[:phase] in [:completed, "completed"] and data[:ok] != true,
         preview when not is_nil(preview) <-
           map_value(detail, :result_preview) || map_value(detail, :result),
         text when is_binary(text) <- LemonRouter.ToolPreview.to_text(preview) do
      String.slice(text, 0, @retained_preview_chars)
    else
      _ -> nil
    end
  end

  defp failure_meta(meta) when is_map(meta) do
    retained =
      for key <- @failure_meta_keys,
          value = map_value(meta, key),
          not is_nil(value),
          into: %{},
          do: {key, value}

    if retained == %{}, do: nil, else: retained
  end

  defp failure_meta(_meta), do: nil

  defp elapsed_since(nil), do: nil

  defp elapsed_since(started_at) when is_integer(started_at) do
    System.system_time(:millisecond) - started_at
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
end
