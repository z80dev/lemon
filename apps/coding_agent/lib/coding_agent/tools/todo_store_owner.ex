defmodule CodingAgent.Tools.TodoStoreOwner do
  @moduledoc false

  use GenServer

  @table :coding_agent_todos

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.get(opts, :table, @table), name: name)
  end

  @impl true
  def init(table) do
    new_table(table)
    {:ok, table}
  end

  @impl true
  def handle_call(:ensure_table, _from, table) do
    if :ets.whereis(table) == :undefined, do: new_table(table)
    {:reply, :ok, table}
  end

  defp new_table(table) do
    :ets.new(table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])
  end
end
