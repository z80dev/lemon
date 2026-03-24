defmodule LemonRouter.AsyncTaskSurfaceSubscriber do
  @moduledoc """
  Router-owned subscriber that projects child-run engine_action events
  directly into the parent task surface's ToolStatusCoalescer.

  This worker survives parent RunProcess completion, ensuring that async
  child task progress continues to edit the original Telegram status message
  after the parent run has exited.
  """

  use GenServer

  require Logger

  alias CodingAgent.TaskProgressBindingStore
  alias CodingAgent.Tools.Task.Projection
  alias LemonCore.{Bus, Event}
  alias LemonRouter.{ChannelContext, ToolStatusCoalescer}

  @terminal_event_types [
    :run_completed,
    :task_completed,
    :task_error,
    :task_timeout,
    :task_aborted
  ]

  def start_link(opts) do
    binding = Keyword.fetch!(opts, :binding)
    meta = Keyword.get(opts, :meta, %{})

    GenServer.start_link(
      __MODULE__,
      %{binding: binding, meta: meta},
      name: via_tuple(binding.child_run_id)
    )
  end

  def child_spec(opts) do
    binding = Keyword.fetch!(opts, :binding)

    %{
      id: {__MODULE__, binding.child_run_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @doc """
  Start (or no-op if already running) an async task surface subscriber
  for the given child run.
  """
  def start_for_child_run(child_run_id, opts \\ []) when is_binary(child_run_id) do
    binding =
      case TaskProgressBindingStore.get_by_child_run_id(child_run_id) do
        {:ok, binding} -> Map.merge(opts[:fallback_binding] || %{}, binding)
        {:error, :not_found} -> opts[:fallback_binding] || %{}
      end

    cond do
      not is_map(binding) ->
        :ok

      not valid_binding?(binding) ->
        :ok

      true ->
        case DynamicSupervisor.start_child(
               LemonRouter.AsyncTaskSurfaceSupervisor,
               {__MODULE__, binding: binding, meta: opts[:meta] || %{}}
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    e ->
      Logger.warning("Failed to start async task surface subscriber: #{inspect(e)}")
      :ok
  end

  @impl true
  def init(%{binding: binding} = state) do
    Bus.subscribe(Bus.run_topic(binding.child_run_id))

    Logger.debug(
      "AsyncTaskSurfaceSubscriber started for child_run_id=#{binding.child_run_id} " <>
        "parent_run_id=#{binding.parent_run_id} surface=#{inspect(binding.surface)}"
    )

    {:ok, state}
  end

  @impl true
  def handle_info(%Event{type: :engine_action, payload: payload}, state)
      when is_map(payload) do
    with {:ok, channel_id} <- ChannelContext.channel_id(state.binding.parent_session_key) do
      projected = Projection.project_child_payload(payload, state.binding)

      ToolStatusCoalescer.ingest_projected_child_action(
        state.binding.parent_session_key,
        channel_id,
        state.binding.parent_run_id,
        state.binding.surface,
        projected,
        meta: state.meta
      )
    end

    {:noreply, state}
  rescue
    _ -> {:noreply, state}
  end

  def handle_info(%Event{type: type} = event, state) when type in @terminal_event_types do
    Logger.debug(
      "AsyncTaskSurfaceSubscriber terminal event type=#{type} " <>
        "child_run_id=#{state.binding.child_run_id}"
    )

    with {:ok, channel_id} <- ChannelContext.channel_id(state.binding.parent_session_key) do
      ToolStatusCoalescer.finalize_run(
        state.binding.parent_session_key,
        channel_id,
        state.binding.parent_run_id,
        terminal_ok?(event),
        surface: state.binding.surface,
        meta: state.meta
      )
    end

    _ = safe_delete_binding(state.binding.child_run_id)
    {:stop, :normal, state}
  rescue
    _ ->
      _ = safe_delete_binding(state.binding.child_run_id)
      {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- Private ----

  defp via_tuple(child_run_id) do
    {:via, Registry, {LemonRouter.AsyncTaskSurfaceRegistry, child_run_id}}
  end

  defp valid_binding?(binding) when is_map(binding) do
    is_binary(binding[:child_run_id]) and binding[:child_run_id] != "" and
      is_binary(binding[:parent_run_id]) and binding[:parent_run_id] != "" and
      is_binary(binding[:parent_session_key]) and binding[:parent_session_key] != "" and
      is_binary(binding[:root_action_id]) and binding[:root_action_id] != "" and
      binding[:surface] != nil
  end

  defp valid_binding?(_), do: false

  defp terminal_ok?(%Event{type: :task_completed}), do: true
  defp terminal_ok?(%Event{type: :run_completed, payload: payload}) when is_map(payload) do
    case payload do
      %{completed: %{ok: true}} -> true
      %{ok: true} -> true
      _ -> false
    end
  end
  defp terminal_ok?(_), do: false

  defp safe_delete_binding(child_run_id) do
    TaskProgressBindingStore.delete_by_child_run_id(child_run_id)
  rescue
    _ -> :ok
  end
end
