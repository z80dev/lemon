defmodule LemonServices.Runtime.LogBuffer do
  @moduledoc """
  Circular buffer for service logs.

  Stores the last N log lines in memory (ETS).
  Provides:
  - Append new log lines
  - Get recent logs
  - Stream logs to subscribers via PubSub

  Uses a separate TableOwner process to own the ETS table
  so it survives process restarts.
  """
  use GenServer

  @default_max_lines 1000
  @table :lemon_services_log_buffers

  # Client API

  def start_link(opts) do
    service_id = Keyword.fetch!(opts, :service_id)
    GenServer.start_link(__MODULE__, service_id, name: via_tuple(service_id))
  end

  @doc """
  Appends a log line to the buffer.
  """
  @spec append(atom(), map()) :: :ok
  def append(service_id, log_line) when is_atom(service_id) do
    GenServer.cast(via_tuple(service_id), {:append, log_line})
  end

  @doc """
  Gets the last N log lines.
  """
  @spec get_logs(atom(), non_neg_integer()) :: [map()]
  def get_logs(service_id, count \\ 100) when is_atom(service_id) do
    case :ets.lookup(@table, service_id) do
      [{^service_id, buffer, _index}] ->
        buffer
        |> :queue.to_list()
        |> Enum.take(-count)

      [] ->
        []
    end
  end

  @doc """
  Clears the log buffer for a service.
  """
  @spec clear(atom()) :: :ok
  def clear(service_id) when is_atom(service_id) do
    GenServer.cast(via_tuple(service_id), :clear)
  end

  # Server Callbacks

  @impl true
  def init(service_id) do
    # Create or reset the buffer entry in ETS
    :ets.insert(@table, {service_id, :queue.new(), 0})
    {:ok, %{service_id: service_id, max_lines: @default_max_lines}}
  end

  @impl true
  def handle_cast({:append, log_line}, state) do
    service_id = state.service_id
    [{^service_id, buffer, index}] = :ets.lookup(@table, service_id)

    # Add sequence number
    log_line = Map.put(log_line, :sequence, index)

    # Add to queue
    new_buffer = :queue.in(log_line, buffer)

    # Trim if over max
    new_buffer =
      if :queue.len(new_buffer) > state.max_lines do
        {{:value, _}, q} = :queue.out(new_buffer)
        q
      else
        new_buffer
      end

    :ets.insert(@table, {state.service_id, new_buffer, index + 1})

    {:noreply, state}
  end

  @impl true
  def handle_cast(:clear, state) do
    :ets.insert(@table, {state.service_id, :queue.new(), 0})
    {:noreply, state}
  end

  defp via_tuple(service_id) do
    {:via, Registry, {LemonServices.Registry, {:log_buffer, service_id}}}
  end

  # Table Owner - owns the ETS table
  defmodule TableOwner do
    @moduledoc """
    GenServer that owns the log buffer ETS table.
    This ensures the table survives restarts of individual log buffers.
    """
    use GenServer

    @table :lemon_services_log_buffers

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    @impl true
    def init(_) do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      {:ok, %{}}
    end
  end
end
