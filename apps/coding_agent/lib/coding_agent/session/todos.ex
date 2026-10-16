defmodule CodingAgent.Session.Todos do
  @moduledoc """
  Branch-derived session todo list, journaled in the session history.

  Every successful todo write appends one `"lemon.todo"` custom entry holding
  the complete normalized list, in order, with canonical IDs, statuses,
  priorities, dependencies and any other supplied fields:

      %{"version" => 1, "todos" => [%{"id" => "...", "content" => "...", ...}]}

  The selected branch's list is the nearest such entry on its parent chain, so
  rewind, tree navigation, durable resume and forks (which copy the selected
  branch) all see exactly the list that branch last wrote. Only the owning
  `CodingAgent.Session` process appends entries; the result is reported as
  successful only after the entry is in the journal.

  Writes carry the revision they were prepared against: the session's branch
  generation (advanced on every branch selection) and the governing entry ID.
  A write prepared against another revision is rejected, so a late result from
  an abandoned branch or superseded list cannot overwrite the current one.

  `CodingAgent.Tools.TodoStore` (ETS) holds a projection of the selected
  branch for out-of-session readers. It is rewritten on every read, write and
  branch selection and is never consulted here, so losing it loses nothing.

  ## Compatibility

  * Branches without journal entries (sessions written before the journal)
    use the latest successful todo *write* tool result recorded on that branch
    (`todowrite`, or `todo` with `action: "write"`), whose result details
    carried the complete list. Read/progress results are not evidence: the old
    session-global store could leak another branch's list into them. Without
    such a result the list is empty. Checkpoints and the cache are never
    imported, and old files are not rewritten.
  * An entry with an unsupported version (or an unreadable version 1 entry)
    governs its branch but cannot be read: reads fail instead of falling back
    to older state, and a complete write replaces it non-destructively.
    Branch projections report `:todos_unavailable` until a readable list is
    selected or written; unreadable truth never emits an empty-plan clear.
  """

  alias CodingAgent.SessionManager
  alias CodingAgent.Session.Notifier
  alias CodingAgent.SessionManager.SessionEntry
  alias CodingAgent.Tools.TodoStore

  @entry_type "lemon.todo"
  @version 1

  @type revision :: {non_neg_integer(), String.t() | nil}
  @type read_result ::
          {:ok, [map()], revision()} | {:error, {:unsupported_todo_entry, term()}, revision()}

  @doc "Materialize the selected branch's list and refresh its cache projection."
  @spec read(map()) :: read_result()
  def read(state) do
    {result, head} = materialize(state.session_manager)
    project(state, result)

    case result do
      {:ok, todos} -> {:ok, todos, revision(state, head)}
      {:error, reason} -> {:error, reason, revision(state, head)}
    end
  end

  @doc """
  Journal `todos` as the selected branch's complete list.

  Fails with `:stale_revision` when `expected` no longer matches the selected
  branch, or `:journal_write_failed` when the entry could not be persisted;
  in both cases neither the journal nor the cache changes.
  """
  @spec write(map(), [map()], revision()) ::
          {:ok, [map()], revision(), map()} | {:error, :stale_revision | :journal_write_failed}
  def write(state, todos, expected) when is_list(todos) do
    {_result, head} = materialize(state.session_manager)

    if expected == revision(state, head) do
      todos = TodoStore.normalize(todos)
      entry = SessionEntry.custom(@entry_type, %{"version" => @version, "todos" => todos})

      try do
        SessionManager.append_entry(state.session_manager, entry)
      rescue
        File.Error -> {:error, :journal_write_failed}
      else
        manager ->
          state = %{state | session_manager: manager}
          project(state, {:ok, todos})
          state = notify_change(state, {:ok, todos})
          {:ok, todos, revision(state, manager.leaf_id), state}
      end
    else
      {:error, :stale_revision}
    end
  end

  @doc "Refresh the cache projection after the selected branch changed."
  @spec sync(map()) :: map()
  def sync(state) do
    {result, _head} = materialize(state.session_manager)
    project(state, result)
    notify_change(state, result)
  end

  defp notify_change(state, result) do
    if state.todo_projection != result do
      # An unreadable branch is not an empty plan. Consumers retain their last
      # known projection as unavailable until the journal yields a readable list.
      event =
        case result do
          {:ok, todos} -> {:todos_changed, todos}
          {:error, _} -> {:todos_unavailable, :unsupported_todo_entry}
        end

      Notifier.broadcast_event(state, event)
    end

    %{state | todo_projection: result}
  end

  @doc """
  The list governing the selected branch and the ID of its journal entry
  (`nil` for legacy or empty branches).
  """
  @spec materialize(SessionManager.Session.t()) ::
          {{:ok, [map()]} | {:error, {:unsupported_todo_entry, term()}}, String.t() | nil}
  def materialize(session_manager) do
    case SessionManager.latest_custom_entry(session_manager, @entry_type) do
      %SessionEntry{id: id, data: %{"version" => @version, "todos" => todos}} = entry
      when is_list(todos) ->
        if readable?(todos),
          do: {{:ok, todos}, id},
          else: {{:error, {:unsupported_todo_entry, version(entry)}}, id}

      %SessionEntry{id: id} = entry ->
        {{:error, {:unsupported_todo_entry, version(entry)}}, id}

      nil ->
        {{:ok, legacy(session_manager)}, nil}
    end
  end

  defp version(%SessionEntry{data: %{"version" => version}}), do: version
  defp version(_entry), do: nil

  defp readable?(todos) do
    ids = Enum.map(todos, fn todo -> if is_map(todo), do: todo["id"] end)

    Enum.all?(todos, fn
      %{"id" => id, "content" => content, "status" => status, "priority" => priority}
      when is_binary(id) and is_binary(content) ->
        String.trim(id) != "" and String.trim(content) != "" and
          status in ["pending", "in_progress", "completed", "blocked", "abandoned"] and
          priority in ["high", "medium", "low"]

      _ ->
        false
    end) and Enum.uniq(ids) == ids
  end

  defp revision(state, head), do: {state.branch_generation || 0, head}

  defp project(state, {:ok, todos}), do: TodoStore.put(state.session_manager.header.id, todos)
  defp project(state, {:error, _}), do: TodoStore.delete(state.session_manager.header.id)

  # ── Legacy evidence ──────────────────────────────────────────────────────

  defp legacy(session_manager) do
    {_calls, todos} =
      session_manager
      |> SessionManager.get_branch()
      |> Enum.reduce({%{}, []}, fn
        %SessionEntry{type: :message, message: message}, acc when is_map(message) ->
          legacy_message(message, acc)

        _entry, acc ->
          acc
      end)

    todos
  end

  defp legacy_message(%{"role" => "assistant", "content" => content}, {calls, todos})
       when is_list(content) do
    calls =
      for %{"type" => "tool_call", "id" => id} = call <- content, into: calls do
        {id, call}
      end

    {calls, todos}
  end

  defp legacy_message(%{"role" => "tool_result"} = result, {calls, todos}) do
    call = Map.get(calls, result["tool_call_id"], %{})

    if legacy_write?(result["tool_name"], call["arguments"]) and result["is_error"] != true do
      {calls, legacy_todos(result["details"])}
    else
      {calls, todos}
    end
  end

  defp legacy_message(_message, acc), do: acc

  defp legacy_write?("todowrite", _arguments), do: true
  defp legacy_write?("todo", %{"action" => "write"}), do: true
  defp legacy_write?(_name, _arguments), do: false

  # A write result that does not carry a readable complete list is not
  # evidence of any list; it must not resurrect an older write.
  defp legacy_todos(details) when is_map(details) do
    todos = Map.get(details, :todos) || Map.get(details, "todos")

    if is_list(todos) and Enum.all?(todos, &legacy_todo?/1),
      do: Enum.map(todos, &stringify_keys/1),
      else: []
  end

  defp legacy_todos(_details), do: []

  defp legacy_todo?(todo) when is_map(todo) do
    todo = stringify_keys(todo)
    is_binary(todo["id"]) and is_binary(todo["content"])
  end

  defp legacy_todo?(_todo), do: false

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
