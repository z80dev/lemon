defmodule CodingAgent.ParentQuestionStoreServer do
  @moduledoc """
  GenServer that owns the ParentQuestions ETS table and manages DETS persistence.

  Waiting parent-question requests cannot be resumed after a restart because the
  child tool execution task is gone, so any `:waiting` entries loaded from DETS
  are marked as `:error` with `:lost_on_restart`.
  """

  use CodingAgent.DurableTable

  @table :coding_agent_parent_questions
  @dets_table :coding_agent_parent_questions_dets
  @default_ttl_seconds 86_400
  @max_events 100

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.start_link(__MODULE__, opts, name: name) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  def table_name, do: @table

  def ensure_table(server \\ __MODULE__) do
    GenServer.call(server, :ensure_table, 5_000)
  end

  def cleanup(server \\ __MODULE__, ttl_seconds \\ @default_ttl_seconds) do
    GenServer.call(server, {:cleanup, ttl_seconds}, 30_000)
  end

  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear, 5_000)
  end

  @doc "Atomically create a request when its child scope has no open request."
  @spec create(map(), GenServer.server()) :: {:ok, map()} | {:error, :already_waiting}
  def create(record, server \\ __MODULE__) when is_map(record) do
    GenServer.call(server, {:create, record}, 10_000)
  end

  @doc "Acknowledge parent enqueueing before a waiting request can release its task join."
  @spec mark_delivered(String.t(), GenServer.server()) :: :ok | {:error, :not_found}
  def mark_delivered(request_id, server \\ __MODULE__) when is_binary(request_id) do
    GenServer.call(server, {:mark_delivered, request_id}, 10_000)
  end

  @doc "Atomically transition a waiting request and return the winning record."
  @spec transition(String.t(), atom(), map(), term(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def transition(request_id, status, updates, authorization \\ :none, server \\ __MODULE__)
      when is_binary(request_id) and is_atom(status) and is_map(updates) do
    GenServer.call(
      server,
      {:transition, request_id, status, updates, authorization},
      10_000
    )
  end

  @doc "Atomically append a bounded lifecycle event."
  @spec append_event(String.t(), term(), GenServer.server()) :: :ok
  def append_event(request_id, event, server \\ __MODULE__) when is_binary(request_id) do
    GenServer.call(server, {:append_event, request_id, event}, 10_000)
  end

  @impl true
  def init(opts) do
    state =
      DurableTable.open(%{}, opts,
        table: @table,
        dets_table: @dets_table,
        path: dets_path(opts),
        normalize: &__MODULE__.normalize_row/2,
        timestamp: &__MODULE__.expiry_timestamp/1,
        ttl_key: :parent_question_store_ttl_seconds,
        interval_key: :parent_question_store_cleanup_interval_seconds
      )

    {:ok, state}
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    state = ensure_tables(state)
    {:reply, :ok, state}
  end

  def handle_call({:create, record}, _from, state) do
    state = ensure_tables(state)
    child_scope_id = Map.fetch!(record, :child_scope_id)

    if waiting_for_child_scope?(child_scope_id) do
      {:reply, {:error, :already_waiting}, state}
    else
      request_id = Map.fetch!(record, :id)
      do_insert_record(request_id, record, [])
      {:reply, {:ok, record}, state}
    end
  end

  def handle_call({:mark_delivered, request_id}, _from, state) do
    state = ensure_tables(state)

    reply =
      case :ets.lookup(@table, request_id) do
        [{^request_id, %{status: :waiting} = record, events}] ->
          updated = %{record | delivery_pending: false, updated_at: System.system_time(:second)}
          do_insert_record(request_id, updated, events)

          if is_binary(updated[:child_run_id]) do
            LemonCore.Bus.broadcast(
              LemonCore.Bus.run_topic(updated.child_run_id),
              {:parent_question, :delivered, request_id}
            )
          end

          :ok

        [{^request_id, _terminal_record, _events}] ->
          :ok

        [] ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:transition, request_id, status, updates, authorization},
        _from,
        state
      ) do
    state = ensure_tables(state)

    reply =
      case :ets.lookup(@table, request_id) do
        [{^request_id, %{status: :waiting} = record, events}] ->
          with :ok <- authorize(record, authorization) do
            now = System.system_time(:second)

            updated =
              record
              |> Map.merge(updates)
              |> Map.put(:status, status)
              |> Map.put(:completed_at, now)
              |> Map.put(:updated_at, now)

            do_insert_record(request_id, updated, events)
            {:ok, updated}
          end

        [{^request_id, record, _events}] ->
          {:error, {:invalid_status, Map.get(record, :status)}}

        _ ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:append_event, request_id, event}, _from, state) do
    state = ensure_tables(state)

    case :ets.lookup(@table, request_id) do
      [{^request_id, record, events}] ->
        updated_events = [event | events] |> Enum.take(@max_events)
        updated_record = Map.put(record, :updated_at, System.system_time(:second))
        do_insert_record(request_id, updated_record, updated_events)

      _ ->
        :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:cleanup, ttl_seconds}, _from, state) do
    state = ensure_tables(state)
    {:reply, {:ok, DurableTable.cleanup(state, ttl_seconds)}, state}
  end

  def handle_call(:clear, _from, state) do
    state = ensure_tables(state)

    DurableTable.clear(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    state = ensure_tables(state)

    DurableTable.periodic_cleanup(state)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp ensure_tables(state), do: DurableTable.ensure(state)

  @doc false
  def normalize_row({request_id, record, events}, _state) do
    record =
      if record[:status] == :waiting do
        record
        |> Map.put(:status, :error)
        |> Map.put(:error, :lost_on_restart)
        |> Map.put(:completed_at, System.system_time(:second))
      else
        record
      end

    {request_id, record, events}
  end

  defp waiting_for_child_scope?(child_scope_id) do
    :ets.foldl(
      fn
        {_id, %{child_scope_id: ^child_scope_id, status: :waiting}, _events}, _acc -> true
        _entry, acc -> acc
      end,
      false,
      @table
    )
  end

  defp authorize(_record, :none), do: :ok

  defp authorize(record, {:parent, session_key, agent_id}) do
    if non_empty_binary?(session_key) and non_empty_binary?(agent_id) and
         session_key == Map.get(record, :parent_session_key) and
         agent_id == Map.get(record, :parent_agent_id) do
      :ok
    else
      {:error, :wrong_parent}
    end
  end

  defp authorize(_record, _authorization), do: {:error, :wrong_parent}

  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp do_insert_record(request_id, record, events),
    do: DurableTable.put(@table, {request_id, record, events})

  @doc false
  def expiry_timestamp({_id, record, _events}) do
    if record[:status] in [:answered, :timed_out, :cancelled, :error],
      do: DurableTable.terminal_timestamp(record)
  end

  defp dets_path(opts) do
    Keyword.get(opts, :dets_path) ||
      Application.get_env(:coding_agent, :parent_question_store_path) ||
      CodingAgent.StatePaths.dets_path("parent_questions.dets")
  end
end
