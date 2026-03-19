defmodule CodingAgent.Tools.Task do
  @moduledoc """
  Task tool for the coding agent.

  Spawns a new CodingAgent session to run a focused subtask and returns the
  final assistant response.
  """

  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias CodingAgent.Tools.Task.{Execution, Params, Result, Runner}

  @doc """
  Returns the Task tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    description = Params.build_description(cwd)
    role_enum = Params.build_role_enum(cwd)

    %AgentTool{
      name: "task",
      description: description,
      label: "Run Task",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "description" => "Action to perform: run (default), poll, or join",
            "enum" => ["run", "poll", "join"]
          },
          "description" => %{
            "type" => "string",
            "description" => "Short (3-5 words) description of the task"
          },
          "prompt" => %{
            "type" => "string",
            "description" => "The task for the agent to perform"
          },
          "task_id" => %{
            "type" => "string",
            "description" => "Task id to poll (when action=poll)"
          },
          "task_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Task ids to join (when action=join)"
          },
          "mode" => %{
            "type" => "string",
            "enum" => ["wait_all", "wait_any"],
            "description" => "Join mode for action=join (default: wait_all)"
          },
          "engine" => %{
            "type" => "string",
            "description" =>
              "Execution engine: internal (default), codex, claude, kimi, opencode, or pi"
          },
          "model" => %{
            "type" => "string",
            "description" => "Optional model override (especially for internal engine)"
          },
          "thinking_level" => %{
            "type" => "string",
            "description" => "Optional thinking level override for internal engine"
          },
          "role" => %{
            "type" => "string",
            "description" =>
              "Optional role to specialize the task (e.g., research, implement, review, test)"
          },
          "async" => %{
            "type" => "boolean",
            "description" =>
              "When true (recommended), run in background and return task_id immediately. Use async=true by default to keep user conversations responsive. Only use async=false for simple tasks that complete instantly."
          },
          "auto_followup" => %{
            "type" => "boolean",
            "description" =>
              "When true (default), async task completion is automatically posted back into this session."
          },
          "cwd" => %{
            "type" => "string",
            "description" => "Optional working directory override for this task run"
          },
          "tool_policy" => %{
            "type" => "object",
            "description" => "Optional tool policy override for the task session"
          },
          "meta" => %{
            "type" => "object",
            "description" =>
              "Optional metadata map attached to task lifecycle and async followup routing"
          },
          "session_key" => %{
            "type" => "string",
            "description" =>
              "Optional parent session key override used for async followup routing and lifecycle metadata"
          },
          "agent_id" => %{
            "type" => "string",
            "description" =>
              "Optional parent agent id override used for async followup routing and lifecycle metadata"
          },
          "queue_mode" => %{
            "type" => "string",
            "enum" => Params.valid_queue_modes(),
            "description" =>
              "Queue mode for async followup routing via router fallback (default: followup)"
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
    |> Params.maybe_add_enum(role_enum)
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
        "poll" -> Result.do_poll(params)
        "join" -> Result.do_join(params)
        _ -> do_execute(tool_call_id, params, signal, on_update, cwd, opts)
      end
    end
  end

  defp do_execute(tool_call_id, params, signal, on_update, cwd, opts) do
    with {:ok, validated} <- Params.validate_run_params(params, cwd),
         :ok <- Params.check_budget_and_policy(validated, opts) do
      Execution.run(tool_call_id, validated, signal, on_update, cwd, opts)
    end
  end

  @doc false
  def reduce_cli_events(events, description, engine_label, on_update) do
    Runner.reduce_cli_events(events, description, engine_label, on_update)
  end

  @doc false
  def reduce_cli_events(events, description, engine_label, on_update, signal) do
    Runner.reduce_cli_events(events, description, engine_label, on_update, signal)
  end
end
