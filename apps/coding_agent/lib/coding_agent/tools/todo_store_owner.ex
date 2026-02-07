defmodule CodingAgent.Tools.TodoStoreOwner do
  @moduledoc false

  use GenServer

  @table :coding_agent_todos

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @impl true
  def init(state) do
    # Ensure the ETS table is owned by a long-lived supervised process. Without
    # this, the first caller to TodoStore.get/put may create the table, and the
    # table will be destroyed when that caller process exits (common in tests).
    _ =
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

        _tid ->
          :ok
      end

    {:ok, state}
  end
end
