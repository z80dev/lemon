defmodule CodingAgent.Tools.TodoStore do
  @moduledoc """
  ETS-based storage for todo items per session.

  This module provides a simple key-value store for todo lists, where each
  session has its own todo list stored by session ID.

  ## Usage

      # Get todos for a session
      todos = CodingAgent.Tools.TodoStore.get("session-123")

      # Update todos for a session
      CodingAgent.Tools.TodoStore.put("session-123", [%{id: "1", content: "Task"}])

  ## Storage

  Uses an ETS table `:coding_agent_todos` with `read_concurrency: true`
  for efficient concurrent access.
  """

  @table :coding_agent_todos

  @doc """
  Get the todo list for a session.

  Returns an empty list if no todos exist for the session.

  ## Examples

      iex> TodoStore.get("session-123")
      [%{id: "1", content: "Task", status: "pending"}]

      iex> TodoStore.get("new-session")
      []
  """
  @spec get(String.t()) :: list(map())
  def get(session_id) when is_binary(session_id) do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, todos}] -> todos
      _ -> []
    end
  end

  @doc """
  Store the todo list for a session.

  ## Examples

      iex> TodoStore.put("session-123", [%{id: "1", content: "Task"}])
      :ok
  """
  @spec put(String.t(), list(map())) :: :ok
  def put(session_id, todos) when is_binary(session_id) and is_list(todos) do
    ensure_table()
    :ets.insert(@table, {session_id, todos})
    :ok
  end

  @doc """
  Deletes the todo list for a session.

  Returns :ok even if the session has no stored todos.
  """
  @spec delete(String.t()) :: :ok
  def delete(session_id) when is_binary(session_id) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        :ets.delete(@table, session_id)
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end

  @doc """
  Clears all todos from the store.

  Primarily used by tests to ensure isolation.

  If the ETS table has not been created yet, this is a no-op.
  """
  @spec clear() :: :ok
  def clear do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        :ets.delete_all_objects(@table)
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        # Try hard to avoid the ETS table being owned by a short-lived process
        # (e.g. Task processes in async tests). If a stable, supervised process
        # exists, set it as the ETS heir so the table survives owner exits.
        heir_opt =
          cond do
            is_pid(Process.whereis(CodingAgent.Tools.TodoStoreOwner)) ->
              [{:heir, Process.whereis(CodingAgent.Tools.TodoStoreOwner), @table}]

            is_pid(Process.whereis(CodingAgent.Supervisor)) ->
              [{:heir, Process.whereis(CodingAgent.Supervisor), @table}]

            true ->
              []
          end

        :ets.new(
          @table,
          [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ] ++ heir_opt
        )

        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end
end
