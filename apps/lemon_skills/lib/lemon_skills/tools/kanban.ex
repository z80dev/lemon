defmodule LemonSkills.Tools.Kanban do
  @moduledoc """
  Durable kanban board tool backed by LemonCore.KanbanStore.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias LemonCore.KanbanStore

  @actions ~w(board_list board_create board_get task_list task_get task_create task_update task_comment)

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "kanban",
      description:
        "Manage durable Lemon kanban boards and tasks for multi-agent work. Use this for work that should persist beyond the current session.",
      label: "Kanban",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => @actions,
            "description" => "Kanban operation to run."
          },
          "board_id" => %{"type" => "string", "description" => "Board id for board/task actions."},
          "task_id" => %{"type" => "string", "description" => "Task id for task actions."},
          "name" => %{"type" => "string", "description" => "Board name for board_create."},
          "title" => %{"type" => "string", "description" => "Task title."},
          "description" => %{"type" => "string", "description" => "Task description."},
          "body" => %{"type" => "string", "description" => "Comment body for task_comment."},
          "status" => %{"type" => "string", "description" => "Board or task status filter/value."},
          "priority" => %{"type" => "string", "description" => "Task priority."},
          "assignee" => %{
            "type" => "string",
            "description" => "Task assignee or assignee filter."
          },
          "worker_profile" => %{"type" => "string", "description" => "Worker profile for a task."},
          "session_key" => %{"type" => "string", "description" => "Session key linked to a task."},
          "run_id" => %{"type" => "string", "description" => "Router run id linked to a task."},
          "owner" => %{"type" => "string", "description" => "Board owner or owner filter."},
          "workspace" => %{"type" => "string", "description" => "Board workspace path."},
          "author" => %{"type" => "string", "description" => "Comment author."},
          "columns" => %{
            "type" => "array",
            "description" => "Board columns for board_create.",
            "items" => %{"type" => "string"}
          },
          "depends_on" => %{
            "type" => "array",
            "description" => "Task ids that must complete before this task is available.",
            "items" => %{"type" => "string"}
          },
          "include_tasks" => %{
            "type" => "boolean",
            "description" => "Whether board_get includes tasks. Defaults to true."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "Maximum rows to return."
          }
        },
        "required" => ["action"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, _signal, _on_update, cwd, opts) do
    case Map.get(params, "action") do
      "board_list" -> board_list(params)
      "board_create" -> board_create(params, cwd, opts)
      "board_get" -> board_get(params)
      "task_list" -> task_list(params)
      "task_get" -> task_get(params)
      "task_create" -> task_create(params)
      "task_update" -> task_update(params)
      "task_comment" -> task_comment(params, opts)
      nil -> {:error, "missing required parameter: action"}
      action -> {:error, "unsupported kanban action: #{inspect(action)}"}
    end
  end

  defp board_list(params) do
    opts =
      []
      |> put_opt(:status, params["status"])
      |> put_opt(:owner, params["owner"])
      |> put_opt(:workspace, params["workspace"])
      |> put_opt(:limit, params["limit"])

    result("kanban boards", %{boards: KanbanStore.list_boards(opts)})
  end

  defp board_create(params, cwd, opts) do
    with {:ok, name} <- required_string(params, "name") do
      create_opts =
        []
        |> put_opt(:workspace, params["workspace"] || Keyword.get(opts, :kanban_workspace) || cwd)
        |> put_opt(:owner, params["owner"] || Keyword.get(opts, :agent_id))
        |> put_opt(:columns, params["columns"])

      case KanbanStore.create_board(name, create_opts) do
        {:ok, board} -> result("created kanban board #{board.id}", %{board: board})
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  defp board_get(params) do
    with {:ok, board_id} <- required_string(params, "board_id"),
         {:ok, board} <- fetch_board(board_id) do
      payload = %{board: board}

      payload =
        if Map.get(params, "include_tasks", true) do
          Map.put(
            payload,
            :tasks,
            KanbanStore.list_tasks(board.id, limit: params["limit"] || 100)
          )
        else
          payload
        end

      result("kanban board #{board.id}", payload)
    end
  end

  defp task_list(params) do
    with {:ok, board_id} <- required_string(params, "board_id") do
      opts =
        []
        |> put_opt(:status, params["status"])
        |> put_opt(:assignee, params["assignee"])
        |> put_opt(:limit, params["limit"])

      result("kanban tasks", %{tasks: KanbanStore.list_tasks(board_id, opts)})
    end
  end

  defp task_get(params) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, task} <- fetch_task(task_id) do
      result("kanban task #{task.id}", %{task: task})
    end
  end

  defp task_create(params) do
    with {:ok, board_id} <- required_string(params, "board_id"),
         {:ok, title} <- required_string(params, "title") do
      opts =
        []
        |> put_opt(:description, params["description"])
        |> put_opt(:status, params["status"])
        |> put_opt(:priority, params["priority"])
        |> put_opt(:assignee, params["assignee"])
        |> put_opt(:worker_profile, params["worker_profile"])
        |> put_opt(:session_key, params["session_key"])
        |> put_opt(:run_id, params["run_id"])
        |> put_opt(:depends_on, params["depends_on"])

      case KanbanStore.create_task(board_id, title, opts) do
        {:ok, task} -> result("created kanban task #{task.id}", %{task: task})
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  defp task_update(params) do
    with {:ok, task_id} <- required_string(params, "task_id") do
      attrs =
        %{}
        |> put_attr(:title, params["title"])
        |> put_attr(:description, params["description"])
        |> put_attr(:status, params["status"])
        |> put_attr(:priority, params["priority"])
        |> put_attr(:assignee, params["assignee"])
        |> put_attr(:worker_profile, params["worker_profile"])
        |> put_attr(:session_key, params["session_key"])
        |> put_attr(:run_id, params["run_id"])
        |> put_attr(:depends_on, params["depends_on"])

      case KanbanStore.update_task(task_id, attrs) do
        {:ok, task} -> result("updated kanban task #{task.id}", %{task: task})
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  defp task_comment(params, opts) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, body} <- required_string(params, "body") do
      comment_opts =
        []
        |> put_opt(:author, params["author"] || Keyword.get(opts, :agent_id))

      case KanbanStore.add_comment(task_id, body, comment_opts) do
        {:ok, task} -> result("commented on kanban task #{task.id}", %{task: task})
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  defp fetch_board(board_id) do
    case KanbanStore.get_board(board_id) do
      %{} = board when map_size(board) == 0 -> {:error, "board not found: #{board_id}"}
      board -> {:ok, board}
    end
  end

  defp fetch_task(task_id) do
    case KanbanStore.get_task(task_id) do
      %{} = task when map_size(task) == 0 -> {:error, "task not found: #{task_id}"}
      task -> {:ok, task}
    end
  end

  defp required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, "#{key} is required"}, else: {:ok, value}

      _ ->
        {:error, "#{key} is required"}
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, ""), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_attr(attrs, _key, nil), do: attrs
  defp put_attr(attrs, _key, ""), do: attrs
  defp put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp result(title, details) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: Jason.encode!(details, pretty: true)}],
      details: Map.put(details, :title, title)
    }
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
