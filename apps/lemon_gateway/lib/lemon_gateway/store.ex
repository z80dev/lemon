defmodule LemonGateway.Store do
  @moduledoc """
  Persistent key-value store with pluggable backends.

  ## Configuration

  Configure the backend in your application config:

      config :lemon_gateway, LemonGateway.Store,
        backend: LemonGateway.Store.JsonlBackend,
        backend_opts: [path: "/var/lib/lemon/store"]

  Defaults to `LemonGateway.Store.EtsBackend` (in-memory, ephemeral).
  """

  use GenServer

  alias LemonGateway.Store.EtsBackend

  @default_backend EtsBackend

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Chat State API

  @spec put_chat_state(term(), map()) :: :ok
  def put_chat_state(scope, state), do: GenServer.cast(__MODULE__, {:put_chat_state, scope, state})

  @spec get_chat_state(term()) :: map() | nil
  def get_chat_state(scope), do: GenServer.call(__MODULE__, {:get_chat_state, scope})

  # Run Events API

  @spec append_run_event(term(), term()) :: :ok
  def append_run_event(run_id, event), do: GenServer.cast(__MODULE__, {:append_run_event, run_id, event})

  @spec finalize_run(term(), map()) :: :ok
  def finalize_run(run_id, summary), do: GenServer.cast(__MODULE__, {:finalize_run, run_id, summary})

  # Progress Mapping API

  @spec put_progress_mapping(term(), integer(), term()) :: :ok
  def put_progress_mapping(scope, progress_msg_id, run_id) do
    GenServer.cast(__MODULE__, {:put_progress_mapping, scope, progress_msg_id, run_id})
  end

  @spec get_run_by_progress(term(), integer()) :: term() | nil
  def get_run_by_progress(scope, progress_msg_id) do
    GenServer.call(__MODULE__, {:get_run_by_progress, scope, progress_msg_id})
  end

  @spec delete_progress_mapping(term(), integer()) :: :ok
  def delete_progress_mapping(scope, progress_msg_id) do
    GenServer.cast(__MODULE__, {:delete_progress_mapping, scope, progress_msg_id})
  end

  # Run History API

  @doc """
  Get run history for a scope, ordered by most recent first.

  ## Options

    * `:limit` - Maximum number of runs to return (default: 10)

  Returns a list of `{run_id, %{events: [...], summary: %{...}, scope: scope, started_at: ts}}`.
  """
  @spec get_run_history(term(), keyword()) :: [{term(), map()}]
  def get_run_history(scope, opts \\ []) do
    GenServer.call(__MODULE__, {:get_run_history, scope, opts})
  end

  @doc """
  Get a specific run by ID.
  """
  @spec get_run(term()) :: map() | nil
  def get_run(run_id) do
    GenServer.call(__MODULE__, {:get_run, run_id})
  end

  # GenServer Implementation

  @impl true
  def init(_opts) do
    config = Application.get_env(:lemon_gateway, __MODULE__, [])
    backend = Keyword.get(config, :backend, @default_backend)
    backend_opts = Keyword.get(config, :backend_opts, [])

    case backend.init(backend_opts) do
      {:ok, backend_state} ->
        {:ok, %{backend: backend, backend_state: backend_state}}

      {:error, reason} ->
        {:stop, {:backend_init_failed, reason}}
    end
  end

  @impl true
  def handle_call({:get_chat_state, scope}, _from, state) do
    {:ok, value, backend_state} = state.backend.get(state.backend_state, :chat, scope)
    {:reply, value, %{state | backend_state: backend_state}}
  end

  def handle_call({:get_run_by_progress, scope, progress_msg_id}, _from, state) do
    key = {scope, progress_msg_id}
    {:ok, value, backend_state} = state.backend.get(state.backend_state, :progress, key)
    {:reply, value, %{state | backend_state: backend_state}}
  end

  def handle_call({:get_run, run_id}, _from, state) do
    {:ok, value, backend_state} = state.backend.get(state.backend_state, :runs, run_id)
    {:reply, value, %{state | backend_state: backend_state}}
  end

  def handle_call({:get_run_history, scope, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)

    {:ok, all_history, backend_state} = state.backend.list(state.backend_state, :run_history)

    # Filter by scope and sort by timestamp (most recent first)
    history =
      all_history
      |> Enum.filter(fn {{s, _ts, _run_id}, _data} -> s == scope end)
      |> Enum.sort_by(fn {{_s, ts, _run_id}, _data} -> ts end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {{_scope, _ts, run_id}, data} -> {run_id, data} end)

    {:reply, history, %{state | backend_state: backend_state}}
  end

  @impl true
  def handle_cast({:put_chat_state, scope, value}, state) do
    {:ok, backend_state} = state.backend.put(state.backend_state, :chat, scope, value)
    {:noreply, %{state | backend_state: backend_state}}
  end

  def handle_cast({:append_run_event, run_id, event}, state) do
    {:ok, existing, backend_state} = state.backend.get(state.backend_state, :runs, run_id)

    record = existing || %{events: [], summary: nil, started_at: System.system_time(:millisecond)}
    record = %{record | events: [event | record.events]}

    {:ok, backend_state} = state.backend.put(backend_state, :runs, run_id, record)
    {:noreply, %{state | backend_state: backend_state}}
  end

  def handle_cast({:finalize_run, run_id, summary}, state) do
    {:ok, existing, backend_state} = state.backend.get(state.backend_state, :runs, run_id)

    record = existing || %{events: [], summary: nil, started_at: System.system_time(:millisecond)}
    record = %{record | summary: summary}

    {:ok, backend_state} = state.backend.put(backend_state, :runs, run_id, record)

    # Also add to run_history for efficient querying by scope
    scope = Map.get(summary, :scope)
    started_at = record.started_at

    if scope do
      history_key = {scope, started_at, run_id}
      history_data = %{events: record.events, summary: summary, scope: scope, started_at: started_at}
      {:ok, backend_state} = state.backend.put(backend_state, :run_history, history_key, history_data)
      {:noreply, %{state | backend_state: backend_state}}
    else
      {:noreply, %{state | backend_state: backend_state}}
    end
  end

  def handle_cast({:put_progress_mapping, scope, progress_msg_id, run_id}, state) do
    key = {scope, progress_msg_id}
    {:ok, backend_state} = state.backend.put(state.backend_state, :progress, key, run_id)
    {:noreply, %{state | backend_state: backend_state}}
  end

  def handle_cast({:delete_progress_mapping, scope, progress_msg_id}, state) do
    key = {scope, progress_msg_id}
    {:ok, backend_state} = state.backend.delete(state.backend_state, :progress, key)
    {:noreply, %{state | backend_state: backend_state}}
  end
end
