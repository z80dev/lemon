defmodule CodingAgent.Tools.TodoStore do
  @moduledoc """
  ETS-based storage for todo items per session with dependency tracking.

  This module provides a key-value store for todo lists with enhanced features:
  - Dependency tracking between todos
  - Progress statistics
  - Priority levels
  - Status tracking (pending, in_progress, completed, blocked)

  ## Usage

      # Get todos for a session
      todos = CodingAgent.Tools.TodoStore.get("session-123")

      # Update todos for a session
      CodingAgent.Tools.TodoStore.put("session-123", [%{id: "1", content: "Task"}])

      # Get actionable todos (dependencies met)
      actionable = CodingAgent.Tools.TodoStore.get_actionable("session-123")

      # Get progress statistics
      stats = CodingAgent.Tools.TodoStore.get_progress("session-123")

  ## Storage

  Uses an ETS table `:coding_agent_todos` with `read_concurrency: true`
  for efficient concurrent access.
  """

  @table :coding_agent_todos

  @type todo_status :: :pending | :in_progress | :completed | :blocked
  @type todo_priority :: :high | :medium | :low

  @type todo_item :: %{
          id: String.t(),
          content: String.t(),
          status: todo_status(),
          dependencies: [String.t()],
          priority: todo_priority(),
          estimated_effort: String.t() | nil,
          created_at: String.t(),
          updated_at: String.t() | nil,
          completed_at: String.t() | nil,
          metadata: map()
        }

  @type progress_stats :: %{
          total: non_neg_integer(),
          completed: non_neg_integer(),
          in_progress: non_neg_integer(),
          blocked: non_neg_integer(),
          pending: non_neg_integer(),
          percentage: non_neg_integer()
        }

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

  @doc """
  Get actionable todos - those whose dependencies are all completed.

  Returns todos that are:
  - Status is :pending or :in_progress
  - All dependencies have status :completed

  Results are sorted by priority (high -> medium -> low).

  ## Examples

      iex> TodoStore.get_actionable("session-123")
      [%{id: "2", content: "Next task", status: :pending, priority: :high}]
  """
  @spec get_actionable(String.t()) :: [todo_item()]
  def get_actionable(session_id) when is_binary(session_id) do
    todos = get(session_id)

    completed_ids =
      todos
      |> Enum.filter(&(todo_status(&1) == :completed))
      |> Enum.map(&todo_id/1)

    priority_order = %{high: 0, medium: 1, low: 2}

    todos
    |> Enum.filter(fn todo ->
      todo_status(todo) in [:pending, :in_progress] and
        Enum.all?(todo_dependencies(todo), &(&1 in completed_ids))
    end)
    |> Enum.sort_by(&(priority_order[todo_priority(&1)] || 999))
  end

  @doc """
  Get progress statistics for todos in a session.

  Returns a map with counts and percentage completion.

  ## Examples

      iex> TodoStore.get_progress("session-123")
      %{
        total: 10,
        completed: 5,
        in_progress: 2,
        blocked: 1,
        pending: 2,
        percentage: 50
      }
  """
  @spec get_progress(String.t()) :: progress_stats()
  def get_progress(session_id) when is_binary(session_id) do
    todos = get(session_id)
    total = length(todos)

    completed = Enum.count(todos, &(todo_status(&1) == :completed))
    in_progress = Enum.count(todos, &(todo_status(&1) == :in_progress))
    blocked = Enum.count(todos, &(todo_status(&1) == :blocked))
    pending = Enum.count(todos, &(todo_status(&1) == :pending))

    percentage = if total > 0, do: div(completed * 100, total), else: 0

    %{
      total: total,
      completed: completed,
      in_progress: in_progress,
      blocked: blocked,
      pending: pending,
      percentage: percentage
    }
  end

  @doc """
  Update the status of a specific todo item.

  Automatically sets updated_at timestamp and completed_at when appropriate.

  ## Examples

      iex> TodoStore.update_status("session-123", "todo-1", :completed)
      :ok
  """
  @spec update_status(String.t(), String.t(), todo_status()) :: :ok
  def update_status(session_id, todo_id, status)
      when is_binary(session_id) and is_binary(todo_id) do
    todos = get(session_id)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    updated_todos =
      Enum.map(todos, fn todo ->
        if todo_id(todo) == todo_id do
          completed_at = if status == :completed, do: now, else: todo_completed_at(todo)

          todo
          |> put_todo_value(:status, status, Atom.to_string(status))
          |> put_todo_value(:updated_at, now, now)
          |> put_todo_value(:completed_at, completed_at, completed_at)
        else
          todo
        end
      end)

    put(session_id, updated_todos)
  end

  @doc """
  Mark a todo as completed.

  Convenience function that wraps update_status/3.

  ## Examples

      iex> TodoStore.complete("session-123", "todo-1")
      :ok
  """
  @spec complete(String.t(), String.t()) :: :ok
  def complete(session_id, todo_id) when is_binary(session_id) and is_binary(todo_id) do
    update_status(session_id, todo_id, :completed)
  end

  @doc """
  Check if all todos in a session are completed.

  Returns true if there are no todos or all todos have status :completed.

  ## Examples

      iex> TodoStore.all_completed?("session-123")
      false
  """
  @spec all_completed?(String.t()) :: boolean()
  def all_completed?(session_id) when is_binary(session_id) do
    todos = get(session_id)

    case todos do
      [] -> true
      _ -> Enum.all?(todos, &(todo_status(&1) == :completed))
    end
  end

  @doc """
  Get todos that are blocking other todos.

  Returns todos that:
  - Are not completed
  - Have dependents that are pending or in_progress

  ## Examples

      iex> TodoStore.get_blocking("session-123")
      [%{id: "1", content: "Blocking task", status: :in_progress}]
  """
  @spec get_blocking(String.t()) :: [todo_item()]
  def get_blocking(session_id) when is_binary(session_id) do
    todos = get(session_id)
    todo_ids = Enum.map(todos, &todo_id/1)

    # Find all dependencies that are referenced but not completed
    blocking_ids =
      todos
      |> Enum.flat_map(&todo_dependencies/1)
      |> Enum.uniq()
      |> Enum.filter(&(&1 in todo_ids))

    todos
    |> Enum.filter(&(todo_id(&1) in blocking_ids and todo_status(&1) != :completed))
  end

  defp todo_id(todo), do: Map.get(todo, :id) || Map.get(todo, "id")

  defp todo_dependencies(todo) do
    deps = Map.get(todo, :dependencies) || Map.get(todo, "dependencies") || []
    if is_list(deps), do: deps, else: []
  end

  defp todo_priority(todo) do
    case Map.get(todo, :priority) || Map.get(todo, "priority") do
      :high -> :high
      :medium -> :medium
      :low -> :low
      "high" -> :high
      "medium" -> :medium
      "low" -> :low
      _ -> :low
    end
  end

  defp todo_status(todo) do
    case Map.get(todo, :status) || Map.get(todo, "status") do
      :pending -> :pending
      :in_progress -> :in_progress
      :completed -> :completed
      :blocked -> :blocked
      "pending" -> :pending
      "in_progress" -> :in_progress
      "completed" -> :completed
      "blocked" -> :blocked
      _ -> :pending
    end
  end

  defp todo_completed_at(todo), do: Map.get(todo, :completed_at) || Map.get(todo, "completed_at")

  defp put_todo_value(todo, atom_key, atom_value, string_value) do
    todo
    |> maybe_put(atom_key, atom_value)
    |> maybe_put(Atom.to_string(atom_key), string_value)
  end

  defp maybe_put(todo, key, value) do
    if Map.has_key?(todo, key), do: Map.put(todo, key, value), else: todo
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
