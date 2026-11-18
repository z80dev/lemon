defmodule LemonChannels.KanbanStatusMessage do
  @moduledoc """
  `/kanban` chat commands.

  The transport supplies trusted context only: the chat principal
  (`:agent_id`, `:session_key`), the bound workspace (`:workspace`), the channel
  context used to resolve the chat's run tool policy (`:channel_context`),
  notification metadata (`:meta`) and its operator attestation (`:operator?`).

  Boards record the chat as their principal and the chat's effective channel-run
  policy (`LemonRouter.Policy`) as their authority; cards record it too, and
  dispatch start durably narrows the board with it. Every mutation needs the
  transport's operator attestation, and every command is scoped to boards the
  chat principal is authorized for. Command flags never set the owner,
  workspace, assignee, author or worker identity.
  """

  alias LemonAgent.Workspace.{KanbanAuthority, KanbanStore}

  @rejected_flags ~w(--owner --workspace --assignee --author --worker-id --worker-profile --session-key --run-id)

  @spec handle(binary() | nil, keyword()) :: String.t()
  def handle(args, opts \\ []) do
    case parse_args(args) do
      {:rejected, flag} ->
        "Kanban option #{flag} is not accepted. The owner, workspace and assignee come from this chat."

      {:boards, command_opts} ->
        with_principal(opts, &boards_text(&1, command_opts))

      {:show_board, board_id, command_opts} ->
        with_board(board_id, opts, :read, &show_board_text(&1, command_opts))

      {:dispatch_status, board_id} ->
        with_board(board_id, opts, :read, &dispatch_status_text(&1, opts))

      {:create_board, name, _command_opts} ->
        with_operator(opts, fn principal -> create_board_text(name, principal, opts) end)

      {:archive_board, board_id} ->
        with_board(board_id, opts, :write, &archive_board_text(&1, opts))

      {:create_task, board_id, title, command_opts} ->
        with_board(board_id, opts, :write, &create_task_text(&1, title, command_opts, opts))

      {:update_task, task_id, command_opts} ->
        with_task(task_id, opts, &update_task_text(&1, command_opts, opts))

      {:comment_task, task_id, body, _command_opts} ->
        with_task(task_id, opts, &comment_task_text(&1, body, opts))

      {:dispatch_start, board_id, command_opts} ->
        with_board(board_id, opts, :write, &dispatch_start_text(&1, command_opts, opts))

      {:dispatch_stop, board_id} ->
        with_board(board_id, opts, :write, &dispatch_stop_text(&1, opts))

      :help ->
        help_text()
    end
  end

  # ── Authorization ─────────────────────────────────────────────────────────

  defp principal(opts) do
    case {opts[:agent_id], opts[:session_key]} do
      {agent_id, session_key}
      when is_binary(agent_id) and agent_id != "" and is_binary(session_key) and
             session_key != "" ->
        {:ok, %{agent_id: agent_id, session_key: session_key}}

      _ ->
        :error
    end
  end

  defp with_principal(opts, fun) do
    case principal(opts) do
      {:ok, principal} -> fun.(principal)
      :error -> "Kanban is unavailable: this chat has no trusted session identity."
    end
  end

  defp with_operator(opts, fun) do
    with_principal(opts, fn principal ->
      if opts[:operator?] == true,
        do: fun.(principal),
        else: "Kanban changes require the operator of this chat."
    end)
  end

  defp with_board(board_id, opts, access, fun) do
    run = fn principal ->
      case KanbanStore.get_board(board_id) do
        board when map_size(board) > 0 ->
          if permitted?(board, principal), do: fun.(board), else: not_authorized()

        _ ->
          not_authorized()
      end
    end

    if access == :write, do: with_operator(opts, run), else: with_principal(opts, run)
  end

  defp with_task(task_id, opts, fun) do
    case KanbanStore.get_task(task_id) do
      task when map_size(task) > 0 ->
        with_board(task.board_id, opts, :write, fn _ -> fun.(task) end)

      _ ->
        with_operator(opts, fn _ -> not_authorized() end)
    end
  end

  defp permitted?(board, principal) do
    case KanbanAuthority.fetch(board) do
      {:ok, authority} -> KanbanAuthority.permits?(authority, principal)
      {:error, _} -> false
    end
  end

  defp not_authorized,
    do: "Kanban board or task is not available or not authorized for this chat."

  # The chat's effective channel-run policy, resolved exactly as the router
  # resolves a run from this chat. Unavailable resolution fails closed.
  defp chat_policy(principal, opts) do
    module = :"Elixir.LemonRouter.Policy"

    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :resolve_validated_for_run, 1),
         {:ok, policy} <-
           apply(module, :resolve_validated_for_run, [
             %{
               agent_id: principal.agent_id,
               session_key: principal.session_key,
               origin: :channel,
               channel_context: opts[:channel_context]
             }
           ]) do
      {:ok, policy}
    else
      _ -> {:error, :policy_unavailable}
    end
  end

  # ── Commands ──────────────────────────────────────────────────────────────

  defp boards_text(principal, command_opts) do
    boards =
      command_opts
      |> Keyword.take([:status])
      |> Keyword.put(:limit, 10_000)
      |> KanbanStore.list_boards()
      |> Enum.filter(&permitted?(&1, principal))
      |> Enum.take(command_opts[:limit] || 50)

    [
      "Kanban Boards",
      "Total shown: #{length(boards)}"
      | Enum.map(boards, &board_summary/1)
    ]
    |> Enum.join("\n")
  end

  defp create_board_text(name, principal, opts) do
    with {:ok, policy} <- chat_policy(principal, opts),
         {:ok, authority} <-
           KanbanAuthority.new(principal, policy, opts[:workspace] || "", granted_by: "channel"),
         {:ok, board} <-
           KanbanStore.create_board(name,
             workspace: authority["root"],
             owner: principal.agent_id,
             meta: opts[:meta],
             authority: authority
           ) do
      Enum.join(
        [
          "Kanban Board Created",
          "Board id: #{board.id}",
          "Status: #{board.status}",
          "Name bytes: #{byte_size(board.name || "")}",
          "Workspace: set"
        ],
        "\n"
      )
    else
      {:error, :empty_name} ->
        "Board name is required. Use /kanban create <name>."

      {:error, :policy_unavailable} ->
        "Kanban board create failed: this chat's tool policy is unavailable."

      {:error, reason}
      when reason in [:enoent, :not_a_directory, :relative_path, :invalid_path] ->
        "Kanban board create failed: this chat has no existing bound project directory."

      {:error, reason} ->
        "Kanban board create failed: #{inspect(reason)}"
    end
  end

  defp show_board_text(board, command_opts) do
    tasks = KanbanStore.list_tasks(board.id, Keyword.take(command_opts, [:status, :limit]))

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

  defp archive_board_text(board, opts) do
    case KanbanStore.archive_board(board.id, Keyword.take(opts, [:meta])) do
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

      {:error, reason} ->
        "Kanban board archive failed: #{inspect(reason)}"
    end
  end

  defp create_task_text(board, title, command_opts, opts) do
    {:ok, principal} = principal(opts)

    with {:ok, policy} <- chat_policy(principal, opts),
         {:ok, task} <-
           KanbanStore.create_task(
             board.id,
             title,
             command_opts
             |> Keyword.take([:status, :priority])
             |> Keyword.merge(
               assignee: principal.agent_id,
               meta: opts[:meta],
               dispatch_policy: policy
             )
           ) do
      task_change_text("Kanban Task Created", task)
    else
      {:error, :empty_title} ->
        "Task title is required. Use /kanban task create <board-id> <title>."

      {:error, :policy_unavailable} ->
        "Kanban task create failed: this chat's tool policy is unavailable."

      {:error, reason} ->
        "Kanban task create failed: #{inspect(reason)}"
    end
  end

  defp update_task_text(task, command_opts, opts) do
    {:ok, principal} = principal(opts)

    attrs =
      command_opts
      |> Keyword.take([:status, :priority])
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)

    with {:ok, policy} <- chat_policy(principal, opts),
         {:ok, task} <- KanbanStore.update_task(task.id, attrs, dispatch_policy: policy) do
      task_change_text("Kanban Task Updated", task)
    else
      {:error, :policy_unavailable} ->
        "Kanban task update failed: this chat's tool policy is unavailable."

      {:error, reason} ->
        "Kanban task update failed: #{inspect(reason)}"
    end
  end

  defp comment_task_text(task, body, opts) do
    case KanbanStore.add_comment(task.id, body, author: opts[:agent_id]) do
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

      {:error, :empty_comment} ->
        "Comment body is required. Use /kanban comment <task-id> <body>."

      {:error, reason} ->
        "Kanban task comment failed: #{inspect(reason)}"
    end
  end

  defp dispatch_start_text(board, command_opts, opts) do
    {:ok, principal} = principal(opts)

    dispatcher_opts =
      command_opts
      |> Keyword.take([:interval_ms, :max_concurrency, :lease_ms])
      |> Keyword.put(:worker_id, principal.agent_id)

    with {:ok, policy} <- chat_policy(principal, opts),
         {:ok, _board} <- KanbanStore.restrict_authority(board.id, policy),
         {:ok, dispatcher} <- call_dispatcher(:start_board, [board.id, dispatcher_opts], opts) do
      dispatcher_text("Kanban Dispatcher Started", dispatcher)
    else
      {:error, :already_running} -> "Kanban dispatcher is already running for this board."
      {:error, reason} -> "Kanban dispatcher start failed: #{inspect(reason)}"
    end
  end

  defp dispatch_status_text(board, opts) do
    case call_dispatcher(:status, [board.id, []], opts) do
      {:ok, %{running: running, dispatcher: dispatcher}} ->
        Enum.join(
          [
            "Kanban Dispatcher Status",
            "Running: #{running}",
            dispatcher && "Status: #{field(dispatcher, :status) || "unknown"}",
            dispatcher && "Board id: #{field(dispatcher, :board_id) || board.id}"
          ]
          |> Enum.reject(&is_nil/1),
          "\n"
        )

      {:error, reason} ->
        "Kanban dispatcher status failed: #{inspect(reason)}"
    end
  end

  defp dispatch_stop_text(board, opts) do
    case call_dispatcher(:stop_board, [board.id, []], opts) do
      {:ok, dispatcher} -> dispatcher_text("Kanban Dispatcher Stopped", dispatcher)
      {:error, :not_running} -> "No kanban dispatcher is running for this board."
      {:error, reason} -> "Kanban dispatcher stop failed: #{inspect(reason)}"
    end
  end

  # ── Parsing ───────────────────────────────────────────────────────────────

  defp parse_args(args) when is_binary(args) do
    tokens = String.split(args, ~r/\s+/, trim: true)

    case Enum.find(tokens, &(&1 in @rejected_flags)) do
      nil -> parse_tokens(tokens)
      flag -> {:rejected, flag}
    end
  end

  defp parse_args(_), do: {:boards, []}

  defp parse_tokens(tokens) do
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

  defp split_opts(tokens) do
    {words, opts} = split_opts(tokens, [], [])
    {Enum.reverse(words), Enum.reverse(opts)}
  end

  defp split_opts([], words, opts), do: {words, opts}

  defp split_opts([flag, value | rest], words, opts) when flag in ["--status", "--priority"] do
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

  defp opt_key("--status"), do: :status
  defp opt_key("--priority"), do: :priority
  defp opt_key("--limit"), do: :limit
  defp opt_key("--interval-ms"), do: :interval_ms
  defp opt_key("--max-concurrency"), do: :max_concurrency
  defp opt_key("--lease-ms"), do: :lease_ms

  # ── Rendering ─────────────────────────────────────────────────────────────

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
        "/kanban boards - list this chat's boards",
        "/kanban create <name> - create a board in this chat's project (operator)",
        "/kanban show <board-id> - show redacted board tasks",
        "/kanban archive <board-id> - archive a board (operator)",
        "/kanban task create <board-id> <title> - create a task (operator)",
        "/kanban task update <task-id> --status <status> - update a task (operator)",
        "/kanban comment <task-id> <body> - add a task comment (operator)",
        "/kanban dispatch start <board-id> - start board dispatcher (operator)",
        "/kanban dispatch status <board-id> - show dispatcher status",
        "/kanban dispatch stop <board-id> - stop board dispatcher (operator)"
      ],
      "\n"
    )
  end
end
