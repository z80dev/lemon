defmodule LemonCore.Dedupe.Owner do
  @moduledoc false
  use GenServer

  def start_link(table), do: GenServer.start_link(__MODULE__, table)

  @impl true
  def init(table) do
    # DynamicSupervisor serializes starts, including concurrent init/1 callers.
    # A restarted child receives the same name and recreates its empty cache.
    case :ets.whereis(table) do
      :undefined ->
        _ =
          :ets.new(table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])

        {:ok, table}

      _existing ->
        :ignore
    end
  end
end
