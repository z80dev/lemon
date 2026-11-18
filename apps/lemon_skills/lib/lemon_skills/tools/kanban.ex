defmodule LemonSkills.Tools.Kanban do
  @moduledoc """
  Durable kanban board tool backed by LemonAgent.Workspace.KanbanStore.

  Wired into CodingAgent.ToolRegistry's builtin tool list. No external service or credentials are
  required; boards and tasks persist in the workspace KanbanStore.

  `board_create` optionally accepts `coding_workflow`: an explicit opt-in map
  for isolated coding, review of the exact diff, and a local branch commit before
  completion. Omission or `false` preserves coding-only behavior. Publishing is
  disabled unless an explicit `publish` map selects `branch` or `pull_request`.
  Workflow settings are validated by the optional automation service and stored
  unchanged as JSON-safe string-key settings under board metadata `codingWorkflow`;
  arbitrary metadata, force-push, and command options are not accepted.

  Dispatched workers act for the calling session, never with more authority:

    * Every action needs the invoking session's trusted identity (`:session_key`
      and `:agent_id` opts). A board records that session as its principal
      (`LemonAgent.Workspace.KanbanAuthority`); only it, and sessions an
      operator shared the board with, can list, read, edit, start or stop it.
      Missing, quarantined and other principals' boards look the same.
    * `session_key`, `run_id`, `owner` and `worker_profile` params are rejected;
      the card assignee is the calling agent. The workspace root is the
      canonical session cwd; a board `workspace` must be an existing directory
      inside it after symlinks are resolved.
    * The caller's effective tool policy is recorded on the board and on every
      card it creates or edits; `dispatch_start` durably narrows the board
      authority with the starter's policy. Workers run with the intersection.
    * `coding_workflow.publish` is recorded as a publication grant only when the
      creator's policy allows shell and external access without approval.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonAgent.Workspace.{KanbanAuthority, KanbanStore}
  alias LemonCore.ToolPolicy

  @actions ~w(board_list board_create board_get task_list task_get task_create task_update task_comment dispatch_start dispatch_stop dispatch_status)
  @caller_derived ~w(session_key run_id owner worker_profile)

  @doc """
  Returns the `LemonAgent.Types.AgentTool.t()` definition for the `"kanban"`
  tool, wired to `execute/6`.

  `cwd` is the session working directory: the default board workspace and the
  boundary for an explicit `"workspace"`. The invoking session's `opts` supply
  `:agent_id` (board owner, task assignee, default comment author and worker
  agent), `:session_key` (board notifications) and `:tool_policy` /
  `:execution_context` (the authority recorded for dispatched workers).
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "kanban",
      description:
        "Manage durable Lemon kanban boards and coding tasks. Create a board in a repository, add tasks, then dispatch_start to execute them in isolated worktrees. Inspect task_get for progress/results; dispatch_stop cancels workers. Move a failed task back to the first column to explicitly retry.",
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
            "description" =>
              "Assignee filter for task_list. Tasks are always assigned to the calling agent."
          },
          "workspace" => %{
            "type" => "string",
            "description" =>
              "Board workspace inside the session working directory (board_create), or a board_list filter."
          },
          "author" => %{"type" => "string", "description" => "Comment author."},
          "coding_workflow" => coding_workflow_schema(),
          "deliver_to" => %{
            "type" => "string",
            "description" =>
              "Supervision for board_create: auto (origin channel or owner), none, telegram:chat[:thread], or discord:channel[:thread]."
          },
          "max_concurrency" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 8,
            "description" => "Parallel coding workers for dispatch_start (default 1)."
          },
          "model" => %{
            "type" => "string",
            "description" => "Optional provider:model for workers."
          },
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

  @doc """
  Tool callback invoked by the agent loop with, in order: `tool_call_id`,
  `params` map, `signal`, `on_update` callback, `cwd`, and `opts`.

  Reads the required `"action"` param to dispatch to `board_list`,
  `board_create`, `board_get`, `task_list`, `task_get`, `task_create`,
  `task_update`, or `task_comment`. Per action: `board_list` reads `"status"`,
  `"workspace"`, `"limit"`; `board_create` requires `"name"` and
  reads `"workspace"`, `"columns"`, `"coding_workflow"`; `board_get` requires
  `"board_id"` and reads `"include_tasks"` (defaults to `true`) and `"limit"`
  (defaults to `100`); `task_list` requires `"board_id"` and reads `"status"`,
  `"assignee"`, `"limit"`; `task_get` requires `"task_id"`; `task_create`
  requires `"board_id"` and `"title"` and reads `"description"`, `"status"`,
  `"priority"`, `"assignee"` (only the calling agent) and `"depends_on"`;
  `task_update` requires `"task_id"` and reads the same optional fields plus
  `"title"`; `task_comment` requires `"task_id"` and `"body"` and reads
  `"author"`. `session_key`, `run_id`, `owner` and `worker_profile` are
  rejected for every action.

  `dispatch_start`, `dispatch_stop`, and `dispatch_status` require `"board_id"`
  and operate on the long-running automation dispatcher. Start accepts
  `"max_concurrency"` (1–8) and an optional worker `"model"`. No scheduler is
  started by this tool when the automation runtime is unavailable.
  Supplied `"coding_workflow"` settings also require the automation service and
  are validated before board creation. Only explicit caller settings are stored;
  publishing settings are never inferred from the repository or coding output.

  On success returns a `%LemonAgent.Types.AgentToolResult{}` whose `content`
  is the pretty-printed JSON encoding of the details and whose `details` map
  holds the payload (board/task data) plus a `:title` summary string. Failures
  — a missing or unsupported `"action"`, a missing required param, a missing
  board/task, a board owned by another agent, or a `KanbanStore` error — return
  `{:error, message}` with a string message.
  """
  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, _signal, _on_update, cwd, opts) do
    with :ok <- reject_caller_derived(params) do
      case Map.get(params, "action") do
        "board_list" -> board_list(params, opts)
        "board_create" -> board_create(params, cwd, opts)
        "board_get" -> board_get(params, opts)
        "task_list" -> task_list(params, opts)
        "task_get" -> task_get(params, opts)
        "task_create" -> task_create(params, opts)
        "task_update" -> task_update(params, opts)
        "task_comment" -> task_comment(params, opts)
        "dispatch_start" -> dispatch(:start_board, params, opts)
        "dispatch_stop" -> dispatch(:stop_board, params, opts)
        "dispatch_status" -> dispatch(:status, params, opts)
        nil -> {:error, "missing required parameter: action"}
        action -> {:error, "unsupported kanban action: #{inspect(action)}"}
      end
    end
  end

  defp coding_workflow_schema do
    %{
      "description" =>
        "board_create only. Explicit opt-in to isolated coding, exact-diff review, and a local branch commit before done. Omit or set false for coding-only behavior. Never publishes unless publish explicitly selects a mode.",
      "anyOf" => [
        %{"type" => "boolean", "enum" => [false]},
        %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "reviewModel" => %{
              "type" => "string",
              "minLength" => 1,
              "description" => "Optional nonempty reviewer model (provider:model)."
            },
            "publish" => %{
              "description" =>
                "Omit or set false to keep commits local with no network publishing. Supply a mode only when publishing is explicitly authorized.",
              "anyOf" => [
                %{"type" => "boolean", "enum" => [false]},
                %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "properties" => %{
                    "mode" => %{
                      "type" => "string",
                      "enum" => ["branch", "pull_request"],
                      "description" =>
                        "branch pushes the task branch; pull_request also opens a PR and records its link."
                    },
                    "remote" => %{
                      "type" => "string",
                      "minLength" => 1,
                      "description" => "Explicit Git remote name, such as origin."
                    },
                    "repository" => %{
                      "type" => "string",
                      "minLength" => 1,
                      "description" => "Required for pull_request: repository as owner/repo."
                    },
                    "base" => %{
                      "type" => "string",
                      "minLength" => 1,
                      "description" => "Required for pull_request: target branch, such as main."
                    },
                    "draft" => %{
                      "type" => "boolean",
                      "default" => true,
                      "description" => "Create pull requests as drafts by default."
                    }
                  },
                  "required" => ["mode", "remote"]
                }
              ]
            }
          }
        }
      ]
    }
  end

  defp dispatch(operation, params, opts) do
    module = :"Elixir.LemonAutomation.KanbanDispatcher"
    concurrency = Map.get(params, "max_concurrency", 1)

    with {:ok, board_id} <- required_string(params, "board_id"),
         {:ok, _board} <- authorized_board(board_id, opts),
         true <- is_integer(concurrency) and concurrency in 1..8,
         true <- Code.ensure_loaded?(module) and function_exported?(module, operation, 2),
         :ok <- record_starter(operation, board_id, opts) do
      opts =
        if operation == :start_board do
          worker_opts =
            []
            |> put_opt(:model, params["model"])
            |> put_opt(:agent_id, caller_agent(opts))

          [max_concurrency: concurrency, worker_opts: worker_opts]
        else
          []
        end

      case apply(module, operation, [board_id, opts]) do
        {:ok, dispatch} -> result("kanban dispatch #{board_id}", %{dispatch: dispatch})
        {:error, reason} -> {:error, format_error(reason)}
      end
    else
      false -> {:error, "kanban dispatcher unavailable or max_concurrency must be 1..8"}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _ -> {:error, "kanban dispatcher unavailable"}
  end

  # A starter durably narrows the board authority before any worker can run, so
  # later restarts (including operator restarts) keep its restrictions.
  defp record_starter(:start_board, board_id, opts) do
    case KanbanStore.restrict_authority(board_id, caller_policy(opts)) do
      {:ok, _board} -> :ok
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp record_starter(_operation, _board_id, _opts), do: :ok

  defp board_list(params, opts) do
    with {:ok, principal} <- principal(opts) do
      filters =
        []
        |> put_opt(:status, params["status"])
        |> put_opt(:workspace, params["workspace"])
        |> Keyword.put(:limit, 10_000)

      boards =
        filters
        |> KanbanStore.list_boards()
        |> Enum.filter(&permitted?(&1, principal))
        |> Enum.take(positive(params["limit"], 50))

      result("kanban boards", %{boards: boards})
    end
  end

  defp validate_delivery(nil), do: {:ok, nil}

  defp validate_delivery(value) do
    module = :"Elixir.LemonAutomation.CronDelivery"

    if Code.ensure_loaded?(module),
      do: apply(module, :validate, [value]),
      else: {:error, "kanban supervision unavailable"}
  end

  defp board_create(params, cwd, opts) do
    with {:ok, principal} <- principal(opts),
         {:ok, name} <- required_string(params, "name"),
         {:ok, root, workspace} <- board_workspace(params["workspace"], cwd),
         {:ok, meta} <- coding_workflow_meta(params),
         {:ok, delivery} <- validate_delivery(params["deliver_to"]),
         {:ok, authority} <- board_authority(principal, opts, root, meta) do
      meta =
        Map.merge(meta || %{}, %{
          "deliverTo" => delivery,
          "notificationSessionKey" => principal.session_key
        })
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      create_opts =
        []
        |> put_opt(:workspace, workspace)
        |> put_opt(:owner, principal.agent_id)
        |> put_opt(:columns, params["columns"])
        |> put_opt(:meta, meta)
        |> put_opt(:authority, authority)

      case KanbanStore.create_board(name, create_opts) do
        {:ok, board} -> result("created kanban board #{board.id}", %{board: board})
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  defp board_authority(principal, opts, root, meta) do
    publish =
      case meta do
        %{"codingWorkflow" => %{"publish" => %{} = publish}} -> publish
        _ -> nil
      end

    case KanbanAuthority.new(principal, caller_policy(opts), root, publish: publish) do
      {:ok, authority} ->
        {:ok, authority}

      {:error, :publication_not_permitted} ->
        {:error,
         "coding_workflow publish is not permitted: this session's tool policy must allow bash and external access without approval"}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  # The authorized root is the session cwd; the board workspace is that root or
  # an existing directory inside it, both canonical (symlinks resolved).
  defp board_workspace(path, cwd) do
    with {:ok, root} <- KanbanAuthority.canonical_directory(Path.expand(cwd)),
         {:ok, workspace} <- workspace_in(path, root) do
      {:ok, root, workspace}
    else
      _ ->
        {:error, "workspace must be an existing directory within the session working directory"}
    end
  end

  defp workspace_in(path, root) when path in [nil, ""], do: {:ok, root}

  defp workspace_in(path, root) when is_binary(path) do
    path = if Path.type(path) == :absolute, do: path, else: Path.join(root, path)

    with {:ok, workspace} <- KanbanAuthority.canonical_directory(path),
         true <- KanbanAuthority.within?(workspace, root) do
      {:ok, workspace}
    else
      _ -> {:error, :outside}
    end
  end

  defp workspace_in(_path, _root), do: {:error, :invalid}

  defp coding_workflow_meta(params) do
    case Map.fetch(params, "coding_workflow") do
      :error ->
        {:ok, nil}

      {:ok, settings} ->
        module = :"Elixir.LemonAutomation.KanbanGitWorkflow"

        cond do
          not (Code.ensure_loaded?(module) and function_exported?(module, :normalize, 1)) ->
            {:error, "kanban coding workflow unavailable"}

          not (is_map(settings) or settings == false) ->
            {:error, "coding_workflow must be an object or false"}

          is_map(settings) and not string_key_settings?(settings) ->
            {:error, "coding_workflow settings must use string keys"}

          true ->
            case apply(module, :normalize, [settings]) do
              {:ok, _runtime_config} -> {:ok, %{"codingWorkflow" => settings}}
              {:error, reason} -> {:error, format_error(reason)}
            end
        end
    end
  end

  defp string_key_settings?(settings) do
    Enum.all?(settings, fn {key, value} ->
      is_binary(key) and (not is_map(value) or string_key_settings?(value))
    end)
  end

  defp board_get(params, opts) do
    with {:ok, board_id} <- required_string(params, "board_id"),
         {:ok, board} <- authorized_board(board_id, opts) do
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

  defp task_list(params, opts) do
    with {:ok, board_id} <- required_string(params, "board_id"),
         {:ok, _board} <- authorized_board(board_id, opts) do
      filters =
        []
        |> put_opt(:status, params["status"])
        |> put_opt(:assignee, params["assignee"])
        |> put_opt(:limit, params["limit"])

      result("kanban tasks", %{tasks: KanbanStore.list_tasks(board_id, filters)})
    end
  end

  defp task_get(params, opts) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, task} <- authorized_task(task_id, opts) do
      result("kanban task #{task.id}", %{task: task})
    end
  end

  defp task_create(params, opts) do
    with {:ok, board_id} <- required_string(params, "board_id"),
         {:ok, title} <- required_string(params, "title"),
         {:ok, _board} <- authorized_board(board_id, opts),
         {:ok, assignee} <- caller_assignee(params, opts) do
      create_opts =
        []
        |> put_opt(:description, params["description"])
        |> put_opt(:status, params["status"])
        |> put_opt(:priority, params["priority"])
        |> put_opt(:assignee, assignee || caller_agent(opts))
        |> put_opt(:depends_on, params["depends_on"])
        |> put_opt(:dispatch_policy, caller_policy(opts))

      case KanbanStore.create_task(board_id, title, create_opts) do
        {:ok, task} -> result("created kanban task #{task.id}", %{task: task})
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  defp task_update(params, opts) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, _task} <- authorized_task(task_id, opts),
         {:ok, assignee} <- caller_assignee(params, opts) do
      attrs =
        %{}
        |> put_attr(:title, params["title"])
        |> put_attr(:description, params["description"])
        |> put_attr(:status, params["status"])
        |> put_attr(:priority, params["priority"])
        |> put_attr(:assignee, assignee)
        |> put_attr(:depends_on, params["depends_on"])

      update_opts = put_opt([], :dispatch_policy, caller_policy(opts))

      case KanbanStore.update_task(task_id, attrs, update_opts) do
        {:ok, task} -> result("updated kanban task #{task.id}", %{task: task})
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  defp task_comment(params, opts) do
    with {:ok, task_id} <- required_string(params, "task_id"),
         {:ok, body} <- required_string(params, "body"),
         {:ok, _task} <- authorized_task(task_id, opts) do
      comment_opts =
        []
        |> put_opt(:author, params["author"] || caller_agent(opts))

      case KanbanStore.add_comment(task_id, body, comment_opts) do
        {:ok, task} -> result("commented on kanban task #{task.id}", %{task: task})
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  # Routing identity comes from the invoking session, never from tool params.
  defp reject_caller_derived(params) do
    case Enum.find(@caller_derived, &(Map.get(params, &1) not in [nil, ""])) do
      nil -> :ok
      key -> {:error, "#{key} is derived from the calling session and cannot be set"}
    end
  end

  defp caller_agent(opts), do: Keyword.get(opts, :agent_id) || "default"

  # The trusted session principal; without a session identity nothing is allowed.
  defp principal(opts) do
    case Keyword.get(opts, :session_key) do
      session_key when is_binary(session_key) and session_key != "" ->
        {:ok, %{agent_id: caller_agent(opts), session_key: session_key}}

      _ ->
        {:error, "kanban requires a trusted session identity"}
    end
  end

  # The invoking session's effective tool policy; nil only for an unrestricted caller.
  defp caller_policy(opts) do
    context_policy =
      case Keyword.get(opts, :execution_context) do
        %{tool_policy: policy} -> policy
        _ -> nil
      end

    case Enum.reject([Keyword.get(opts, :tool_policy), context_policy], &is_nil/1) do
      [] ->
        nil

      [policy] ->
        policy

      [policy, context_policy] ->
        case ToolPolicy.restrict(policy, context_policy) do
          {:ok, restricted} -> restricted
          {:error, _} -> ToolPolicy.deny_all()
        end
    end
  end

  defp caller_assignee(params, opts) do
    case params["assignee"] do
      value when value in [nil, ""] ->
        {:ok, nil}

      value ->
        if value == caller_agent(opts),
          do: {:ok, value},
          else: {:error, "assignee must be the calling agent #{caller_agent(opts)}"}
    end
  end

  # Missing, quarantined and other principals' boards are indistinguishable.
  defp authorized_board(board_id, opts) do
    with {:ok, principal} <- principal(opts) do
      case KanbanStore.get_board(board_id) do
        board when map_size(board) > 0 ->
          if permitted?(board, principal), do: {:ok, board}, else: unauthorized(board_id)

        _ ->
          unauthorized(board_id)
      end
    end
  end

  defp authorized_task(task_id, opts) do
    case KanbanStore.get_task(task_id) do
      task when map_size(task) > 0 ->
        with {:ok, _board} <- authorized_board(task.board_id, opts), do: {:ok, task}

      _ ->
        {:error, "kanban task #{task_id} is not available or not authorized for this session"}
    end
  end

  defp permitted?(board, principal) do
    case KanbanAuthority.fetch(board) do
      {:ok, authority} -> KanbanAuthority.permits?(authority, principal)
      {:error, _} -> false
    end
  end

  defp unauthorized(board_id),
    do: {:error, "kanban board #{board_id} is not available or not authorized for this session"}

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

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default

  defp result(title, details) do
    %AgentToolResult{
      content: [%TextContent{type: :text, text: Jason.encode!(details, pretty: true)}],
      details: Map.put(details, :title, title)
    }
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
