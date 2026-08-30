defmodule CodingAgent.ParentQuestionStoreServer do
  @moduledoc """
  GenServer that owns the ParentQuestions ETS table and manages DETS persistence.

  Waiting parent-question requests cannot be resumed after a restart because the
  child tool execution task is gone, so any `:waiting` entries loaded from DETS
  are marked as `:error` with `:lost_on_restart`.
  """

  use GenServer
  require Logger

  @table :coding_agent_parent_questions
  @dets_table :coding_agent_parent_questions_dets
  @default_ttl_seconds 86_400
  @cleanup_interval_seconds 300
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
    Process.flag(:trap_exit, true)

    state = %{
      table: @table,
      dets_table: @dets_table,
      dets_path: dets_path(opts),
      ets_initialized: false,
      dets_initialized: false,
      loaded_from_dets: false
    }

    state = initialize_ets(state)
    state = initialize_dets(state)
    state = maybe_load_from_dets(state)
    schedule_cleanup()

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
    {:reply, {:ok, do_cleanup(ttl_seconds)}, state}
  end

  def handle_call(:clear, _from, state) do
    state = ensure_tables(state)

    if state.ets_initialized do
      :ets.delete_all_objects(@table)
    end

    if state.dets_initialized do
      :dets.delete_all_objects(@dets_table)
      :dets.sync(@dets_table)
    end

    {:reply, :ok, %{state | loaded_from_dets: false}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    state = ensure_tables(state)

    ttl_seconds =
      Application.get_env(
        :coding_agent,
        :parent_question_store_ttl_seconds,
        @default_ttl_seconds
      )

    _deleted_count = do_cleanup(ttl_seconds)
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.dets_initialized do
      :dets.close(@dets_table)
    end

    :ok
  end

  defp ensure_tables(state) do
    state
    |> initialize_ets()
    |> initialize_dets()
    |> maybe_load_from_dets()
  end

  defp initialize_ets(state) do
    if state.ets_initialized do
      state
    else
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          %{state | ets_initialized: true}

        _tid ->
          %{state | ets_initialized: true}
      end
    end
  end

  defp initialize_dets(state) do
    if state.dets_initialized do
      state
    else
      File.mkdir_p!(Path.dirname(state.dets_path))

      dets_file = String.to_charlist(state.dets_path)

      case :dets.open_file(@dets_table, file: dets_file, type: :set) do
        {:ok, _} ->
          %{state | dets_initialized: true}

        {:error, {:already_open, _pid}} ->
          %{state | dets_initialized: true}

        {:error, reason} ->
          Logger.warning("Failed to open parent question DETS: #{inspect(reason)}")
          state
      end
    end
  end

  defp maybe_load_from_dets(%{loaded_from_dets: true} = state), do: state

  defp maybe_load_from_dets(state) do
    if state.dets_initialized and state.ets_initialized do
      now = System.system_time(:second)

      :dets.foldl(
        fn {request_id, record, events}, :ok ->
          record =
            if Map.get(record, :status) == :waiting do
              record
              |> Map.put(:status, :error)
              |> Map.put(:error, :lost_on_restart)
              |> Map.put(:completed_at, now)
            else
              record
            end

          :ets.insert(@table, {request_id, record, events})
          :ok
        end,
        :ok,
        @dets_table
      )

      %{state | loaded_from_dets: true}
    else
      state
    end
  end

  defp do_cleanup(ttl_seconds) do
    now = System.system_time(:second)

    expired_ids =
      :ets.foldl(
        fn {request_id, record, _events}, acc ->
          if expired_record?(record, now, ttl_seconds) do
            [request_id | acc]
          else
            acc
          end
        end,
        [],
        @table
      )

    Enum.each(expired_ids, fn request_id ->
      :ets.delete(@table, request_id)

      if dets_open?() do
        :dets.delete(@dets_table, request_id)
      end
    end)

    if dets_open?() and expired_ids != [] do
      :dets.sync(@dets_table)
    end

    length(expired_ids)
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

  defp do_insert_record(request_id, record, events) do
    :ets.insert(@table, {request_id, record, events})

    if dets_open?() do
      :dets.insert(@dets_table, {request_id, record, events})
    end

    :ok
  end

  defp expired_record?(record, now, ttl_seconds) do
    status = Map.get(record, :status)

    if status in [:answered, :timed_out, :cancelled, :error] do
      completed_at =
        Map.get(record, :completed_at) || Map.get(record, :updated_at) ||
          Map.get(record, :inserted_at)

      is_integer(completed_at) and now - completed_at >= ttl_seconds
    else
      false
    end
  end

  defp dets_open? do
    :dets.info(@dets_table) != :undefined
  rescue
    _ -> false
  end

  defp schedule_cleanup do
    interval =
      Application.get_env(
        :coding_agent,
        :parent_question_store_cleanup_interval_seconds,
        @cleanup_interval_seconds
      )

    Process.send_after(self(), :cleanup, interval * 1_000)
  end

  defp dets_path(opts) do
    Keyword.get(opts, :dets_path) ||
      Application.get_env(:coding_agent, :parent_question_store_path) ||
      Path.join(CodingAgent.Config.agent_dir(), "parent_questions.dets")
  end
end
