defmodule LemonChannels.KanbanStatusMessage do
  @moduledoc false

  alias LemonCore.KanbanStore

  @spec handle(binary() | nil, keyword()) :: String.t()
  def handle(args, opts \\ []) do
    case parse_args(args) do
      {:boards, command_opts} ->
        boards_text(Keyword.merge(opts, command_opts))

      {:create_board, name, command_opts} ->
        create_board_text(name, Keyword.merge(opts, command_opts))

      {:show_board, board_id, command_opts} ->
        show_board_text(board_id, Keyword.merge(opts, command_opts))

      {:archive_board, board_id} ->
        archive_board_text(board_id, opts)

      {:create_task, board_id, title, command_opts} ->
        create_task_text(board_id, title, Keyword.merge(opts, command_opts))

      {:update_task, task_id, command_opts} ->
        update_task_text(task_id, Keyword.merge(opts, command_opts))

      {:comment_task, task_id, body, command_opts} ->
        comment_task_text(task_id, body, Keyword.merge(opts, command_opts))

      {:dispatch_start, board_id, command_opts} ->
        dispatch_start_text(board_id, Keyword.merge(opts, command_opts))

      {:dispatch_status, board_id} ->
        dispatch_status_text(board_id, opts)

      {:dispatch_stop, board_id} ->
        dispatch_stop_text(board_id, opts)

      :help ->
        help_text()
    end
  end

  defp boards_text(opts) do
    boards = KanbanStore.list_boards(opts)

    [
      "Kanban Boards",
      "Total shown: #{length(boards)}"
      | Enum.map(boards, &board_summary/1)
    ]
    |> Enum.join("\n")
  end

  defp create_board_text(name, opts) do
    case KanbanStore.create_board(name, opts) do
      {:ok, board} ->
        Enum.join(
          [
            "Kanban Board Created",
            "Board id: #{board.id}",
            "Status: #{board.status}",
            "Name bytes: #{byte_size(board.name || "")}",
            board.workspace && "Workspace: set"
          ]
          |> Enum.reject(&is_nil/1),
          "\n"
        )

      {:error, :empty_name} ->
        "Board name is required. Use /kanban create <name>."

      {:error, reason} ->
        "Kanban board create failed: #{inspect(reason)}"
    end
  end

  defp show_board_text(board_id, opts) do
    case KanbanStore.get_board(board_id) do
      %{} = board when map_size(board) == 0 ->
        "Kanban board not found."

      board ->
        tasks = KanbanStore.list_tasks(board.id, opts)

        [
          "Kanban Board",
          "Board id: #{board.id}",
          "Status: #{board.status}",
          "Columns: #{Enum.join(board.columns || [], ", ")}",
          "Tasks shown: #{length(tasks)}"
          | Enum.map(tasks, &task_summary/1)
        ]
        |> Enum.join("\n")
    end
  end

  defp archive_board_text(board_id, opts) do
    case KanbanStore.archive_board(board_id, opts) do
      {:ok, board} ->
        Enum.join(
          [
            "Kanban Board Archived",
            "Board id: #{board.id}",
            "Status: #{board.status}",
            "Name bytes: #{byte_size(board.name || "")}"
          ],
          "\n"
        )

      {:error, :not_found} ->
        "Kanban board not found."

      {:error, reason} ->
        "Kanban board archive failed: #{inspect(reason)}"
    end
  end

  defp create_task_text(board_id, title, opts) do
    case KanbanStore.create_task(board_id, title, opts) do
      {:ok, task} ->
        task_change_text("Kanban Task Created", task)

      {:error, :not_found} ->
        "Kanban board not found."

      {:error, :empty_title} ->
        "Task title is required. Use /kanban task create <board-id> <title>."

      {:error, reason} ->
        "Kanban task create failed: #{inspect(reason)}"
    end
  end

  defp update_task_text(task_id, opts) do
    attrs =
      opts
      |> Keyword.take([:status, :priority, :assignee, :worker_profile, :session_key, :run_id])
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)

    case KanbanStore.update_task(task_id, attrs, opts) do
      {:ok, task} -> task_change_text("Kanban Task Updated", task)
      {:error, :not_found} -> "Kanban task not found."
      {:error, reason} -> "Kanban task update failed: #{inspect(reason)}"
    end
  end

  defp comment_task_text(task_id, body, opts) do
    case KanbanStore.add_comment(task_id, body, opts) do
      {:ok, task} ->
        Enum.join(
          [
            "Kanban Task Commented",
            "Task id: #{task.id}",
            "Status: #{task.status}",
            "Comments: #{length(task.comments || [])}"
          ],
          "\n"
        )

      {:error, :not_found} ->
        "Kanban task not found."

      {:error, :empty_comment} ->
        "Comment body is required. Use /kanban comment <task-id> <body>."

      {:error, reason} ->
        "Kanban task comment failed: #{inspect(reason)}"
    end
  end

  defp dispatch_start_text(board_id, opts) do
    case call_dispatcher(:start_board, [board_id, dispatcher_opts(opts)], opts) do
      {:ok, dispatcher} -> dispatcher_text("Kanban Dispatcher Started", dispatcher)
      {:error, :board_not_found} -> "Kanban board not found."
      {:error, :already_running} -> "Kanban dispatcher is already running for this board."
      {:error, reason} -> "Kanban dispatcher start failed: #{inspect(reason)}"
    end
  end

  defp dispatch_status_text(board_id, opts) do
    case call_dispatcher(:status, [board_id, dispatcher_opts(opts)], opts) do
      {:ok, %{running: running, dispatcher: dispatcher}} ->
        Enum.join(
          [
            "Kanban Dispatcher Status",
            "Running: #{running}",
            dispatcher && "Status: #{field(dispatcher, :status) || "unknown"}",
            dispatcher && "Board id: #{field(dispatcher, :board_id) || board_id}"
          ]
          |> Enum.reject(&is_nil/1),
          "\n"
        )

      {:error, reason} ->
        "Kanban dispatcher status failed: #{inspect(reason)}"
    end
  end

  defp dispatch_stop_text(board_id, opts) do
    case call_dispatcher(:stop_board, [board_id, dispatcher_opts(opts)], opts) do
      {:ok, dispatcher} -> dispatcher_text("Kanban Dispatcher Stopped", dispatcher)
      {:error, :not_running} -> "No kanban dispatcher is running for this board."
      {:error, reason} -> "Kanban dispatcher stop failed: #{inspect(reason)}"
    end
  end

  defp parse_args(args) when is_binary(args) do
    tokens = String.split(args, ~r/\s+/, trim: true)

    case tokens do
      [] ->
        {:boards, []}

      ["boards" | rest] ->
        {:boards, parse_opts(rest)}

      ["list" | rest] ->
        {:boards, parse_opts(rest)}

      ["create" | rest] ->
        {words, opts} = split_opts(rest)
        {:create_board, Enum.join(words, " "), opts}

      ["show", board_id | rest] ->
        {:show_board, board_id, parse_opts(rest)}

      ["tasks", board_id | rest] ->
        {:show_board, board_id, parse_opts(rest)}

      ["archive", board_id | _rest] ->
        {:archive_board, board_id}

      ["task", "create", board_id | rest] ->
        {words, opts} = split_opts(rest)
        {:create_task, board_id, Enum.join(words, " "), opts}

      ["task", "update", task_id | rest] ->
        {:update_task, task_id, parse_opts(rest)}

      ["comment", task_id | rest] ->
        {words, opts} = split_opts(rest)
        {:comment_task, task_id, Enum.join(words, " "), opts}

      ["dispatch", "start", board_id | rest] ->
        {:dispatch_start, board_id, parse_opts(rest)}

      ["dispatch", "status", board_id | _rest] ->
        {:dispatch_status, board_id}

      ["dispatch", "stop", board_id | _rest] ->
        {:dispatch_stop, board_id}

      _ ->
        :help
    end
  end

  defp parse_args(_), do: {:boards, []}

  defp split_opts(tokens) do
    {words, opts} = split_opts(tokens, [], [])
    {Enum.reverse(words), Enum.reverse(opts)}
  end

  defp split_opts([], words, opts), do: {words, opts}

  defp split_opts([flag, value | rest], words, opts)
       when flag in [
              "--status",
              "--owner",
              "--workspace",
              "--priority",
              "--assignee",
              "--worker-profile",
              "--session-key",
              "--run-id",
              "--author",
              "--worker-id"
            ] do
    split_opts(rest, words, [{opt_key(flag), value} | opts])
  end

  defp split_opts([flag, value | rest], words, opts)
       when flag in ["--limit", "--interval-ms", "--max-concurrency", "--lease-ms"] do
    case Integer.parse(value || "") do
      {integer, ""} when integer > 0 -> split_opts(rest, words, [{opt_key(flag), integer} | opts])
      _ -> split_opts(rest, words, opts)
    end
  end

  defp split_opts([token | rest], words, opts), do: split_opts(rest, [token | words], opts)

  defp parse_opts(tokens) do
    {_words, opts} = split_opts(tokens)
    opts
  end

  defp opt_key("--worker-profile"), do: :worker_profile
  defp opt_key("--session-key"), do: :session_key
  defp opt_key("--run-id"), do: :run_id
  defp opt_key("--worker-id"), do: :worker_id
  defp opt_key("--interval-ms"), do: :interval_ms
  defp opt_key("--max-concurrency"), do: :max_concurrency
  defp opt_key("--lease-ms"), do: :lease_ms
  defp opt_key("--" <> key), do: String.to_atom(key)

  defp board_summary(board) do
    tasks = KanbanStore.list_tasks(board.id, limit: 10_000)
    open = Enum.count(tasks, &(&1.status != "done"))

    "#{board.id} - #{board.status} - open #{open}/#{length(tasks)} - name bytes #{byte_size(board.name || "")}"
  end

  defp task_summary(task) do
    "  #{task.id} - #{task.status} - #{task.priority || "normal"} - title bytes #{byte_size(task.title || "")} - comments #{length(task.comments || [])}"
  end

  defp task_change_text(title, task) do
    Enum.join(
      [
        title,
        "Task id: #{task.id}",
        "Board id: #{task.board_id}",
        "Status: #{task.status}",
        "Priority: #{task.priority || "normal"}",
        "Title bytes: #{byte_size(task.title || "")}"
      ],
      "\n"
    )
  end

  defp dispatcher_text(title, dispatcher) do
    Enum.join(
      [
        title,
        "Status: #{field(dispatcher, :status) || "unknown"}",
        "Board id: #{field(dispatcher, :board_id) || "unknown"}",
        "Max concurrency: #{field(dispatcher, :max_concurrency) || "unknown"}"
      ],
      "\n"
    )
  end

  defp dispatcher_opts(opts) do
    opts
    |> Keyword.take([:interval_ms, :max_concurrency, :lease_ms, :worker_id, :worker_profile])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp call_dispatcher(function, args, opts) do
    module =
      opts[:dispatcher_module] ||
        Application.get_env(
          :lemon_channels,
          :kanban_dispatcher_module,
          :"Elixir.LemonAutomation.KanbanDispatcher"
        )

    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      _ -> {:error, :not_available}
    end
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || Map.get(map, camelize(key))
  end

  defp field(_map, _key), do: nil

  defp camelize(key) do
    key
    |> Atom.to_string()
    |> Macro.camelize()
    |> then(fn <<first::binary-size(1), rest::binary>> -> String.downcase(first) <> rest end)
  end

  defp help_text do
    Enum.join(
      [
        "Kanban Commands",
        "/kanban boards - list boards",
        "/kanban create <name> - create a board",
        "/kanban show <board-id> - show redacted board tasks",
        "/kanban archive <board-id> - archive a board",
        "/kanban task create <board-id> <title> - create a task",
        "/kanban task update <task-id> --status <status> - update a task",
        "/kanban comment <task-id> <body> - add a task comment",
        "/kanban dispatch start <board-id> - start board dispatcher",
        "/kanban dispatch status <board-id> - show dispatcher status",
        "/kanban dispatch stop <board-id> - stop board dispatcher"
      ],
      "\n"
    )
  end
end
