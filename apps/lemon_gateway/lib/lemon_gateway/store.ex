defmodule LemonGateway.Store do
  @moduledoc false
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec put_chat_state(term(), map()) :: :ok
  def put_chat_state(scope, state), do: GenServer.cast(__MODULE__, {:put_chat_state, scope, state})

  @spec get_chat_state(term()) :: map() | nil
  def get_chat_state(scope), do: GenServer.call(__MODULE__, {:get_chat_state, scope})

  @spec append_run_event(term(), term()) :: :ok
  def append_run_event(run_id, event), do: GenServer.cast(__MODULE__, {:append_run_event, run_id, event})

  @spec finalize_run(term(), map()) :: :ok
  def finalize_run(run_id, summary), do: GenServer.cast(__MODULE__, {:finalize_run, run_id, summary})

  @spec put_progress_mapping(term(), integer(), term()) :: :ok
  def put_progress_mapping(scope, progress_msg_id, run_id) do
    GenServer.cast(__MODULE__, {:put_progress_mapping, scope, progress_msg_id, run_id})
  end

  @spec get_run_by_progress(term(), integer()) :: term() | nil
  def get_run_by_progress(scope, progress_msg_id) do
    GenServer.call(__MODULE__, {:get_run_by_progress, scope, progress_msg_id})
  end

  @impl true
  def init(_opts) do
    tables = %{
      chat: :ets.new(:lemon_gateway_chat, [:set, :protected]),
      progress: :ets.new(:lemon_gateway_progress, [:set, :protected]),
      runs: :ets.new(:lemon_gateway_runs, [:set, :protected])
    }

    {:ok, tables}
  end

  @impl true
  def handle_call({:get_chat_state, scope}, _from, state) do
    reply =
      case :ets.lookup(state.chat, scope) do
        [{^scope, value}] -> value
        _ -> nil
      end

    {:reply, reply, state}
  end

  def handle_call({:get_run_by_progress, scope, progress_msg_id}, _from, state) do
    key = {scope, progress_msg_id}

    reply =
      case :ets.lookup(state.progress, key) do
        [{^key, run_id}] -> run_id
        _ -> nil
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:put_chat_state, scope, value}, state) do
    :ets.insert(state.chat, {scope, value})
    {:noreply, state}
  end

  def handle_cast({:append_run_event, run_id, event}, state) do
    events =
      case :ets.lookup(state.runs, run_id) do
        [{^run_id, value}] -> value
        _ -> %{events: [], summary: nil}
      end

    events = %{events | events: [event | events.events]}
    :ets.insert(state.runs, {run_id, events})
    {:noreply, state}
  end

  def handle_cast({:finalize_run, run_id, summary}, state) do
    record =
      case :ets.lookup(state.runs, run_id) do
        [{^run_id, value}] -> value
        _ -> %{events: [], summary: nil}
      end

    :ets.insert(state.runs, {run_id, %{record | summary: summary}})
    {:noreply, state}
  end

  def handle_cast({:put_progress_mapping, scope, progress_msg_id, run_id}, state) do
    :ets.insert(state.progress, {{scope, progress_msg_id}, run_id})
    {:noreply, state}
  end
end
