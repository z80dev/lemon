defmodule CodingAgent.Tools.Task.LiveBridge do
  @moduledoc false

  use GenServer

  alias CodingAgent.TaskProgressBindingStore
  alias LemonCore.{Bus, Event}

  @terminal_event_types [
    :run_completed,
    :task_completed,
    :task_error,
    :task_timeout,
    :task_aborted
  ]

  def start_link(binding) when is_map(binding) do
    GenServer.start_link(__MODULE__, binding)
  end

  def child_spec(binding) when is_map(binding) do
    %{
      id: {__MODULE__, binding.child_run_id},
      start: {__MODULE__, :start_link, [binding]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  def start_for_child_run(child_run_id) when is_binary(child_run_id) do
    case TaskProgressBindingStore.get_by_child_run_id(child_run_id) do
      {:ok, binding} ->
        case DynamicSupervisor.start_child(
               CodingAgent.Tools.Task.LiveBridgeSupervisor,
               {__MODULE__, binding}
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        :ok
    end
  end

  def start_for_child_run(_), do: :ok

  @impl true
  def init(binding) do
    Bus.subscribe(Bus.run_topic(binding.child_run_id))
    {:ok, %{binding: binding}}
  end

  @impl true
  def handle_info(%Event{type: :engine_action, payload: payload}, state) when is_map(payload) do
    projected_payload =
      CodingAgent.Tools.Task.Projection.project_child_payload(payload, state.binding)

    event =
      Event.new(:task_projected_child_action, projected_payload, %{
        run_id: state.binding.parent_run_id,
        parent_run_id: state.binding.parent_run_id,
        session_key: state.binding.parent_session_key,
        child_run_id: state.binding.child_run_id,
        task_id: state.binding.task_id,
        projected_from: :child_run
      })

    Bus.broadcast(Bus.run_topic(state.binding.parent_run_id), event)
    {:noreply, state}
  end

  def handle_info(%Event{type: type}, state) when type in @terminal_event_types do
    :ok = TaskProgressBindingStore.delete_by_child_run_id(state.binding.child_run_id)
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
