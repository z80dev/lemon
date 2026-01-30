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

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end
end
