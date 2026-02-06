defmodule AgentCore.AbortSignal.TableOwner do
  @moduledoc false

  use GenServer

  @table :agent_core_abort_signals

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    ensure_table()
    {:ok, %{}}
  end

  # If another process created the table with this process as heir, ETS will send this message
  # when the original owner exits.
  @impl true
  def handle_info({:"ETS-TRANSFER", @table, _from, _gift_data}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end
end
