defmodule LemonCore.SessionLifecycle.StoreRows do
  @moduledoc """
  Building blocks for `LemonCore.SessionLifecycle.Participant` owners whose
  session state is rows in generic `LemonCore.Store` tables.

  Tables are named directly and keyed by the session key; owners whose rows
  are keyed otherwise select them in their own wrapper and pass the rows to
  `delete/1`, `verify_deleted/3` and `restore/1`. Reads are strict: an
  unreadable table is `{:error, :store_unavailable}`, never an empty snapshot.
  """

  alias LemonCore.Store

  @type row :: {table :: atom(), key :: term(), value :: term()}

  @doc "Strictly read the row of `session_key` in each table."
  @spec snapshot(String.t(), [atom()]) :: {:ok, [row()]} | {:error, :store_unavailable}
  def snapshot(session_key, tables) do
    Enum.reduce_while(tables, {:ok, []}, fn table, {:ok, rows} ->
      case Store.fetch(table, session_key) do
        {:ok, nil} -> {:cont, {:ok, rows}}
        {:ok, value} -> {:cont, {:ok, rows ++ [{table, session_key, value}]}}
        {:error, _} -> {:halt, {:error, :store_unavailable}}
      end
    end)
  end

  @doc "Delete the snapshot's rows."
  @spec delete([row()]) :: :ok | {:error, term()}
  def delete(rows), do: each(rows, fn {table, key, _value} -> Store.delete(table, key) end)

  @doc """
  Strictly verify that no table holds a row of the session and that every
  snapshot row (including rows selected through other keys) is gone.
  """
  @spec verify_deleted(String.t(), [atom()], [row()]) :: :ok | {:error, term()}
  def verify_deleted(session_key, tables, rows) do
    with {:ok, []} <- snapshot(session_key, tables),
         :ok <- each(rows, &absent/1) do
      :ok
    else
      {:ok, _remaining} -> {:error, :rows_remain}
      error -> error
    end
  end

  @doc "Write the snapshot's rows back."
  @spec restore([row()]) :: :ok | {:error, term()}
  def restore(rows), do: each(rows, fn {table, key, value} -> Store.put(table, key, value) end)

  defp absent({table, key, _value}) do
    case Store.fetch(table, key) do
      {:ok, nil} -> :ok
      {:ok, _remaining} -> {:error, :rows_remain}
      error -> error
    end
  end

  defp each(rows, fun) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case fun.(row) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
