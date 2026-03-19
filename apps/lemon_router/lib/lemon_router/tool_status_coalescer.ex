defmodule LemonRouter.ToolStatusCoalescer do
  @moduledoc """
  Coalesce tool/action lifecycle events into a single editable "Tool calls" message.

  This is intentionally separate from StreamCoalescer (answer streaming). Tool actions can
  run without producing output deltas, so we want a dedicated status surface.

  Channel-specific presentation is handled by `LemonChannels.Dispatcher`.
  """

  use GenServer

  require Logger

  alias LemonChannels.Dispatcher
  alias LemonCore.DeliveryIntent
  alias LemonRouter.ChannelContext
  alias LemonRouter.DeliveryRouteResolver

  @default_idle_ms 400
  @default_max_latency_ms 1200
  @default_task_reap_ms 60_000

  @max_actions 40

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
    :reap_timer,
    :reap_token,
    :config,
    :meta,
    :seq,
    :finalized,
    :run_started_at,
    :engine
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

      {:ok, _id, _action_data} ->
        case get_or_start_coalescer(session_key, channel_id, surface, meta) do
          {:ok, pid} ->
            GenServer.cast(pid, {:action, run_id, action_event, meta})

          {:error, reason} ->
            Logger.warning("Failed to start tool status coalescer: #{inspect(reason)}")
        end
    end

    :ok
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

    case Registry.lookup(
           LemonRouter.ToolStatusRegistry,
           registry_key(session_key, channel_id, surface)
         ) do
      [{pid, _}] -> GenServer.cast(pid, :flush)
      _ -> :ok
    end
  end

  defp equivalent_action_id(actions, data) when is_map(actions) and is_map(data) do
    Enum.find_value(actions, fn {existing_id, existing_data} ->
      if equivalent_action?({existing_id, existing_data}, {data[:id], data}),
        do: existing_id,
        else: nil
    end)
  end

  defp equivalent_action_id(_, _), do: nil

  defp equivalent_action?(
         {existing_id, existing},
         {incoming_id, incoming}
       )
       when is_binary(existing_id) and is_binary(incoming_id) and is_map(existing) and
              is_map(incoming) do
    existing_detail = existing[:detail] || %{}
    incoming_detail = incoming[:detail] || %{}

    existing_child_run_id = existing_detail[:child_run_id] || existing_detail["child_run_id"]
    incoming_child_run_id = incoming_detail[:child_run_id] || incoming_detail["child_run_id"]

    existing_parent =
      existing_detail[:parent_tool_use_id] || existing_detail["parent_tool_use_id"]

    incoming_parent =
      incoming_detail[:parent_tool_use_id] || incoming_detail["parent_tool_use_id"]

    projected_embedded_equivalent_ids?(existing_id, incoming_id) and
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

    case get_or_start_coalescer(session_key, channel_id, surface, meta) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, {:anchor_segment, run_id, prefix_text, meta}, 2_000)
        catch
          :exit, _ -> :ok
        end

        :ok

      _ ->
        :ok
    end
  end

  def anchor_segment(_session_key, _channel_id, _run_id, _prefix_text, _opts), do: :ok

  @doc """
  Finalize the current tool-status segment without marking running actions complete.
  """
  def commit_segment(session_key, channel_id, run_id, opts \\ [])

  def commit_segment(session_key, channel_id, run_id, opts) when is_binary(run_id) do
    meta = Keyword.get(opts, :meta, %{})
    surface = Keyword.get(opts, :surface, :status)

    case Registry.lookup(
           LemonRouter.ToolStatusRegistry,
           registry_key(session_key, channel_id, surface)
         ) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:commit_segment, run_id, meta}, 2_000)
        catch
          :exit, _ -> :ok
        end

        :ok

      _ ->
        :ok
    end
  end

  def commit_segment(_session_key, _channel_id, _run_id, _opts), do: :ok

  @doc """
  Finalize the tool status for a run by marking any still-running actions as completed.
  """
  def finalize_run(session_key, channel_id, run_id, ok?, opts \\ [])

  def finalize_run(session_key, channel_id, run_id, ok?, opts) when is_binary(run_id) do
    meta = Keyword.get(opts, :meta, %{})
    surface = Keyword.get(opts, :surface, :status)

    case get_or_start_coalescer(session_key, channel_id, surface, meta) do
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

  defp get_or_start_coalescer(session_key, channel_id, surface, meta) do
    key = registry_key(session_key, channel_id, surface)

    case Registry.lookup(LemonRouter.ToolStatusRegistry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec =
          {__MODULE__,
           session_key: session_key, channel_id: channel_id, surface: surface, meta: meta}

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
    surface = Keyword.get(opts, :surface, :status)

    config = %{
      idle_ms: Keyword.get(opts, :idle_ms, @default_idle_ms),
      max_latency_ms: Keyword.get(opts, :max_latency_ms, @default_max_latency_ms),
      task_reap_ms: Keyword.get(opts, :task_reap_ms, @default_task_reap_ms)
    }

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
      reap_timer: nil,
      reap_token: nil,
      config: config,
      meta: Keyword.get(opts, :meta, %{}),
      seq: 0,
      finalized: false,
      run_started_at: nil,
      engine: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:action, run_id, action_event, meta}, state) do
    now = System.system_time(:millisecond)
    state = cancel_task_reap(state)

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
            reap_timer: nil,
            reap_token: nil,
            seq: 0,
            finalized: false,
            meta: compact_meta(meta),
            run_started_at: now,
            engine: nil
        }
      else
        %{state | meta: Map.merge(state.meta || %{}, compact_meta(meta))}
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
            |> Enum.reduce({state.actions, state.order}, fn data, {actions, order} ->
              upsert_action(actions, order, data.id, data)
            end)
            |> then(fn {actions, order} ->
              engine =
                state.engine ||
                  (is_binary(action_data[:caller_engine]) && action_data[:caller_engine]) ||
                  nil

              state = %{
                state
                | actions: actions,
                  order: order,
                  first_event_ts: state.first_event_ts || now,
                  run_started_at: state.run_started_at || now,
                  engine: engine
              }

              maybe_flush(state, now)
            end)
        end

      {:noreply, state}
    end
  end

  def handle_cast(:flush, state) do
    state = do_flush(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:anchor_segment, run_id, prefix_text, meta}, _from, state) do
    state = cancel_task_reap(state)

    state =
      cond do
        state.run_id == nil ->
          %{state | run_id: run_id, meta: compact_meta(meta)}

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
              reap_timer: nil,
              reap_token: nil,
              finalized: false,
              meta: compact_meta(meta),
              run_started_at: nil,
              engine: nil
          }

        true ->
          %{state | meta: Map.merge(state.meta || %{}, compact_meta(meta))}
      end

    state =
      state
      |> finalize_segment()
      |> reset_segment()
      |> Map.put(:prefix_text, prefix_text)

    {:reply, :ok, state}
  end

  def handle_call({:commit_segment, run_id, meta}, _from, state) do
    state = cancel_task_reap(state)

    state =
      if state.run_id == run_id do
        state
        |> Map.put(:meta, Map.merge(state.meta || %{}, compact_meta(meta)))
        |> finalize_segment()
        |> reset_segment()
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:finalize_run, run_id, ok?, meta}, _from, state) do
    state = cancel_task_reap(state)

    state =
      cond do
        state.run_id == nil ->
          %{
            state
            | run_id: run_id,
              meta: compact_meta(meta),
              actions: %{},
              order: [],
              prefix_text: nil,
              last_text: nil,
              last_kind: nil,
              first_event_ts: nil,
              flush_timer: nil,
              reap_timer: nil,
              reap_token: nil,
              seq: 0,
              finalized: false,
              run_started_at: nil,
              engine: nil
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
              reap_timer: nil,
              reap_token: nil,
              seq: 0,
              finalized: false,
              meta: compact_meta(meta),
              run_started_at: nil,
              engine: nil
          }

        true ->
          %{state | meta: Map.merge(state.meta || %{}, compact_meta(meta))}
      end

    state =
      state
      |> Map.put(:finalized, true)
      |> finalize_running_actions(ok?)
      |> do_flush()
      |> maybe_schedule_task_reap()

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    state = do_flush(state)
    {:noreply, state}
  end

  def handle_info({:reap_if_idle, token}, %{reap_token: token} = state) do
    state = %{state | reap_timer: nil, reap_token: nil}

    if task_surface_reapable?(state) do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- Internal ----

  defp compact_meta(meta), do: ChannelContext.compact_meta(meta)

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

  defp do_flush(state) do
    cancel_timer(state.flush_timer)

    opts = %{
      elapsed_ms: elapsed_since(state.run_started_at),
      engine: state.engine,
      action_count: length(state.order)
    }

    text =
      state.channel_id
      |> LemonRouter.ToolStatusRenderer.render(state.actions, state.order, opts)
      |> maybe_prefix_running(state)
      |> maybe_prefix_text(state)

    kind = if state.finalized == true, do: :tool_status_finalize, else: :tool_status_snapshot

    state =
      cond do
        state.order == [] ->
          state

        text == state.last_text and kind == state.last_kind ->
          state

        true ->
          state = %{state | seq: state.seq + 1}
          state = emit_output(state, kind, text)
          %{state | last_text: text, last_kind: kind}
      end

    state
    |> Map.put(:first_event_ts, nil)
    |> Map.put(:flush_timer, nil)
    |> maybe_schedule_task_reap()
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
    state = cancel_task_reap(state)
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
        reap_timer: nil,
        reap_token: nil,
        finalized: false,
        engine: nil
    }
  end

  defp maybe_schedule_task_reap(%__MODULE__{} = state) do
    task_reap_ms = state.config[:task_reap_ms]

    cond do
      not task_surface?(state.surface) ->
        state

      not is_integer(task_reap_ms) or task_reap_ms <= 0 ->
        state

      not task_surface_reapable?(state) ->
        state

      true ->
        state = cancel_task_reap(state)
        token = make_ref()
        timer = Process.send_after(self(), {:reap_if_idle, token}, task_reap_ms)
        %{state | reap_timer: timer, reap_token: token}
    end
  end

  defp cancel_task_reap(%__MODULE__{reap_timer: nil} = state), do: %{state | reap_token: nil}

  defp cancel_task_reap(%__MODULE__{reap_timer: timer} = state) do
    cancel_timer(timer)
    %{state | reap_timer: nil, reap_token: nil}
  end

  defp task_surface_reapable?(%__MODULE__{} = state) do
    task_surface?(state.surface) and state.order != [] and not any_running_action?(state)
  end

  defp task_surface?({:status_task, task_id}) when is_binary(task_id) and task_id != "", do: true
  defp task_surface?(_), do: false

  defp emit_output(state, kind, text) do
    case build_intent(state, kind, text) do
      {:ok, intent} ->
        _ = dispatcher().dispatch(intent)
        state

      :error ->
        state
    end
  rescue
    _ -> state
  end

  defp build_intent(state, kind, text) do
    with {:ok, route} <-
           DeliveryRouteResolver.resolve(state.session_key, state.channel_id, state.meta || %{}) do
      {:ok,
       %DeliveryIntent{
         intent_id:
           "#{state.run_id}:status:#{surface_token(state.surface)}:#{state.seq}:#{Atom.to_string(kind)}",
         run_id: state.run_id,
         session_key: state.session_key,
         route: route,
         kind: kind,
         body: %{text: text, seq: state.seq},
         controls: %{allow_cancel?: state.finalized != true},
         meta: Map.put(state.meta || %{}, :surface, state.surface)
       }}
    else
      _ -> :error
    end
  end

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

  defp maybe_prefix_text(text, %__MODULE__{prefix_text: prefix} = state)
       when is_binary(text) and is_binary(prefix) do
    trimmed = String.trim(prefix)

    if trimmed == "" do
      text
    else
      combine_prefix_and_status(trimmed, text, chunk_limit(state.channel_id))
    end
  end

  defp maybe_prefix_text(text, _state), do: text

  # Keep the current tool-status snapshot visible even when the handed-off
  # assistant prefix is long. Telegram truncation preserves the start of a
  # message, so without budgeting the prefix separately we can hide the tool
  # lines entirely.
  defp combine_prefix_and_status(prefix, text, max_len)
       when is_binary(prefix) and is_binary(text) and is_integer(max_len) and max_len > 0 do
    separator = "\n\n"
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
          prefix_tail = String.slice(prefix, -available_for_prefix, available_for_prefix)
          "…" <> prefix_tail <> separator <> text
        end
    end
  end

  defp chunk_limit(channel_id) when is_binary(channel_id) and channel_id != "" do
    case LemonChannels.Registry.get_capabilities(channel_id) do
      %{chunk_limit: limit} when is_integer(limit) and limit > 0 -> limit
      _ -> 4096
    end
  rescue
    _ -> 4096
  end

  defp chunk_limit(_), do: 4096

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

  defp registry_key(session_key, channel_id, :status), do: {session_key, channel_id}
  defp registry_key(session_key, channel_id, surface), do: {session_key, channel_id, surface}

  defp surface_token(surface) do
    surface
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
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

  defp expand_embedded_actions(action_data) when is_map(action_data) do
    case {skip_parent_action?(action_data), embedded_child_action(action_data)} do
      {true, nil} -> []
      {true, child} -> [child]
      {false, nil} -> [action_data]
      {false, child} -> [action_data, child]
    end
  end

  defp expand_embedded_actions(action_data), do: [action_data]

  defp skip_parent_action?(action_data) when is_map(action_data) do
    detail = action_data[:detail] || %{}
    args = Map.get(detail, :args) || Map.get(detail, "args") || %{}
    name = Map.get(detail, :name) || Map.get(detail, "name")
    action_name = Map.get(args, :action) || Map.get(args, "action")

    action_data[:kind] in ["subagent", :subagent] and name == "task" and
      action_name in ["poll", "join"]
  end

  defp skip_parent_action?(_), do: false

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

  defp embedded_child_action(_), do: nil

  defp current_action(detail) when is_map(detail) do
    current_action_from_partial_result(detail) || current_action_from_result_meta(detail)
  end

  defp current_action(_), do: nil

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

  defp current_action_from_partial_result(_), do: nil

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

  defp current_action_from_result_meta(_), do: nil

  defp embedded_action_detail(detail) when is_map(detail) do
    embedded_action_detail_from_partial_result(detail) ||
      embedded_action_detail_from_result_meta(detail)
  end

  defp embedded_action_detail(_), do: %{}

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

  defp embedded_action_detail_from_partial_result(_), do: nil

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

  defp embedded_action_detail_from_result_meta(_), do: nil

  defp embedded_engine(detail) when is_map(detail) do
    embedded_engine_from_partial_result(detail) || embedded_engine_from_result_meta(detail)
  end

  defp embedded_engine(_), do: nil

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

  defp embedded_engine_from_partial_result(_), do: nil

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

  defp embedded_engine_from_result_meta(_), do: nil

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
    normalize_embedded_kind(kind) in ["tool", "command", "file_change", "web_search", "subagent"]
  end

  defp allowed_embedded_kind?(_), do: false

  defp normalize_embedded_phase(phase) when is_binary(phase) do
    case String.downcase(phase) do
      "started" -> :started
      "updated" -> :updated
      "completed" -> :completed
      _ -> :updated
    end
  end

  defp normalize_embedded_phase(_), do: :updated

  defp embedded_ok(phase) when is_binary(phase) do
    case String.downcase(phase) do
      "completed" -> true
      _ -> nil
    end
  end

  defp embedded_ok(_), do: nil

  defp projected_embedded_equivalent_ids?(left, right) do
    {projected_child_action_id?(left), embedded_child_action_id?(left),
     projected_child_action_id?(right), embedded_child_action_id?(right)} in [
      {true, false, false, true},
      {false, true, true, false}
    ]
  end

  defp projected_child_action_id?(<<"taskproj:", _::binary>>), do: true
  defp projected_child_action_id?(_), do: false

  defp embedded_child_action_id?(id) when is_binary(id) do
    not projected_child_action_id?(id) and String.match?(id, ~r/:[0-9a-f]{32}$/)
  end

  defp embedded_child_action_id?(_), do: false

  defp upsert_action(actions, order, id, data) do
    id = equivalent_action_id(actions, data) || id
    actions = Map.put(actions, id, Map.put(data, :id, id))
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

  defp elapsed_since(nil), do: nil

  defp elapsed_since(started_at) when is_integer(started_at) do
    System.system_time(:millisecond) - started_at
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
end
