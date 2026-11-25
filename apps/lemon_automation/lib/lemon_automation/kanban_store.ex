defmodule LemonAutomation.KanbanStore do
  @moduledoc """
  Durable BEAM-native kanban board state for multi-agent work.

  Router run and session identity (`run_id`, `session_key`) are written only by
  `track_leased_run/4` under the exact card lease; `update_task/3` rejects them,
  rejects `meta`, and refuses any edit while a card is leased or tracking a run.

  Board authority (`LemonAutomation.KanbanAuthority`) is supplied once, by
  a trusted caller, through `create_board/2`'s `:authority` option. Afterwards
  only `restrict_authority/2` (narrowing), `share_board/2` and
  `reauthorize_board/1` (operator surfaces) change it. Card creators and editors
  pass their policy as the trusted `:dispatch_policy` option; it is intersected
  into the card's `meta["dispatchPolicy"]` and never widened. Supplied `meta`
  never carries authority, lease, run, workflow or failure records.
  """

  require Logger

  alias LemonAutomation.KanbanAuthority
  alias LemonCore.{Introspection, Store, ToolPolicy}

  @protected_task_attrs ~w(run_id runId session_key sessionKey meta)
  # Board `codingWorkflow` is creator configuration; on a card it is the
  # controller's lease-guarded checkpoint.
  @reserved_board_meta ~w(kanbanAuthority)
  @reserved_card_meta ~w(kanbanAuthority kanbanRun kanbanLease codingWorkflow dispatchPolicy lastFailure)
  @run_provenance "kanban-dispatcher/v2"

  @boards_table :kanban_boards
  @tasks_table :kanban_tasks
  @default_columns ~w(todo doing review done)
  @board_statuses ~w(active archived)

  @spec create_board(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_board(name, opts \\ []) when is_binary(name) do
    name = String.trim(name)

    with :ok <- if(name == "", do: {:error, :empty_name}, else: :ok),
         {:ok, workspace, meta} <- board_authority(opts) do
      now = now_ms()
      columns = normalize_columns(opts[:columns])

      board = %{
        id: board_id(),
        name: name,
        status: "active",
        workspace: workspace,
        owner: string_opt(opts[:owner]),
        columns: columns,
        created_at_ms: now,
        updated_at_ms: now,
        archived_at_ms: nil,
        meta: meta
      }

      with :ok <- Store.put(@boards_table, board.id, board) do
        emit(:kanban_board_created, board, nil, opts)
        {:ok, board}
      end
    end
  end

  # Authorized boards store the canonical workspace inside the recorded root.
  defp board_authority(opts) do
    meta = new_meta(opts[:meta], @reserved_board_meta)
    workspace = string_opt(opts[:workspace])

    case opts[:authority] do
      nil ->
        {:ok, workspace, meta}

      authority ->
        with {:ok, authority} <- KanbanAuthority.validate(authority),
             {:ok, workspace} <- KanbanAuthority.canonical_directory(workspace || ""),
             true <- KanbanAuthority.within?(workspace, authority["root"]) do
          {:ok, workspace, Map.put(meta, KanbanAuthority.key(), authority)}
        else
          {:error, :kanban_authority_missing} -> {:error, :invalid_kanban_authority}
          _ -> {:error, :workspace_outside_authorized_root}
        end
    end
  end

  @doc "Durably narrows a board's authority with a dispatch starter's policy."
  @spec restrict_authority(binary(), term()) :: {:ok, map()} | {:error, term()}
  def restrict_authority(board_id, policy) when is_binary(board_id),
    do: update_authority(board_id, &KanbanAuthority.restrict(&1, policy))

  @doc "Operator path: share a board with another trusted session."
  @spec share_board(binary(), binary()) :: {:ok, map()} | {:error, term()}
  def share_board(board_id, session_key) when is_binary(board_id),
    do: update_authority(board_id, &KanbanAuthority.share(&1, session_key))

  @doc """
  Operator path: (re)authorize a board with operator authority rooted at its
  current canonical workspace. Publication is never granted here.
  """
  @spec reauthorize_board(binary()) :: {:ok, map()} | {:error, term()}
  def reauthorize_board(board_id) when is_binary(board_id) do
    with_board_lock(board_id, fn ->
      with {:ok, board} <- fetch_board(board_id),
           {:ok, authority} <-
             KanbanAuthority.operator(board.workspace || "", board.meta[KanbanAuthority.key()]) do
        put_board(%{
          board
          | workspace: authority["root"],
            meta: Map.put(board.meta, KanbanAuthority.key(), authority)
        })
      end
    end)
  end

  @doc """
  Operator path: grant publication for the board's exact requested settings
  and the `destinations` (push URLs, PR repository and base) resolved for this
  confirmation. `digest` (`KanbanAuthority.publish_digest/2`) binds it to what
  the operator previewed; any change of settings or destinations refuses with
  `:stale`.
  """
  @spec grant_publication(binary(), binary(), map()) :: {:ok, map()} | {:error, term()}
  def grant_publication(board_id, digest, destinations)
      when is_binary(board_id) and is_binary(digest) do
    update_board_authority(board_id, fn board, authority ->
      settings = get_in(board.meta, ["codingWorkflow", "publish"])

      cond do
        not is_map(settings) -> {:error, :publication_not_requested}
        KanbanAuthority.publish_digest(settings, destinations) != digest -> {:error, :stale}
        true -> KanbanAuthority.grant_publication(authority, settings, destinations)
      end
    end)
  end

  @doc """
  Operator path: allow workers to run in place in the board's workspace
  (needed for non-Git workspaces or worktrees disabled). Refused with
  `:workspace_changed` unless `workspace_digest` (see
  `KanbanAuthority.workspace_digest/1`) still names the board's workspace.
  """
  @spec grant_in_place(binary(), binary()) :: {:ok, map()} | {:error, term()}
  def grant_in_place(board_id, workspace_digest) when is_binary(board_id) do
    update_board_authority(board_id, fn board, authority ->
      if is_binary(workspace_digest) and
           KanbanAuthority.workspace_digest(board.workspace) == workspace_digest,
         do: KanbanAuthority.grant_in_place(authority, board.workspace),
         else: {:error, :workspace_changed}
    end)
  end

  defp update_authority(board_id, fun),
    do: update_board_authority(board_id, fn _board, authority -> fun.(authority) end)

  defp update_board_authority(board_id, fun) do
    with_board_lock(board_id, fn ->
      with {:ok, board} <- fetch_board(board_id),
           {:ok, authority} <- KanbanAuthority.fetch(board),
           {:ok, authority} <- fun.(board, authority) do
        put_board(%{board | meta: Map.put(board.meta, KanbanAuthority.key(), authority)})
      end
    end)
  end

  defp put_board(board) do
    board = %{board | updated_at_ms: now_ms()}

    with :ok <- Store.put(@boards_table, board.id, board) do
      emit(:kanban_board_updated, board, nil, [])
      {:ok, board}
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

  @doc "List boards. `strict: true` returns `{:ok, boards}` or a store error, never false emptiness."
  @spec list_boards(keyword()) :: [map()] | {:ok, [map()]} | {:error, term()}
  def list_boards(opts \\ []) do
    project = fn records ->
      records
      |> Enum.map(fn {_key, board} -> normalize_board(board) end)
      |> Enum.reject(&(&1 == %{}))
      |> maybe_filter(:status, opts[:status] && to_string(opts[:status]))
      |> maybe_filter(:owner, opts[:owner] && to_string(opts[:owner]))
      |> maybe_filter(:workspace, opts[:workspace] && to_string(opts[:workspace]))
      |> Enum.sort_by(&(&1.updated_at_ms || 0), :desc)
      |> Enum.take(positive_limit(opts[:limit], 50))
    end

    list_records(@boards_table, opts, project)
  end

  @doc """
  Archive a board. The read-modify-write runs under the board lock so a
  concurrent authority update (e.g. a starter narrowing it) is never undone.
  """
  @spec archive_board(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def archive_board(board_id, opts \\ []) when is_binary(board_id) do
    with_board_lock(board_id, fn ->
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
    end)
  end

  @spec create_task(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_task(board_id, title, opts \\ []) when is_binary(board_id) and is_binary(title) do
    title = String.trim(title)

    with {:ok, board} <- fetch_board(board_id),
         :ok <- validate_title(title),
         {:ok, status} <- normalize_task_status(opts[:status], board.columns),
         :ok <- workflow_completion_allowed(%{meta: %{}}, board, status),
         {:ok, meta} <-
           restrict_dispatch_policy(
             new_meta(opts[:meta], @reserved_card_meta),
             opts[:dispatch_policy]
           ) do
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
        session_key: nil,
        run_id: nil,
        depends_on: normalize_string_list(opts[:depends_on]),
        comments: [],
        created_at_ms: now,
        updated_at_ms: now,
        completed_at_ms: completed_at(status, now),
        meta: meta
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

  @doc "List cards. `strict: true` preserves backend failure instead of returning an empty board."
  @spec list_tasks(binary(), keyword()) :: [map()] | {:ok, [map()]} | {:error, term()}
  def list_tasks(board_id, opts \\ []) when is_binary(board_id) do
    project = fn records ->
      records
      |> Enum.map(fn {_key, task} -> normalize_task(task) end)
      |> Enum.reject(&(&1 == %{}))
      |> Enum.filter(&(&1.board_id == board_id))
      |> maybe_filter(:status, opts[:status] && to_string(opts[:status]))
      |> maybe_filter(:assignee, opts[:assignee] && to_string(opts[:assignee]))
      |> Enum.sort_by(&(&1.updated_at_ms || 0), :desc)
      |> Enum.take(positive_limit(opts[:limit], 100))
    end

    list_records(@tasks_table, opts, project)
  end

  defp list_records(table, opts, project) do
    if opts[:strict] do
      with {:ok, records} <- Store.fetch_all(table), do: {:ok, project.(records)}
    else
      project.(Store.list(table))
    end
  end

  @doc """
  Update an idle card's editable fields.

  Router identity (`run_id`, `session_key`) and `meta` are never accepted, and
  a card holding a lease or tracking a run cannot be edited: only the exact
  lease owner changes it through the lease-guarded writers.
  """
  @spec update_task(binary(), keyword() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_task(task_id, attrs, opts \\ []) when is_binary(task_id) do
    with_task_board_lock(task_id, fn ->
      case get_task(task_id) do
        %{} = task when map_size(task) == 0 ->
          {:error, :not_found}

        task ->
          with :ok <- editable(task),
               {:ok, board} <- fetch_board(task.board_id),
               {:ok, updated} <- apply_task_attrs(task, board, attrs),
               {:ok, meta} <- restrict_dispatch_policy(updated.meta, opts[:dispatch_policy]) do
            updated =
              updated
              |> Map.put(:meta, meta)
              |> Map.put(:updated_at_ms, now_ms())
              |> Map.put(:completed_at_ms, completed_at(updated.status, updated.completed_at_ms))

            with :ok <- Store.put(@tasks_table, task.id, updated) do
              emit(:kanban_task_updated, board, updated, opts)
              {:ok, updated}
            end
          end
      end
    end)
  end

  defp editable(task) do
    if is_nil(active_lease(task)) and not tracked_run?(task),
      do: :ok,
      else: {:error, :task_leased}
  end

  @spec add_comment(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_comment(task_id, body, opts \\ []) when is_binary(task_id) and is_binary(body) do
    body = String.trim(body)

    cond do
      body == "" ->
        {:error, :empty_comment}

      true ->
        with_task_board_lock(task_id, fn ->
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
        end)
    end
  end

  @spec lease_task(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def lease_task(board_id, worker_id, opts \\ [])
      when is_binary(board_id) and is_binary(worker_id) do
    with_board_lock(board_id, fn ->
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
              |> Map.put(
                :worker_profile,
                string_opt(opts[:worker_profile]) || task.worker_profile
              )
              |> Map.put(:updated_at_ms, now)
              |> Map.put(:meta, task.meta |> normalize_meta() |> Map.put("kanbanLease", lease))

            with :ok <- Store.put(@tasks_table, task.id, updated) do
              emit(:kanban_task_leased, board, updated, opts)
              {:ok, updated}
            end
        end
      end
    end)
  end

  @doc """
  Extend only the exact current lease. The dispatcher calls this while its
  monitored in-VM worker is alive; expiry remains durable for crash recovery.
  Renewal never changes run ownership or makes an ambiguous run retryable.
  """
  @spec renew_task_lease(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def renew_task_lease(task_id, lease_id, opts \\ [])
      when is_binary(task_id) and is_binary(lease_id) do
    with_task_board_lock(task_id, fn ->
      with {:ok, task, _board} <- fetch_task_with_lease(task_id, lease_id) do
        now = Keyword.get(opts, :now_ms, now_ms())
        lease_ms = positive_limit(opts[:lease_ms], 300_000)
        lease = Map.put(active_lease(task), "expiresAtMs", now + lease_ms)
        updated = %{task | meta: Map.put(task.meta, "kanbanLease", lease)}

        with :ok <- Store.put(@tasks_table, task.id, updated), do: {:ok, updated}
      end
    end)
  end

  @spec reclaim_expired_leases(binary(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def reclaim_expired_leases(board_id, opts \\ []) when is_binary(board_id) do
    with_board_lock(board_id, fn ->
      with {:ok, board} <- fetch_board(board_id) do
        now = now_ms()
        target_status = string_opt(opts[:to_status]) || List.first(board.columns) || "todo"

        reclaimed =
          board_id
          |> list_tasks(limit: 10_000)
          |> Enum.filter(&(expired_lease?(&1, now) and not tracked_run?(&1)))
          |> Enum.map(fn task -> reclaim_task_unlocked(task, board, target_status, opts) end)

        {:ok, reclaimed}
      end
    end)
  end

  @doc """
  Reclaim one task only when the caller still owns the supplied lease ID.

  Dispatcher stop/restart paths use this guard so a late result from an old
  worker cannot clear or terminalize a newer worker's lease.
  """
  @spec reclaim_task_lease(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def reclaim_task_lease(task_id, lease_id, opts \\ [])
      when is_binary(task_id) and is_binary(lease_id) do
    with_task_board_lock(task_id, fn ->
      with {:ok, task, board} <- fetch_task_with_lease(task_id, lease_id) do
        target_status = string_opt(opts[:to_status]) || List.first(board.columns) || "todo"
        {:ok, reclaim_task_unlocked(task, board, target_status, opts)}
      end
    end)
  end

  @doc """
  Reclaim every lease owned by a dispatcher worker ID on a board.

  This is the dispatcher restart reconciliation boundary for unexpired leases
  whose former worker task no longer has a live owner.
  """
  @spec reclaim_worker_leases(binary(), binary(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def reclaim_worker_leases(board_id, worker_id, opts \\ [])
      when is_binary(board_id) and is_binary(worker_id) do
    with_board_lock(board_id, fn ->
      with {:ok, board} <- fetch_board(board_id) do
        target_status = string_opt(opts[:to_status]) || List.first(board.columns) || "todo"

        reclaimed =
          board_id
          |> list_tasks(limit: 10_000)
          |> Enum.filter(
            &(lease_worker_id(active_lease(&1)) == worker_id and not tracked_run?(&1))
          )
          |> Enum.map(&reclaim_task_unlocked(&1, board, target_status, opts))

        {:ok, reclaimed}
      end
    end)
  end

  @doc """
  Persist a router invocation before submission, guarded by the exact task lease.
  Tracked invocations are not reclaimed on expiry or dispatcher restart: their
  outcome must be reconciled before another worker can edit the same checkout.

  The run record is bound to the card and lease (`taskId`, `leaseId`,
  `provenance`); only such a record is trusted for session reuse.
  """
  def track_leased_run(task_id, lease_id, run_id, attrs \\ %{}) do
    with_task_board_lock(task_id, fn ->
      with {:ok, task, board} <- fetch_task_with_lease(task_id, lease_id) do
        {workflow, attrs} = attrs |> Map.new() |> Map.pop("codingWorkflow")

        run =
          attrs
          |> Map.put_new("status", "running")
          |> Map.merge(%{
            "runId" => run_id,
            "taskId" => task.id,
            "leaseId" => lease_id,
            "provenance" => @run_provenance
          })

        meta =
          task.meta
          |> Map.put("kanbanRun", run)
          |> put_workflow(workflow)

        updated =
          task
          |> Map.put(:run_id, run_id)
          |> Map.put(:session_key, run["sessionKey"] || task.session_key)
          |> Map.put(:meta, meta)
          |> Map.put(:updated_at_ms, now_ms())

        with :ok <- Store.put(@tasks_table, task.id, updated) do
          emit(:kanban_task_updated, board, updated, [])
          {:ok, updated}
        end
      end
    end)
  end

  @doc "Persist a coding workflow checkpoint under the exact still-owned card lease."
  def checkpoint_leased_workflow(task_id, lease_id, checkpoint) when is_map(checkpoint) do
    with_task_board_lock(task_id, fn ->
      with {:ok, task, board} <- fetch_task_with_lease(task_id, lease_id) do
        checkpoint =
          if get_in(task.meta, ["codingWorkflow", "cancelRequested"]) == true,
            do: Map.put(checkpoint, "cancelRequested", true),
            else: checkpoint

        updated = %{
          task
          | meta: Map.put(task.meta, "codingWorkflow", checkpoint),
            updated_at_ms: now_ms()
        }

        with :ok <- Store.put(@tasks_table, task.id, updated) do
          emit(:kanban_task_updated, board, updated, [])
          {:ok, updated}
        end
      end
    end)
  end

  defp put_workflow(meta, workflow) when is_map(workflow),
    do: Map.put(meta, "codingWorkflow", workflow)

  defp put_workflow(meta, _), do: meta

  @doc """
  Complete a task only if the supplied lease is still authoritative.
  """
  @spec complete_leased_task(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def complete_leased_task(task_id, lease_id, opts \\ []) do
    with_task_board_lock(task_id, fn ->
      with {:ok, task, board} <- fetch_task_with_lease(task_id, lease_id),
           :ok <- workflow_completion_allowed(task, board, "done") do
        complete_task_unlocked(task, board, opts)
      end
    end)
  end

  @doc """
  Fail a task only if the supplied lease is still authoritative.
  """
  @spec fail_leased_task(binary(), binary(), binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def fail_leased_task(task_id, lease_id, reason, opts \\ []) do
    with_task_board_lock(task_id, fn ->
      with {:ok, task, board} <- fetch_task_with_lease(task_id, lease_id) do
        fail_task_unlocked(task, board, reason, opts)
      end
    end)
  end

  defp complete_task_unlocked(task, board, opts) do
    now = now_ms()

    updated =
      task
      |> Map.put(:status, "done")
      |> Map.put(:run_id, string_opt(opts[:run_id]) || task.run_id)
      |> Map.put(:updated_at_ms, now)
      |> Map.put(:completed_at_ms, now)
      |> Map.put(:meta, terminal_meta(task.meta, "completed", opts))

    with :ok <- Store.put(@tasks_table, task.id, updated) do
      emit(:kanban_task_completed, board, updated, opts)
      {:ok, updated}
    end
  end

  defp fail_task_unlocked(task, board, reason, opts) do
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
      |> Map.put(
        :meta,
        terminal_meta(task.meta, "failed", opts) |> Map.put("lastFailure", failure)
      )

    with :ok <- Store.put(@tasks_table, task.id, updated) do
      emit(:kanban_task_failed, board, updated, opts)
      {:ok, updated}
    end
  end

  defp reclaim_task_unlocked(task, board, target_status, opts) do
    updated =
      task
      |> Map.put(:status, target_status)
      |> Map.put(:updated_at_ms, now_ms())
      |> Map.put(:meta, clear_lease(task.meta))

    :ok = Store.put(@tasks_table, task.id, updated)
    emit(:kanban_task_reclaimed, board, updated, opts)
    updated
  end

  defp with_task_board_lock(task_id, fun) do
    case get_task(task_id) do
      %{} = task when map_size(task) == 0 ->
        {:error, :not_found}

      task ->
        with_board_lock(task.board_id, fun)
    end
  end

  defp with_board_lock(board_id, fun) do
    case :global.trans({{__MODULE__, board_id}, self()}, fun, [node()], 3) do
      :aborted -> {:error, :lock_aborted}
      result -> result
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
      is_nil(active_lease(task)) and not Map.has_key?(task.meta, "lastFailure") and
        not tracked_run?(task) and Enum.all?(task.depends_on, &MapSet.member?(completed, &1))
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

    with :ok <- reject_protected_attrs(attrs),
         {:ok, status} <- maybe_status(attrs, task.status, board.columns),
         :ok <- workflow_completion_allowed(task, board, status),
         {:ok, title} <- maybe_title(attrs, task.title) do
      {:ok,
       task
       |> Map.put(:title, title)
       |> maybe_put(:description, attr(attrs, :description))
       |> Map.put(:status, status)
       |> maybe_put(:priority, attr(attrs, :priority))
       |> maybe_put(:assignee, attr(attrs, :assignee))
       |> maybe_put(:worker_profile, attr(attrs, :worker_profile) || attr(attrs, :workerProfile))
       |> maybe_put_list(:depends_on, attr(attrs, :depends_on) || attr(attrs, :dependsOn))
       |> maybe_retry(attr(attrs, :status), List.first(board.columns))}
    end
  end

  defp apply_task_attrs(_task, _board, _attrs), do: {:error, :invalid_attrs}

  defp reject_protected_attrs(attrs) do
    case Enum.find(Map.keys(attrs), &(to_string(&1) in @protected_task_attrs)) do
      nil -> :ok
      key -> {:error, {:protected_field, to_string(key)}}
    end
  end

  # The caller's validated tool policy, intersected with every earlier one.
  defp restrict_dispatch_policy(meta, nil), do: {:ok, meta}

  defp restrict_dispatch_policy(meta, policy) do
    restricted =
      case Map.fetch(meta, "dispatchPolicy") do
        {:ok, current} -> ToolPolicy.restrict(current, policy)
        :error -> ToolPolicy.parse(policy)
      end

    case restricted do
      {:ok, policy} -> {:ok, Map.put(meta, "dispatchPolicy", ToolPolicy.to_map(policy))}
      {:error, _reason} -> {:error, :invalid_dispatch_policy}
    end
  end

  # Reserved records have one trusted writer each; supplied metadata never sets them.
  defp new_meta(meta, reserved), do: meta |> normalize_meta() |> Map.drop(reserved)

  @doc "The session a lease-guarded dispatcher run recorded for this exact card, if any."
  @spec trusted_run_session(map()) :: binary() | nil
  def trusted_run_session(%{id: task_id, meta: %{"kanbanRun" => run}}) when is_map(run) do
    if run["provenance"] == @run_provenance and run["taskId"] == task_id and
         is_binary(run["leaseId"]) and is_binary(run["sessionKey"]),
       do: run["sessionKey"]
  end

  def trusted_run_session(_task), do: nil

  defp maybe_retry(task, status, first_column) do
    if status == first_column and not tracked_run?(task) do
      update_in(task.meta, fn meta ->
        meta = Map.delete(meta, "lastFailure")

        case meta["codingWorkflow"] do
          %{"phase" => "completed"} ->
            Map.delete(meta, "codingWorkflow")

          %{} = workflow ->
            Map.put(meta, "codingWorkflow", Map.delete(workflow, "cancelRequested"))

          _ ->
            meta
        end
      end)
    else
      task
    end
  end

  defp workflow_completion_allowed(task, board, "done") do
    workflow = task.meta["codingWorkflow"]
    required? = is_map(workflow) or is_map(board.meta["codingWorkflow"])

    approved? =
      is_map(workflow) and workflow["phase"] == "completed" and
        get_in(workflow, ["review", "approved"]) == true and
        is_binary(workflow["commitSha"]) and workflow["cancelRequested"] != true

    if not required? or approved?, do: :ok, else: {:error, :review_required}
  end

  defp workflow_completion_allowed(_task, _board, _status), do: :ok

  defp tracked_run?(task) do
    get_in(task, [:meta, "kanbanRun", "status"]) in ["running", "outcome_unknown"]
  end

  defp terminal_meta(meta, status, opts) do
    run = Map.get(meta, "kanbanRun", %{})

    meta
    |> clear_lease()
    |> Map.put(
      "kanbanRun",
      run
      |> Map.put("status", status)
      |> Map.put("finishedAtMs", now_ms())
      |> Map.put("output", string_opt(opts[:output]))
    )
  end

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

  defp fetch_task_with_lease(task_id, lease_id) do
    case get_task(task_id) do
      %{} = task when map_size(task) == 0 ->
        {:error, :not_found}

      task ->
        with {:ok, board} <- fetch_board(task.board_id),
             ^lease_id <- lease_id(active_lease(task)) do
          {:ok, task, board}
        else
          {:error, _} = error -> error
          nil -> {:error, :stale_lease}
          _other_lease -> {:error, :stale_lease}
        end
    end
  end

  defp lease_id(%{} = lease), do: lease["id"] || lease[:id]
  defp lease_id(_), do: nil

  defp lease_worker_id(%{} = lease), do: lease["workerId"] || lease[:workerId]
  defp lease_worker_id(_), do: nil

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

    # A doorbell, not a payload: subscribers re-read the store. Lease renewals do
    # not ring it (they change no operator-visible state).
    ring_changed(board.id)
    :ok
  rescue
    error ->
      Logger.debug("Failed to emit kanban event #{event_type}: #{Exception.message(error)}")
      :ok
  end

  @doc """
  Bus topic rung with the doorbell `{:kanban_changed, board_id}` after every
  operator-visible board/task write (and dispatcher start/stop). Subscribers
  re-read the store; the message carries no board or task content.
  """
  @spec changed_topic() :: String.t()
  def changed_topic, do: "kanban"

  @doc "Rings the `changed_topic/0` doorbell for `board_id`."
  @spec ring_changed(binary()) :: :ok
  def ring_changed(board_id) when is_binary(board_id) do
    if LemonCore.Bus.running?(),
      do: LemonCore.Bus.broadcast(changed_topic(), {:kanban_changed, board_id})

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
