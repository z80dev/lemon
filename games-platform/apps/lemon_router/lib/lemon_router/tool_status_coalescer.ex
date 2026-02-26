defmodule LemonRouter.ToolStatusCoalescer do
  @moduledoc """
  Coalesce tool/action lifecycle events into a single editable "Tool calls" message.

  This is intentionally separate from StreamCoalescer (answer streaming). Tool actions can
  run without producing output deltas, so we want a dedicated status surface.

  Channel-specific output strategies are handled by `LemonRouter.ChannelAdapter`.
  """

  use GenServer

  require Logger

  alias LemonRouter.ChannelAdapter
  alias LemonRouter.ChannelContext

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
            meta: compact_meta(meta),
            status_create_ref: nil,
            deferred_text: nil
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

  # ---- Internal ----

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

    text =
      state.channel_id
      |> LemonRouter.ToolStatusRenderer.render(state.actions, state.order)
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
    adapter = ChannelAdapter.for(state.channel_id)
    snapshot = build_snapshot(state)

    case adapter.emit_tool_status(snapshot, text) do
      {:ok, updates} -> apply_updates(state, updates)
      :skip -> state
    end
  rescue
    _ -> state
  end

  defp build_snapshot(state) do
    %{
      session_key: state.session_key,
      channel_id: state.channel_id,
      run_id: state.run_id,
      meta: state.meta || %{},
      seq: state.seq,
      finalized: state.finalized,
      status_create_ref: state.status_create_ref,
      deferred_text: state.deferred_text
    }
  end

  defp apply_updates(state, updates) when is_map(updates) do
    Enum.reduce(updates, state, fn {key, value}, acc ->
      if Map.has_key?(acc, key) do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp apply_updates(state, _), do: state

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

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

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
end
