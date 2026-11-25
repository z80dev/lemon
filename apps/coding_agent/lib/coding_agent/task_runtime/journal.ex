defmodule CodingAgent.TaskRuntime.Journal do
  @moduledoc """
  Node-local snapshots of task owner state that outlive an owner crash.

  Each owner writes only its own row; this process only owns the table. Rows
  hold live handles and callbacks, so they never leave the node or the VM and
  are not persisted. An owner deletes its row when it stops normally.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end

  @impl true
  def format_status(status), do: LemonCore.StatusRedaction.gen_server(status, [])

  @doc false
  def put(id, row), do: :ets.insert(@table, {id, row})

  @doc false
  def fetch(id) do
    case :ets.lookup(@table, id) do
      [{^id, row}] -> {:ok, row}
      [] -> :error
    end
  end

  @doc false
  def delete(id), do: :ets.delete(@table, id)

  @doc false
  def ids, do: :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
end
