defmodule AgentCore.AbortSignal do
  @moduledoc false

  @table :agent_core_abort_signals

  @spec new() :: reference()
  def new do
    ensure_table()
    ref = make_ref()
    :ets.insert(@table, {ref, false})
    ref
  end

  @spec abort(reference()) :: :ok
  def abort(ref) when is_reference(ref) do
    ensure_table()
    :ets.insert(@table, {ref, true})
    :ok
  end

  @spec aborted?(reference() | nil) :: boolean()
  def aborted?(nil), do: false

  def aborted?(ref) when is_reference(ref) do
    ensure_table()

    case :ets.lookup(@table, ref) do
      [{^ref, true}] -> true
      _ -> false
    end
  end

  @spec clear(reference() | nil) :: :ok
  def clear(nil), do: :ok

  def clear(ref) when is_reference(ref) do
    ensure_table()
    :ets.delete(@table, ref)
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        heir = Process.whereis(:init)

        opts =
          [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ] ++
            if is_pid(heir) do
              [{:heir, heir, :ok}]
            else
              []
            end

        :ets.new(@table, opts)
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end
end
