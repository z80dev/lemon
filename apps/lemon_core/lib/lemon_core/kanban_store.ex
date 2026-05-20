defmodule LemonCore.KanbanStore do
  @moduledoc """
  Durable BEAM-native kanban board state for multi-agent work.
  """

  require Logger

  alias LemonCore.{Bus, Event, Introspection, Store}

  @boards_table :kanban_boards
  @tasks_table :kanban_tasks
  @default_columns ~w(todo doing review done)
  @board_statuses ~w(active archived)

  @spec create_board(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_board(name, opts \\ []) when is_binary(name) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:error, :empty_name}

      true ->
        now = now_ms()
        columns = normalize_columns(opts[:columns])

        board = %{
          id: board_id(),
          name: name,
          status: "active",
          workspace: string_opt(opts[:workspace]),
          owner: string_opt(opts[:owner]),
          columns: columns,
          created_at_ms: now,
          updated_at_ms: now,
          archived_at_ms: nil,
          meta: normalize_meta(opts[:meta])
        }

        with :ok <- Store.put(@boards_table, board.id, board) do
          emit(:kanban_board_created, board, nil, opts)
          {:ok, board}
        end
    end
  end

  @spec get_board(binary()) :: map()
  def get_board(board_id) when is_binary(board_id) do
    case Store.get(@boards_table, board_id) do
      nil -> %{}
      board when is_map(board) -> normalize_board(board)
      _ -> %{}
    end
  end

  @spec list_boards(keyword()) :: [map()]
  def list_boards(opts \\ []) do
    status = opts[:status] && to_string(opts[:status])
    owner = opts[:owner] && to_string(opts[:owner])
    workspace = opts[:workspace] && to_string(opts[:workspace])
    limit = positive_limit(opts[:limit], 50)

    @boards_table
    |> Store.list()
    |> Enum.map(fn {_key, board} -> normalize_board(board) end)
    |> Enum.reject(&(&1 == %{}))
    |> maybe_filter(:status, status)
    |> maybe_filter(:owner, owner)
    |> maybe_filter(:workspace, workspace)
    |> Enum.sort_by(&(&1.updated_at_ms || 0), :desc)
    |> Enum.take(limit)
  end

  @spec archive_board(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def archive_board(board_id, opts \\ []) when is_binary(board_id) do
    case get_board(board_id) do
      %{} = board when map_size(board) == 0 ->
        {:error, :not_found}

      board ->
        now = now_ms()

        updated =
          board
          |> Map.put(:status, "archived")
          |> Map.put(:updated_at_ms, now)
          |> Map.put(:archived_at_ms, now)

        with :ok <- Store.put(@boards_table, board.id, updated) do
          emit(:kanban_board_archived, updated, nil, opts)
          {:ok, updated}
        end
    end
  end

  @spec create_task(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_task(board_id, title, opts \\ []) when is_binary(board_id) and is_binary(title) do
    title = String.trim(title)

    with {:ok, board} <- fetch_board(board_id),
         :ok <- validate_title(title),
         {:ok, status} <- normalize_task_status(opts[:status], board.columns) do
      now = now_ms()

      task = %{
        id: task_id(),
        board_id: board.id,
        title: title,
        description: string_opt(opts[:description]),
        status: status,
        priority: string_opt(opts[:priority]) || "normal",
        assignee: string_opt(opts[:assignee]),
        worker_profile: string_opt(opts[:worker_profile]),
        session_key: string_opt(opts[:session_key]),
        run_id: string_opt(opts[:run_id]),
        depends_on: normalize_string_list(opts[:depends_on]),
        comments: [],
        created_at_ms: now,
        updated_at_ms: now,
        completed_at_ms: completed_at(status, now),
        meta: normalize_meta(opts[:meta])
      }

      with :ok <- Store.put(@tasks_table, task.id, task) do
        emit(:kanban_task_created, board, task, opts)
        {:ok, task}
      end
    end
  end

  @spec get_task(binary()) :: map()
  def get_task(task_id) when is_binary(task_id) do
    case Store.get(@tasks_table, task_id) do
      nil -> %{}
      task when is_map(task) -> normalize_task(task)
      _ -> %{}
    end
  end

  @spec list_tasks(binary(), keyword()) :: [map()]
  def list_tasks(board_id, opts \\ []) when is_binary(board_id) do
    status = opts[:status] && to_string(opts[:status])
    assignee = opts[:assignee] && to_string(opts[:assignee])
    limit = positive_limit(opts[:limit], 100)

    @tasks_table
    |> Store.list()
    |> Enum.map(fn {_key, task} -> normalize_task(task) end)
    |> Enum.reject(&(&1 == %{}))
    |> Enum.filter(&(&1.board_id == board_id))
    |> maybe_filter(:status, status)
    |> maybe_filter(:assignee, assignee)
    |> Enum.sort_by(&(&1.updated_at_ms || 0), :desc)
    |> Enum.take(limit)
  end

  @spec update_task(binary(), keyword() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_task(task_id, attrs, opts \\ []) when is_binary(task_id) do
    case get_task(task_id) do
      %{} = task when map_size(task) == 0 ->
        {:error, :not_found}

      task ->
        with {:ok, board} <- fetch_board(task.board_id),
             {:ok, updated} <- apply_task_attrs(task, board, attrs) do
          updated =
            updated
            |> Map.put(:updated_at_ms, now_ms())
            |> Map.put(:completed_at_ms, completed_at(updated.status, updated.completed_at_ms))

          with :ok <- Store.put(@tasks_table, task.id, updated) do
            emit(:kanban_task_updated, board, updated, opts)
            {:ok, updated}
          end
        end
    end
  end

  @spec add_comment(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_comment(task_id, body, opts \\ []) when is_binary(task_id) and is_binary(body) do
    body = String.trim(body)

    cond do
      body == "" ->
        {:error, :empty_comment}

      true ->
        case get_task(task_id) do
          %{} = task when map_size(task) == 0 ->
            {:error, :not_found}

          task ->
            with {:ok, board} <- fetch_board(task.board_id) do
              now = now_ms()

              comment = %{
                "id" => comment_id(),
                "author" => string_opt(opts[:author]),
                "body" => body,
                "createdAtMs" => now
              }

              updated =
                task
                |> Map.put(:comments, task.comments ++ [comment])
                |> Map.put(:updated_at_ms, now)

              with :ok <- Store.put(@tasks_table, task.id, updated) do
                emit(:kanban_task_commented, board, updated, opts)
                {:ok, updated}
              end
            end
        end
    end
  end

  @spec lease_task(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def lease_task(board_id, worker_id, opts \\ [])
      when is_binary(board_id) and is_binary(worker_id) do
    with {:ok, board} <- fetch_board(board_id) do
      from_status = string_opt(opts[:from_status]) || List.first(board.columns) || "todo"
      to_status = lease_status(board.columns)
      lease_ms = positive_limit(opts[:lease_ms], 300_000)

      case next_available_task(board, from_status) do
        nil ->
          {:error, :no_available_task}

        task ->
          now = now_ms()

          lease = %{
            "id" => lease_id(),
            "workerId" => worker_id,
            "leasedAtMs" => now,
            "expiresAtMs" => now + lease_ms,
            "attempt" => lease_attempt(task) + 1
          }

          updated =
            task
            |> Map.put(:status, to_status)
            |> Map.put(:assignee, task.assignee || worker_id)
            |> Map.put(:worker_profile, string_opt(opts[:worker_profile]) || task.worker_profile)
            |> Map.put(:updated_at_ms, now)
            |> Map.put(:meta, task.meta |> normalize_meta() |> Map.put("kanbanLease", lease))

          with :ok <- Store.put(@tasks_table, task.id, updated) do
            emit(:kanban_task_leased, board, updated, opts)
            {:ok, updated}
          end
      end
    end
  end

  @spec complete_task(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete_task(task_id, opts \\ []) when is_binary(task_id) do
    case get_task(task_id) do
      %{} = task when map_size(task) == 0 ->
        {:error, :not_found}

      task ->
        with {:ok, board} <- fetch_board(task.board_id) do
          now = now_ms()

          updated =
            task
            |> Map.put(:status, "done")
            |> Map.put(:run_id, string_opt(opts[:run_id]) || task.run_id)
            |> Map.put(:updated_at_ms, now)
            |> Map.put(:completed_at_ms, now)
            |> Map.put(:meta, clear_lease(task.meta))

          with :ok <- Store.put(@tasks_table, task.id, updated) do
            emit(:kanban_task_completed, board, updated, opts)
            {:ok, updated}
          end
        end
    end
  end

  @spec fail_task(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def fail_task(task_id, reason, opts \\ []) when is_binary(task_id) and is_binary(reason) do
    case get_task(task_id) do
      %{} = task when map_size(task) == 0 ->
        {:error, :not_found}

      task ->
        with {:ok, board} <- fetch_board(task.board_id) do
          now = now_ms()
          status = if "blocked" in board.columns, do: "blocked", else: List.first(board.columns)

          failure = %{
            "reason" => String.trim(reason),
            "workerId" => string_opt(opts[:worker_id]),
            "atMs" => now
          }

          updated =
            task
            |> Map.put(:status, status || "todo")
            |> Map.put(:updated_at_ms, now)
            |> Map.put(:completed_at_ms, nil)
            |> Map.put(:meta, task.meta |> clear_lease() |> Map.put("lastFailure", failure))

          with :ok <- Store.put(@tasks_table, task.id, updated) do
            emit(:kanban_task_failed, board, updated, opts)
            {:ok, updated}
          end
        end
    end
  end

  @spec reclaim_expired_leases(binary(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def reclaim_expired_leases(board_id, opts \\ []) when is_binary(board_id) do
    with {:ok, board} <- fetch_board(board_id) do
      now = now_ms()
      target_status = string_opt(opts[:to_status]) || List.first(board.columns) || "todo"

      reclaimed =
        board_id
        |> list_tasks(limit: 10_000)
        |> Enum.filter(&expired_lease?(&1, now))
        |> Enum.map(fn task ->
          updated =
            task
            |> Map.put(:status, target_status)
            |> Map.put(:updated_at_ms, now)
            |> Map.put(:meta, clear_lease(task.meta))

          :ok = Store.put(@tasks_table, task.id, updated)
          emit(:kanban_task_reclaimed, board, updated, opts)
          updated
        end)

      {:ok, reclaimed}
    end
  end

  @spec clear_board(binary(), keyword()) :: :ok | {:error, term()}
  def clear_board(board_id, opts \\ []) when is_binary(board_id) do
    board = get_board(board_id)

    list_tasks(board_id, limit: 10_000)
    |> Enum.each(fn task -> Store.delete(@tasks_table, task.id) end)

    with :ok <- Store.delete(@boards_table, board_id) do
      if board != %{} do
        emit(:kanban_board_cleared, board, nil, opts)
      end

      :ok
    end
  end

  @spec diagnostics(keyword()) :: map()
  def diagnostics(opts \\ []) do
    boards = list_boards(limit: opts[:limit] || 20)
    board_ids = MapSet.new(Enum.map(boards, & &1.id))

    tasks =
      @tasks_table
      |> Store.list()
      |> Enum.map(fn {_key, task} -> normalize_task(task) end)
      |> Enum.reject(&(&1 == %{}))
      |> Enum.filter(&MapSet.member?(board_ids, &1.board_id))

    %{
      board_count: length(boards),
      active_board_count: Enum.count(boards, &(&1.status == "active")),
      archived_board_count: Enum.count(boards, &(&1.status == "archived")),
      task_count: length(tasks),
      open_task_count: Enum.count(tasks, &(&1.status != "done")),
      recent_boards:
        Enum.map(boards, fn board ->
          board_tasks = Enum.filter(tasks, &(&1.board_id == board.id))

          %{
            board_id: board.id,
            status: board.status,
            workspace_hash: hash_value(board.workspace),
            owner: board.owner,
            name_bytes: byte_size(board.name || ""),
            columns: board.columns,
            task_count: length(board_tasks),
            updated_at_ms: board.updated_at_ms
          }
        end),
      cleanup: %{
        includes_titles: false,
        includes_descriptions: false,
        includes_comments: false,
        includes_raw_session_ids: false
      }
    }
  end

  defp fetch_board(board_id) do
    case get_board(board_id) do
      %{} = board when map_size(board) == 0 -> {:error, :board_not_found}
      board -> {:ok, board}
    end
  end

  defp validate_title(""), do: {:error, :empty_title}
  defp validate_title(_title), do: :ok

  defp next_available_task(board, from_status) do
    completed = completed_task_ids(board.id)

    board.id
    |> list_tasks(status: from_status, limit: 10_000)
    |> Enum.sort_by(&(&1.created_at_ms || 0), :asc)
    |> Enum.find(fn task ->
      is_nil(active_lease(task)) and Enum.all?(task.depends_on, &MapSet.member?(completed, &1))
    end)
  end

  defp completed_task_ids(board_id) do
    board_id
    |> list_tasks(status: "done", limit: 10_000)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp apply_task_attrs(task, board, attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    with {:ok, status} <- maybe_status(attrs, task.status, board.columns),
         {:ok, title} <- maybe_title(attrs, task.title) do
      {:ok,
       task
       |> Map.put(:title, title)
       |> maybe_put(:description, attr(attrs, :description))
       |> Map.put(:status, status)
       |> maybe_put(:priority, attr(attrs, :priority))
       |> maybe_put(:assignee, attr(attrs, :assignee))
       |> maybe_put(:worker_profile, attr(attrs, :worker_profile) || attr(attrs, :workerProfile))
       |> maybe_put(:session_key, attr(attrs, :session_key) || attr(attrs, :sessionKey))
       |> maybe_put(:run_id, attr(attrs, :run_id) || attr(attrs, :runId))
       |> maybe_put_list(:depends_on, attr(attrs, :depends_on) || attr(attrs, :dependsOn))
       |> maybe_put_meta(attr(attrs, :meta))}
    end
  end

  defp apply_task_attrs(_task, _board, _attrs), do: {:error, :invalid_attrs}

  defp maybe_title(attrs, existing) do
    case attr(attrs, :title) do
      nil ->
        {:ok, existing}

      value ->
        title = String.trim(to_string(value))
        if title == "", do: {:error, :empty_title}, else: {:ok, title}
    end
  end

  defp maybe_status(attrs, existing, columns) do
    case attr(attrs, :status) do
      nil -> {:ok, existing}
      status -> normalize_task_status(status, columns)
    end
  end

  defp normalize_task_status(nil, [first | _]), do: {:ok, first}
  defp normalize_task_status(nil, []), do: {:ok, "todo"}

  defp normalize_task_status(status, columns) do
    status = String.trim(to_string(status))

    if status in columns do
      {:ok, status}
    else
      {:error, :invalid_status}
    end
  end

  defp normalize_board(board) when is_map(board) do
    %{
      id: field(board, :id),
      name: field(board, :name),
      status: normalize_board_status(field(board, :status)),
      workspace: field(board, :workspace),
      owner: field(board, :owner),
      columns: normalize_columns(field(board, :columns)),
      created_at_ms: field(board, :created_at_ms),
      updated_at_ms: field(board, :updated_at_ms),
      archived_at_ms: field(board, :archived_at_ms),
      meta: normalize_meta(field(board, :meta))
    }
  end

  defp normalize_board(_), do: %{}

  defp normalize_task(task) when is_map(task) do
    %{
      id: field(task, :id),
      board_id: field(task, :board_id),
      title: field(task, :title),
      description: field(task, :description),
      status: field(task, :status) || "todo",
      priority: field(task, :priority) || "normal",
      assignee: field(task, :assignee),
      worker_profile: field(task, :worker_profile),
      session_key: field(task, :session_key),
      run_id: field(task, :run_id),
      depends_on: normalize_string_list(field(task, :depends_on)),
      comments: normalize_comments(field(task, :comments)),
      created_at_ms: field(task, :created_at_ms),
      updated_at_ms: field(task, :updated_at_ms),
      completed_at_ms: field(task, :completed_at_ms),
      meta: normalize_meta(field(task, :meta))
    }
  end

  defp normalize_task(_), do: %{}

  defp normalize_board_status(status) do
    status = to_string(status || "active")
    if status in @board_statuses, do: status, else: "active"
  end

  defp normalize_columns(columns) when is_list(columns) do
    columns
    |> Enum.map(&String.trim(to_string(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> case do
      [] -> @default_columns
      values -> values
    end
  end

  defp normalize_columns(_), do: @default_columns

  defp normalize_comments(comments) when is_list(comments) do
    Enum.map(comments, fn
      %{} = comment ->
        %{
          "id" => field(comment, :id),
          "author" => field(comment, :author),
          "body" => field(comment, :body),
          "createdAtMs" => field(comment, :createdAtMs) || field(comment, :created_at_ms)
        }

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_comments(_), do: []

  defp normalize_string_list(value) when is_list(value) do
    value
    |> Enum.map(&string_opt/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(_), do: []

  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_), do: %{}

  defp lease_status(columns),
    do: if("doing" in columns, do: "doing", else: List.first(columns) || "todo")

  defp active_lease(task) do
    case task.meta["kanbanLease"] || task.meta[:kanbanLease] do
      %{} = lease -> lease
      _ -> nil
    end
  end

  defp lease_attempt(task) do
    case active_lease(task) do
      %{} = lease -> lease["attempt"] || lease[:attempt] || 0
      _ -> 0
    end
  end

  defp clear_lease(meta) do
    meta
    |> normalize_meta()
    |> Map.delete("kanbanLease")
    |> Map.delete(:kanbanLease)
  end

  defp expired_lease?(task, now) do
    case active_lease(task) do
      %{} = lease -> is_integer(lease["expiresAtMs"]) and lease["expiresAtMs"] <= now
      _ -> false
    end
  end

  defp maybe_filter(items, _field, nil), do: items
  defp maybe_filter(items, _field, ""), do: items
  defp maybe_filter(items, field, value), do: Enum.filter(items, &(Map.get(&1, field) == value))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, string_opt(value))

  defp maybe_put_list(map, _key, nil), do: map
  defp maybe_put_list(map, key, value), do: Map.put(map, key, normalize_string_list(value))

  defp maybe_put_meta(map, nil), do: map
  defp maybe_put_meta(map, meta), do: Map.put(map, :meta, normalize_meta(meta))

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) ||
      Map.get(attrs, lower_camel_key(key))
  end

  defp lower_camel_key(key) do
    key
    |> Atom.to_string()
    |> Macro.camelize()
    |> then(fn <<first::binary-size(1), rest::binary>> -> String.downcase(first) <> rest end)
  end

  defp completed_at("done", nil), do: now_ms()
  defp completed_at("done", value), do: value
  defp completed_at(_status, _value), do: nil

  defp positive_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value, default), do: default

  defp emit(event_type, board, task, opts) do
    payload = %{
      board_id: board.id,
      task_id: task && task.id,
      status: (task && task.status) || board.status,
      owner: board.owner,
      assignee: task && task.assignee,
      title_bytes: task && byte_size(task.title || ""),
      name_bytes: byte_size(board.name || ""),
      comment_count: task && length(task.comments || [])
    }

    _ =
      Introspection.record(event_type, payload,
        run_id: (task && task.run_id) || string_opt(opts[:run_id]),
        session_key: task && task.session_key,
        agent_id: (task && task.assignee) || board.owner,
        engine: "lemon",
        provenance: :direct
      )

    if Process.whereis(LemonCore.PubSub) do
      event = Event.new(event_type, payload, %{board_id: board.id, task_id: task && task.id})
      Bus.broadcast("kanban", event)
      Bus.broadcast("kanban:#{board.id}", event)
    end

    :ok
  rescue
    error ->
      Logger.debug("Failed to emit kanban event #{event_type}: #{Exception.message(error)}")
      :ok
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp string_opt(nil), do: nil

  defp string_opt(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_opt(value) when is_atom(value), do: Atom.to_string(value)
  defp string_opt(value) when is_integer(value), do: Integer.to_string(value)
  defp string_opt(_), do: nil

  defp board_id, do: "board_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  defp task_id, do: "task_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  defp comment_id, do: "comment_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  defp lease_id, do: "lease_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  defp now_ms, do: System.system_time(:millisecond)

  defp hash_value(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp hash_value(_), do: nil
end
