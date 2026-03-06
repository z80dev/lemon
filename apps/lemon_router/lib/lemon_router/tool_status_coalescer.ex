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

  @max_actions 40

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
    :run_started_at,
    :engine
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
  - `:meta` - semantic delivery metadata (for example `:user_msg_id`)
  """
  def ingest_action(session_key, channel_id, run_id, action_event, opts \\ []) do
    meta = Keyword.get(opts, :meta, %{})

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
      run_started_at: nil,
      engine: nil
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

          {:ok, id, action_data} ->
            {actions, order} = upsert_action(state.actions, state.order, id, action_data)

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
              last_text: nil,
              first_event_ts: nil,
              flush_timer: nil,
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

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    state = do_flush(state)
    {:noreply, state}
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

    state =
      cond do
        state.order == [] ->
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
    kind = if state.finalized == true, do: :tool_status_finalize, else: :tool_status_snapshot

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
    with {:ok, route} <- DeliveryRouteResolver.resolve(state.session_key, state.channel_id, state.meta || %{}) do
      {:ok,
       %DeliveryIntent{
         intent_id: "#{state.run_id}:status:#{state.seq}:#{Atom.to_string(kind)}",
         run_id: state.run_id,
         session_key: state.session_key,
         route: route,
         kind: kind,
         body: %{text: text, seq: state.seq},
         controls: %{allow_cancel?: state.finalized != true},
         meta: Map.put(state.meta || %{}, :surface, :status)
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

  defp elapsed_since(nil), do: nil

  defp elapsed_since(started_at) when is_integer(started_at) do
    System.system_time(:millisecond) - started_at
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

end
