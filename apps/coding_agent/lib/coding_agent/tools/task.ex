defmodule CodingAgent.Tools.Task do
  @moduledoc """
  Task tool for the coding agent.

  Spawns a new CodingAgent session to run a focused subtask and returns the
  final assistant response.
  """

  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias CodingAgent.Tools.Task.{Control, Execution, Messaging, Params, Result, Swarm, Wait}

  @doc """
  Returns the Task tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    description = Params.build_description(cwd, opts)
    agent_enum = Params.build_agent_enum(cwd, opts)

    %AgentTool{
      name: "task",
      description: description,
      label: "Run Task",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "description" => "Default: run",
            "enum" => [
              "run",
              "swarm",
              "poll",
              "join",
              "wait",
              "get",
              "message",
              "steer",
              "cancel"
            ]
          },
          "concurrency" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 32,
            "description" => "Active swarm limit; default 8, also subject to global/budget caps"
          },
          "name" => %{
            "type" => "string",
            "description" =>
              "Messaging alias: 1-64 ASCII letters/digits/_/-, starting with a letter; unique in batch"
          },
          "to" => %{
            "type" => "string",
            "description" => "Message address: agent://<name-or-id>, parent, or all"
          },
          "description" => %{
            "type" => "string",
            "description" => "Short task label"
          },
          "prompt" => %{
            "type" => "string",
            "description" => "Child assignment"
          },
          "context" => %{
            "type" => "string",
            "maxLength" => 65_536,
            "description" =>
              "Shared background for run/tasks[]/swarm (top-level only); each child receives " <>
                "<context>…</context> then its prompt inside <assignment>…</assignment>"
          },
          "message" => %{
            "type" => "string",
            "description" => "Peer input delivered at the next steering boundary"
          },
          "worktree" => %{
            "type" => "boolean",
            "description" => "Run in an isolated git worktree from HEAD"
          },
          "merge" => %{
            "type" => "string",
            "enum" => ["none", "patch", "branch"],
            "description" =>
              "Worktree merge-back on success: patch applies to this checkout, branch keeps a review commit; default [runtime.task].worktree_merge"
          },
          "task_id" => %{
            "type" => "string",
            "description" => "Target for poll/get/message/steer/cancel"
          },
          "task_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Targets for join/wait"
          },
          "mode" => %{
            "type" => "string",
            "enum" => ["wait_all", "wait_any"],
            "description" => "Join mode; default wait_all"
          },
          "model" => %{
            "type" => "string",
            "description" => "Model or @role; omitted uses persona/task defaults, then parent"
          },
          "thinking_level" => %{
            "type" => "string",
            "description" => "Thinking level override"
          },
          "agent" => %{
            "type" => "string",
            "description" =>
              "Persona: scout/reviewer are read-only; task-executor or discovered definitions"
          },
          "output_schema" => %{
            "type" => ["object", "boolean"],
            "description" =>
              "Final JSON Schema (default: persona output). Invalid output is re-prompted up to twice; " <>
                "valid data becomes structured_output"
          },
          "schema_mode" => %{
            "type" => "string",
            "enum" => ["strict", "permissive"],
            "description" =>
              "strict (default) fails on invalid output after retries; permissive returns text plus structured_output_error"
          },
          "async" => %{
            "type" => "boolean",
            "description" => "Default/recommended true: return receipt immediately; false waits"
          },
          "auto_followup" => %{
            "type" => "boolean",
            "description" => "Default true: deliver completion back to this session"
          },
          "cwd" => %{
            "type" => "string",
            "description" => "Child working directory"
          },
          "tool_policy" => %{
            "type" => "object",
            "description" => "Child tool policy; cannot widen read-only personas"
          },
          "meta" => %{
            "type" => "object",
            "description" => "Lifecycle/followup metadata"
          },
          "session_key" => %{
            "type" => "string",
            "description" => "Parent session routing override"
          },
          "agent_id" => %{
            "type" => "string",
            "description" => "Parent agent routing override"
          },
          "queue_mode" => %{
            "type" => "string",
            "enum" => Params.valid_queue_modes(),
            "description" => "Followup delivery queue; default followup"
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
    |> Params.maybe_add_enum(agent_enum)
    |> add_batch_schema()
  end

  @doc """
  Execute the task tool.
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(tool_call_id, params, signal, on_update, cwd, opts) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      case Params.normalize_action(Map.get(params, "action")) do
        "swarm" ->
          opts = Params.with_settings(cwd, opts)

          with :ok <- Params.check_spawn_depth(cwd, opts) do
            Swarm.execute(tool_call_id, params, signal, on_update, cwd, opts)
          end

        "wait" ->
          Wait.execute(params, signal, opts)

        action when action in ["message", "steer"] ->
          Messaging.send(params["to"] || params["task_id"], params["message"], opts)

        action when action in ["poll", "join", "get", "cancel"] ->
          with :ok <- authorize_action(action, params, opts) do
            case action do
              "poll" -> Result.do_poll(params)
              "join" -> Result.do_join(params, signal)
              "get" -> Result.do_get(params)
              "cancel" -> cancel_child(params, opts)
            end
          end

        "run" ->
          opts = Params.with_settings(cwd, opts)

          with :ok <- Params.check_spawn_depth(cwd, opts) do
            if Map.has_key?(params, "tasks"),
              do: run_batch(tool_call_id, params, signal, on_update, cwd, opts),
              else: do_execute(tool_call_id, params, signal, on_update, cwd, opts)
          end

        _ ->
          {:error, "Unknown task action"}
      end
    end
  end

  defp do_execute(tool_call_id, params, signal, on_update, cwd, opts) do
    with {:ok, validated} <- Params.validate_run_params(params, cwd, opts),
         {:ok, validated} <- Params.restrict_to_parent(validated, cwd, opts),
         :ok <- Params.check_budget_and_policy(validated, opts) do
      Execution.run(tool_call_id, validated, signal, on_update, cwd, opts)
    end
  end

  defp add_batch_schema(tool) do
    child_properties =
      Map.take(tool.parameters["properties"], [
        "description",
        "name",
        "prompt",
        "agent",
        "output_schema",
        "schema_mode",
        "model",
        "thinking_level",
        "async",
        "cwd",
        "worktree",
        "merge",
        "tool_policy"
      ])
      |> Map.put("depends_on", %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Swarm prerequisite names; all must succeed before this node starts"
      })

    tasks = %{
      "type" => "array",
      "minItems" => 1,
      "maxItems" => 32,
      "description" =>
        "Children inherit top-level options (context is top-level only). Swarm nodes require unique names; depends_on defines their DAG.",
      "items" => %{"type" => "object", "properties" => child_properties, "required" => ["prompt"]}
    }

    %{tool | parameters: put_in(tool.parameters, ["properties", "tasks"], tasks)}
  end

  defp authorize_action(action, params, opts) do
    ids =
      if action == "join",
        do: Map.get(params, "task_ids") || Map.get(params, "task_id"),
        else: Map.get(params, "task_id")

    ids = if is_binary(ids), do: [ids], else: ids

    if is_list(ids) and ids != [] and Enum.all?(ids, &is_binary/1) do
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        case Control.authorize(id, opts) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      # Let the action's existing validator explain malformed IDs.
      :ok
    end
  end

  defp cancel_child(params, opts) do
    case Map.get(params, "task_id") do
      id when is_binary(id) ->
        with :ok <- Control.command(id, "cancel", nil, opts) do
          %AgentToolResult{
            content: [%LemonAi.Types.TextContent{text: "Cancellation requested: #{id}"}],
            details: %{task_id: id, status: "cancelling"}
          }
        end

      _ ->
        {:error, "task_id is required"}
    end
  end

  defp run_batch(tool_call_id, params, signal, on_update, cwd, opts) do
    tasks = params["tasks"]

    cond do
      not (is_list(tasks) and length(tasks) in 1..32 and Enum.all?(tasks, &is_map/1)) ->
        {:error, "tasks must contain 1 to 32 task objects"}

      Enum.any?(tasks, &Map.has_key?(&1, "context")) ->
        {:error, "context is only supported at the top level, not per task"}

      true ->
        launch_batch(tool_call_id, tasks, params, signal, on_update, cwd, opts)
    end
  end

  defp launch_batch(tool_call_id, tasks, params, signal, on_update, cwd, opts) do
    defaults = Map.drop(params, ["tasks", "action"])

    validated =
      Enum.map(tasks, fn task ->
        child = Map.merge(defaults, task)

        child =
          if Map.get(child, "async", true) == false,
            do: Map.put(child, "auto_followup", false),
            else: child

        Params.validate_run_params(child, cwd, opts)
      end)

    with nil <- Enum.find(validated, &match?({:error, _}, &1)),
         :ok <- unique_task_names(validated) do
      results =
        Enum.map(validated, fn {:ok, child} ->
          with {:ok, child} <- Params.restrict_to_parent(child, cwd, opts),
               :ok <- Params.check_budget_and_policy(child, opts) do
            Execution.run(tool_call_id, %{child | async: true}, signal, on_update, cwd, opts)
          end
        end)

      receipts =
        Enum.zip_with(results, validated, fn result, {:ok, child} ->
          details =
            case result do
              %AgentToolResult{details: details} -> details
              {:error, reason} -> %{status: "error", error: reason}
            end

          Map.put(details, :async, child.async)
        end)

      task_ids = for %{task_id: id} <- receipts, do: id

      sync_ids = for %{task_id: id, async: false} <- receipts, do: id
      background = Enum.filter(receipts, & &1.async)

      if sync_ids != [] do
        case Result.do_join(%{"task_ids" => sync_ids}, signal) do
          %AgentToolResult{} = result ->
            content =
              if background == [],
                do: result.content,
                else:
                  result.content ++
                    [
                      %LemonAi.Types.TextContent{
                        text: "Background tasks: " <> Jason.encode!(background)
                      }
                    ]

            %{
              result
              | content: content,
                details: Map.merge(result.details, %{launches: receipts, task_ids: task_ids})
            }

          error ->
            error
        end
      else
        %AgentToolResult{
          content: [%LemonAi.Types.TextContent{text: Jason.encode!(%{tasks: receipts})}],
          details: %{tasks: receipts, task_ids: task_ids, status: "queued"}
        }
      end
    else
      {:error, _} = error -> error
    end
  end

  defp unique_task_names(validated) do
    names = for {:ok, %{name: name}} <- validated, not is_nil(name), do: name

    if length(names) == length(Enum.uniq(names)),
      do: :ok,
      else: {:error, "Task names must be unique within a batch"}
  end
end
