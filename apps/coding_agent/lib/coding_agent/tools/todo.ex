defmodule CodingAgent.Tools.Todo do
  @moduledoc """
  Session-scoped plan management with read, write, progress and actionable views.

  `write` replaces the full list (including clearing it with `todos: []`), not
  patch it. Entries require only `content`; omitted `status` and `priority`
  default to `"pending"` and `"medium"`, while explicitly supplied values must be
  valid. IDs are optional: an omitted ID reuses an unclaimed ID from the previous
  same-content entry, or gets a deterministic content-based ID; repeated content
  receives distinct IDs in list order. Supply the returned ID when renaming a
  task to preserve its identity. Duplicate explicit IDs reject the entire write.
  `read`, `progress`, and `actionable` are getters, not updates: passing `todos`
  to them is rejected with guidance to use `write`. Rejected writes leave the
  stored plan unchanged.

  State is the owning session's selected-branch journal (`CodingAgent.Session.Todos`),
  so every view agrees with rewind, branch navigation, resume and forks. A write
  succeeds only once its journal entry is recorded, and is rejected if the
  session switched branches or the list changed after this write read it.

  Every successful operation includes the complete normalized state in
  `details.todos` and `details.plan.entries`, even when text content is a progress
  summary or actionable subset. Plan entries are ordered maps with `content`,
  `status` (pending/in_progress/completed/blocked/abandoned), `priority`
  (high/medium/low) and optional `phase`/`blocker` strings. Actionable results
  additionally expose `details.actionable` and full status counts.

  The pure list views (`result_details/1`, `normalize/1`, `actionable/1`,
  `progress/1`) also serve the session journal and control-plane summaries.
  """

  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @valid_actions ["read", "write", "progress", "actionable"]
  @statuses ["pending", "in_progress", "completed", "blocked", "abandoned"]
  @priorities ["high", "medium", "low"]

  @type todo_status :: :pending | :in_progress | :completed | :blocked | :abandoned
  @type todo_priority :: :high | :medium | :low

  @type progress_stats :: %{
          total: non_neg_integer(),
          completed: non_neg_integer(),
          in_progress: non_neg_integer(),
          blocked: non_neg_integer(),
          abandoned: non_neg_integer(),
          pending: non_neg_integer(),
          percentage: non_neg_integer()
        }

  @doc """
  Returns the unified todo tool definition bound to the `:session_pid` option.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session = Keyword.get(opts, :session_pid)

    %AgentTool{
      name: "todo",
      description:
        "Manage the session plan. ONLY action='write' changes tasks or statuses: pass the complete todos list. " <>
          "read, progress, and actionable are read-only getters; omit todos or pass null with them. " <>
          "Write entries need content; omit IDs or pass null for generated IDs, status defaults pending, priority defaults medium. " <>
          "Statuses: pending, in_progress, completed, blocked (optional blocker note), abandoned. Optional phase groups tasks. " <>
          "Only the first in_progress entry remains active after a write. Blocked and abandoned tasks are not actionable. " <>
          "To mark tasks done, use write with status='completed', then progress to inspect counts.",
      label: "Manage Todos",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => @valid_actions,
            "description" =>
              "'write' replaces/updates the complete plan; 'read' reads it; 'progress' gets counts without changing anything; 'actionable' gets ready tasks. Send todos ONLY with write."
          },
          "todos" => todos_schema()
        },
        "required" => ["action"]
      },
      execute: &execute(&1, &2, &3, &4, session)
    }
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          session :: GenServer.server() | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(
        _tool_call_id,
        %{"action" => action, "todos" => todos},
        _signal,
        _on_update,
        _session
      )
      when action in ["read", "progress", "actionable"] and not is_nil(todos) do
    {:error,
     "action='#{action}' is read-only and cannot update todos. Use action='write' with the complete updated list to change statuses; no plan state was changed."}
  end

  def execute(_tool_call_id, params, signal, _on_update, session) do
    action = Map.get(params, "action")

    cond do
      action not in @valid_actions ->
        {:error,
         if(is_nil(action), do: "action is required and must", else: "action must") <>
           " be one of: read, write, progress, actionable"}

      AbortSignal.aborted?(signal) ->
        {:error, "Operation aborted"}

      action == "write" ->
        execute_write(Map.get(params, "todos"), session)

      true ->
        with {:ok, todos} <- readable(session), do: view(action, todos)
    end
  end

  # ── Views ────────────────────────────────────────────────────────────────

  defp view("read", todos) do
    details = result_details(todos)

    %AgentToolResult{
      content: [%TextContent{text: Jason.encode!(details.todos, pretty: true)}],
      details: Map.put(details, :title, "#{open_count(details.todos)} todos")
    }
  end

  defp view("progress", todos) do
    progress = progress(todos)

    %AgentToolResult{
      content: [%TextContent{text: Jason.encode!(progress, pretty: true)}],
      details:
        todos
        |> result_details()
        |> Map.merge(progress)
        |> Map.put(:title, "todo progress")
    }
  end

  defp view("actionable", todos) do
    actionable = actionable(todos)

    %AgentToolResult{
      content: [%TextContent{text: Jason.encode!(actionable, pretty: true)}],
      details:
        todos
        |> result_details()
        |> Map.merge(progress(todos))
        |> Map.put(:title, "#{length(actionable)} actionable todos")
        |> Map.put(:actionable, result_details(actionable).todos)
    }
  end

  defp open_count(todos),
    do: Enum.count(todos, fn todo -> todo["status"] not in ["completed", "abandoned"] end)

  # The selected branch's list as the session materializes it, with the
  # revision a write must be prepared against.
  defp current(nil), do: {:error, "Session not available"}

  defp current(session) do
    case CodingAgent.Session.todos(session) do
      {:ok, todos, revision} -> {:ok, todos, revision}
      {:error, {:unsupported_todo_entry, version}, revision} -> {:unsupported, version, revision}
    end
  catch
    :exit, _ -> {:error, "Session not available"}
  end

  # Read-only views refuse an unreadable list rather than showing other state.
  defp readable(session) do
    case current(session) do
      {:ok, todos, _revision} ->
        {:ok, todos}

      {:unsupported, version, _revision} ->
        {:error,
         "This branch's todo list was saved in an unsupported format (entry version " <>
           "#{inspect(version)}) and cannot be read. Write the complete list to replace it."}

      {:error, _} = error ->
        error
    end
  end

  # ── Write ────────────────────────────────────────────────────────────────

  defp todos_schema do
    %{
      "type" => ["array", "null"],
      "description" =>
        "Complete replacement plan, including completed tasks. Use [] to clear it. IDs are optional.",
      "items" => %{
        "type" => "object",
        "properties" => %{
          "content" => %{"type" => "string", "description" => "Brief description of the task"},
          "status" => %{
            "type" => "string",
            "enum" => @statuses,
            "default" => "pending",
            "description" =>
              "Task status; defaults to pending. Only the first in_progress item stays active."
          },
          "priority" => %{
            "type" => "string",
            "enum" => @priorities,
            "default" => "medium",
            "description" => "Priority; defaults to medium when omitted"
          },
          "id" => %{
            "type" => ["string", "null"],
            "description" =>
              "Stable ID returned by a previous write; omit or pass null for new tasks"
          },
          "phase" => %{"type" => "string", "description" => "Optional phase/group name"},
          "blocker" => %{
            "type" => "string",
            "description" => "Optional explanation of what blocks the task"
          }
        },
        "required" => ["content"]
      }
    }
  end

  defp execute_write(todos, _session) when not is_list(todos),
    do: {:error, "Todos must be an array"}

  defp execute_write(_todos, nil), do: {:error, "Session not available"}

  defp execute_write(todos, session) do
    todos =
      Enum.map(todos, fn
        todo when is_map(todo) ->
          todo = if is_nil(Map.get(todo, "id")), do: Map.delete(todo, "id"), else: todo
          todo |> Map.put_new("status", "pending") |> Map.put_new("priority", "medium")

        todo ->
          todo
      end)

    with :ok <- validate_todos(todos),
         {:ok, prior, revision} <- previous(session),
         {:ok, todos} <- journal(session, assign_ids(todos, prior), revision) do
      %AgentToolResult{
        content: [%TextContent{text: Jason.encode!(todos, pretty: true)}],
        details: Map.put(result_details(todos), :title, "#{open_count(todos)} todos")
      }
    end
  end

  # An unreadable (unsupported) entry is replaced, not merged: IDs start fresh.
  defp previous(session) do
    case current(session) do
      {:ok, todos, revision} -> {:ok, todos, revision}
      {:unsupported, _version, revision} -> {:ok, [], revision}
      {:error, _} = error -> error
    end
  end

  defp journal(session, todos, revision) do
    case CodingAgent.Session.write_todos(session, todos, revision) do
      {:ok, todos, _revision} ->
        {:ok, todos}

      {:error, :stale_revision} ->
        {:error,
         "The todo list changed (the session switched branches or another update was saved) " <>
           "before this write was recorded, so nothing was written. Read the current list " <>
           "and write the complete list again if it still applies."}

      {:error, :journal_write_failed} ->
        {:error,
         "The todo update could not be saved to the session journal; the list is unchanged."}

      {:error, :aborted} ->
        {:error, "The todo update was cancelled before it was recorded; the list is unchanged."}
    end
  catch
    :exit, _ ->
      {:error,
       "The session did not confirm the todo update. Read the list before writing it again."}
  end

  defp validate_todos(todos) do
    with :ok <- validate_entries(todos), do: validate_unique_ids(todos)
  end

  defp validate_entries(todos) do
    Enum.reduce_while(Enum.with_index(todos, 1), :ok, fn
      {todo, idx}, :ok when is_map(todo) ->
        case validate_todo(todo, idx) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end

      {_todo, idx}, :ok ->
        {:halt, {:error, "Todo #{idx} must be an object"}}
    end)
  end

  defp validate_todo(todo, idx) do
    with :ok <- validate_optional_id(todo, idx),
         :ok <- validate_non_empty_string(todo, "content", idx),
         :ok <- validate_status(todo, idx),
         :ok <- validate_priority(todo, idx),
         :ok <- validate_optional_string(todo, "phase", idx) do
      validate_optional_string(todo, "blocker", idx)
    end
  end

  defp validate_optional_id(todo, idx) do
    if Map.has_key?(todo, "id"), do: validate_non_empty_string(todo, "id", idx), else: :ok
  end

  defp validate_optional_string(todo, key, idx) do
    if not Map.has_key?(todo, key) or is_binary(Map.get(todo, key)),
      do: :ok,
      else: {:error, "Todo #{idx} #{key} must be a string"}
  end

  defp validate_non_empty_string(todo, key, idx) do
    case Map.get(todo, key) do
      value when is_binary(value) ->
        if String.trim(value) != "",
          do: :ok,
          else: {:error, "Todo #{idx} #{key} must be a non-empty string"}

      _ ->
        {:error, "Todo #{idx} #{key} must be a non-empty string"}
    end
  end

  defp validate_status(todo, idx) do
    if Map.get(todo, "status") in @statuses,
      do: :ok,
      else:
        {:error,
         "Todo #{idx} status must be pending, in_progress, completed, blocked, or abandoned"}
  end

  defp validate_priority(todo, idx) do
    if Map.get(todo, "priority") in @priorities,
      do: :ok,
      else: {:error, "Todo #{idx} priority must be high, medium, or low"}
  end

  defp validate_unique_ids(todos) do
    ids = for todo <- todos, Map.has_key?(todo, "id"), do: todo["id"]
    if Enum.uniq(ids) == ids, do: :ok, else: {:error, "todo ids must be unique"}
  end

  defp assign_ids(todos, previous) do
    previous_ids =
      previous
      |> Enum.group_by(&(Map.get(&1, "content") || Map.get(&1, :content)))
      |> Map.new(fn {content, entries} ->
        {content, Enum.map(entries, &(Map.get(&1, "id") || Map.get(&1, :id)))}
      end)

    reserved = MapSet.new(for todo <- todos, Map.has_key?(todo, "id"), do: todo["id"])

    {todos, _used} =
      Enum.map_reduce(todos, reserved, fn todo, used ->
        if Map.has_key?(todo, "id") do
          {todo, used}
        else
          id =
            Enum.find(Map.get(previous_ids, todo["content"], []), fn id ->
              is_binary(id) and String.trim(id) != "" and not MapSet.member?(used, id)
            end) || generated_id(todo["content"], used)

          {Map.put(todo, "id", id), MapSet.put(used, id)}
        end
      end)

    todos
  end

  defp generated_id(content, used) do
    base = "todo_" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      index -> "#{base}_#{index}"
    end)
    |> Enum.find(&(not MapSet.member?(used, &1)))
  end

  # ── Pure list views ──────────────────────────────────────────────────────

  @doc """
  Returns complete normalized todo state and its ACP/TUI plan projection.

  Pass the entire list, not a filtered actionable subset. Extra todo fields
  (including dependencies) are retained; plan entries contain content, status,
  priority and any phase/blocker notes, and never omit terminal tasks.
  """
  @spec result_details([map()]) :: %{todos: [map()], plan: %{entries: [map()]}}
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
        entry = %{
          content: Map.get(todo, "content", ""),
          status: todo["status"],
          priority: todo["priority"]
        }

        Enum.reduce([{"phase", :phase}, {"blocker", :blocker}], entry, fn {key, atom}, acc ->
          if Map.has_key?(todo, key), do: Map.put(acc, atom, todo[key]), else: acc
        end)
      end)

    %{todos: todos, plan: %{entries: entries}}
  end

  @doc "Keep the first in-progress item; demote later active items to pending."
  @spec normalize([map()]) :: [map()]
  def normalize(todos) do
    {todos, _active} =
      Enum.map_reduce(todos, false, fn todo, active ->
        cond do
          todo_status(todo) != :in_progress ->
            {todo, active}

          active ->
            key = if Map.has_key?(todo, :status), do: :status, else: "status"
            status = if is_atom(Map.get(todo, key)), do: :pending, else: "pending"
            {Map.put(todo, key, status), true}

          true ->
            {todo, true}
        end
      end)

    todos
  end

  @doc """
  Actionable todos - pending or in-progress todos whose dependencies are all
  completed - sorted by priority (high -> medium -> low).
  """
  @spec actionable([map()]) :: [map()]
  def actionable(todos) when is_list(todos) do
    completed_ids =
      for todo <- todos, todo_status(todo) == :completed, do: todo_id(todo)

    priority_order = %{high: 0, medium: 1, low: 2}

    todos
    |> Enum.filter(fn todo ->
      todo_status(todo) in [:pending, :in_progress] and
        Enum.all?(todo_dependencies(todo), &(&1 in completed_ids))
    end)
    |> Enum.sort_by(&priority_order[todo_priority(&1)])
  end

  @doc """
  Status counts and completion percentage for a todo list.

  ## Examples

      iex> CodingAgent.Tools.Todo.progress([%{"status" => "completed"}, %{"status" => "pending"}])
      %{total: 2, completed: 1, in_progress: 0, blocked: 0, abandoned: 0, pending: 1, percentage: 50}
  """
  @spec progress([map()]) :: progress_stats()
  def progress(todos) when is_list(todos) do
    counts = Enum.frequencies_by(todos, &todo_status/1)
    total = length(todos)
    completed = Map.get(counts, :completed, 0)

    %{
      total: total,
      completed: completed,
      in_progress: Map.get(counts, :in_progress, 0),
      blocked: Map.get(counts, :blocked, 0),
      abandoned: Map.get(counts, :abandoned, 0),
      pending: Map.get(counts, :pending, 0),
      percentage: if(total > 0, do: div(completed * 100, total), else: 0)
    }
  end

  defp todo_id(todo), do: Map.get(todo, :id) || Map.get(todo, "id")

  defp todo_dependencies(todo) do
    deps = Map.get(todo, :dependencies) || Map.get(todo, "dependencies") || []
    if is_list(deps), do: deps, else: []
  end

  defp todo_priority(todo) do
    case Map.get(todo, :priority) || Map.get(todo, "priority") do
      priority when priority in [:high, :medium, :low] -> priority
      "high" -> :high
      "medium" -> :medium
      _ -> :low
    end
  end

  defp todo_status(todo) do
    case Map.get(todo, :status) || Map.get(todo, "status") do
      status when status in [:pending, :in_progress, :completed, :blocked, :abandoned] -> status
      "in_progress" -> :in_progress
      "completed" -> :completed
      "blocked" -> :blocked
      "abandoned" -> :abandoned
      _ -> :pending
    end
  end
end
