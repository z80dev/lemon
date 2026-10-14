defmodule CodingAgent.Tools.TodoStore do
  @moduledoc """
  ETS projection of each session's selected-branch todo list, plus pure list
  views (progress, actionable, plan projection).

  The authoritative list is journaled in the session history and materialized
  by `CodingAgent.Session.Todos`; the owning session rewrites this projection
  on every todo read, write and branch selection. It serves out-of-session
  readers (progress snapshots, control-plane summaries, checkpoint creation).
  Session reads never consult it, so clearing it or restarting its owner loses
  nothing, and `put/2` cannot change what a session or its tools read.

  ## Usage

      todos = CodingAgent.Tools.TodoStore.get("session-123")
      stats = CodingAgent.Tools.TodoStore.progress(todos)
      next = CodingAgent.Tools.TodoStore.actionable(todos)

  `result_details/1` projects a complete list to string-keyed `todos` and an
  ordered `plan.entries` list of atom-keyed maps with string content/status/priority.
  The plan supports pending, in_progress and completed; an internally blocked
  todo remains blocked in `todos` but projects as pending in the plan.
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
  Returns complete normalized todo state and its ACP/TUI plan projection.

  Pass the entire stored list, not a filtered actionable subset. Extra todo
  fields (including dependencies) are retained; plan entries contain only
  content, status and priority and never omit completed tasks.
  """
  @spec result_details(list(map())) :: %{todos: list(map()), plan: %{entries: list(map())}}
  def result_details(todos) do
    todos =
      Enum.map(todos, fn todo ->
        todo
        |> Map.new(fn {key, value} ->
          {if(is_atom(key), do: Atom.to_string(key), else: key), value}
        end)
        |> Map.put("status", Atom.to_string(todo_status(todo)))
        |> Map.put("priority", Atom.to_string(todo_priority(todo)))
      end)

    entries =
      Enum.map(todos, fn todo ->
        %{
          content: Map.get(todo, "content", ""),
          status: if(todo["status"] == "blocked", do: "pending", else: todo["status"]),
          priority: todo["priority"]
        }
      end)

    %{todos: todos, plan: %{entries: entries}}
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
  Actionable todos from the session's projected list. See `actionable/1`.
  """
  @spec get_actionable(String.t()) :: [todo_item()]
  def get_actionable(session_id) when is_binary(session_id),
    do: session_id |> get() |> actionable()

  @doc """
  Actionable todos - pending or in-progress todos whose dependencies are all
  completed - sorted by priority (high -> medium -> low).
  """
  @spec actionable(list(map())) :: [todo_item()]
  def actionable(todos) when is_list(todos) do
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
  Progress statistics for the session's projected list. See `progress/1`.
  """
  @spec get_progress(String.t()) :: progress_stats()
  def get_progress(session_id) when is_binary(session_id),
    do: session_id |> get() |> progress()

  @doc """
  Status counts and completion percentage for a todo list.

  ## Examples

      iex> TodoStore.progress([%{"status" => "completed"}, %{"status" => "pending"}])
      %{total: 2, completed: 1, in_progress: 0, blocked: 0, pending: 1, percentage: 50}
  """
  @spec progress(list(map())) :: progress_stats()
  def progress(todos) when is_list(todos) do
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
