defmodule CodingAgent.TestStore do
  @moduledoc false

  # Minimal ETS-backed store implementation for tests. This avoids requiring
  # LemonGateway.Store (which is not a dependency of :coding_agent).

  @table :coding_agent_test_store

  def reset do
    ensure_table!()
    :ets.delete_all_objects(@table)
    :ok
  end

  def put(table, key, value) do
    ensure_table!()
    true = :ets.insert(@table, {{table, key}, value})
    :ok
  end

  def get(table, key) do
    ensure_table!()

    case :ets.lookup(@table, {table, key}) do
      [{{^table, ^key}, value}] -> value
      _ -> nil
    end
  end

  def delete(table, key) do
    ensure_table!()
    true = :ets.delete(@table, {table, key})
    :ok
  end

  def list(table) do
    ensure_table!()

    @table
    |> :ets.match_object({{table, :_}, :_})
    |> Enum.map(fn {{^table, key}, value} -> {key, value} end)
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])

        :ok

      _tid ->
        :ok
    end
  end
end

