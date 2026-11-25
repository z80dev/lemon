defmodule LemonAutomation.Tools.Goal do
  @moduledoc """
  Session-scoped durable coding goals. `tool/2` requires the canonical router
  `:session_key` and `:agent_id`; `cwd` is the session working directory.
  Dispatch uses the running `LemonAutomation.GoalLoopManager`, never a
  tool-owned scheduler. `LemonAutomation.Application` contributes the tool
  through `LemonAgent.ToolRegistry`.

  Goal work acts for the calling session, never with more authority: `set`
  records the session as the goal principal, its effective tool policy
  (`:tool_policy` intersected with `:execution_context`) and the canonical
  session cwd as the root (`LemonAutomation.GoalAuthority`). The goal
  target must be an existing directory inside that root. `start` and
  `run_once` pass the same trusted starter authority (session, agent, policy,
  canonical session cwd): the goal must belong to this session and agent and
  its target must lie inside this session's cwd, and the recorded authority is
  durably narrowed to it.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAutomation.{CronDelivery, GoalAuthority, GoalLoopManager, GoalStore}
  alias LemonAi.Types.TextContent
  alias LemonCore.ToolPolicy

  @actions ~w(set status start stop pause resume run_once)

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "goal",
      label: "Goal",
      description:
        "Set a durable coding goal in a repository, then start a bounded judge/work loop. run_once starts one asynchronous tick. status shows run IDs, progress and results. stop or pause cancels owned work and disables auto restart; resume only reactivates a paused goal, then start explicitly. Unknown outcomes retain ownership and cannot be retried until reconciled. Work edits the target repository directly, not an isolated worktree.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => @actions,
            "description" =>
              "set defines the goal; status inspects it; start or run_once dispatch bounded work; stop, pause, and resume control its lifecycle."
          },
          "objective" => %{
            "type" => "string",
            "description" => "Concrete coding objective for set."
          },
          "cwd" => %{
            "type" => "string",
            "description" =>
              "Repository for set: this tool's working directory (default) or a directory inside it."
          },
          "deliver_to" => %{
            "type" => "string",
            "description" =>
              "Supervision destination for set: auto (origin channel or configured owner), none, telegram:chat[:thread], or discord:channel[:thread]."
          },
          "max_ticks" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 20,
            "description" => "Bound on judge/work ticks for start (default 3)."
          },
          "model" => %{
            "type" => "string",
            "description" => "Optional provider:model for start/run_once."
          }
        },
        "required" => ["action"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  def execute(_id, params, signal, _on_update, cwd, opts) do
    with false <- signal != nil and LemonAgent.AbortSignal.aborted?(signal),
         {:ok, session_key} <- session_key(opts),
         {:ok, payload} <- dispatch(params["action"], session_key, params, cwd, opts) do
      details = Map.put(payload, :title, "goal #{params["action"]}")

      %AgentToolResult{
        content: [%TextContent{text: Jason.encode!(details, pretty: true)}],
        details: details,
        trust: :untrusted
      }
    else
      true -> {:error, "goal operation cancelled"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  defp dispatch("set", session_key, params, cwd, opts) do
    with {:ok, objective} <- required_string(params["objective"], "objective"),
         {:ok, authority} <- caller_authority(session_key, cwd, opts),
         {:ok, target} <- target_directory(authority, params["cwd"]),
         {:ok, delivery} <- validate_delivery(params["deliver_to"]),
         {:ok, goal} <-
           manager(fn ->
             GoalLoopManager.set_goal(session_key, objective,
               cwd: target,
               agent_id: opts[:agent_id],
               authority: authority,
               meta: if(delivery, do: %{"deliverTo" => delivery}, else: %{})
             )
           end) do
      {:ok, %{goal: goal}}
    end
  end

  defp dispatch("status", session_key, _params, _cwd, _opts),
    do: manager(fn -> GoalLoopManager.status(session_key) end)

  defp dispatch(action, session_key, params, cwd, opts) when action in ["start", "run_once"] do
    max_ticks = if action == "run_once", do: 1, else: Map.get(params, "max_ticks", 3)

    with true <- is_integer(max_ticks) and max_ticks in 1..20,
         {:ok, _goal} <- fetch_goal(session_key),
         {:ok, starter} <- caller_authority(session_key, cwd, opts),
         {:ok, model_opts} <- model_options(params["model"]),
         {:ok, loop} <-
           manager(fn ->
             GoalLoopManager.start_loop(
               session_key,
               [max_ticks: max_ticks, auto: false, starter: starter] ++ model_opts
             )
           end) do
      {:ok, %{loop: loop, goal: GoalStore.get(session_key)}}
    else
      false -> {:error, "max_ticks must be 1..20"}
      error -> error
    end
  end

  defp dispatch(action, session_key, _params, _cwd, _opts) when action in ["stop", "pause"] do
    with {:ok, _goal} <- fetch_goal(session_key),
         {:ok, stopped} <- stop(session_key) do
      if action == "pause" do
        with {:ok, goal} <- GoalStore.pause(session_key) do
          {:ok, Map.put(stopped, :goal, goal)}
        end
      else
        {:ok, stopped}
      end
    end
  end

  defp dispatch("resume", session_key, _params, _cwd, _opts) do
    with {:ok, %{running: false}} <- manager(fn -> GoalLoopManager.status(session_key) end),
         {:ok, goal} <- fetch_goal(session_key) do
      if goal.status == "paused" do
        with {:ok, goal} <- GoalStore.resume(session_key), do: {:ok, %{goal: goal}}
      else
        {:error, "only a paused goal can be resumed"}
      end
    else
      {:ok, %{running: true}} -> {:error, :already_running}
      error -> error
    end
  end

  defp dispatch(_action, _session_key, _params, _cwd, _opts),
    do: {:error, "unsupported or missing goal action"}

  defp stop(session_key) do
    case manager(fn -> GoalLoopManager.stop_loop(session_key, mode: :hard) end) do
      {:error, :not_running} ->
        with {:ok, _goal} <- GoalStore.configure_loop_auto(session_key, false),
             {:ok, goal} <- GoalStore.record_loop_status(session_key, :stopped) do
          {:ok, %{goal: goal, router_abort: :not_needed}}
        end

      result ->
        result
    end
  end

  defp validate_delivery(nil), do: {:ok, nil}

  defp validate_delivery(value), do: CronDelivery.validate(value)

  # A manager that is not running never received the call; any other exit may
  # follow an accepted mutation, so its outcome is unknown and never retried.
  defp manager(call) do
    call.()
  catch
    :exit, {:noproc, _} -> {:error, :goal_runtime_unavailable}
    :exit, _ -> {:error, :outcome_unknown}
  end

  defp fetch_goal(session_key) do
    case GoalStore.get(session_key) do
      goal when map_size(goal) == 0 -> {:error, :not_found}
      goal -> {:ok, goal}
    end
  end

  defp session_key(opts), do: required_string(opts[:session_key], "session_key in tool context")

  defp caller_authority(session_key, cwd, opts) do
    principal = %{session_key: session_key, agent_id: opts[:agent_id]}

    case GoalAuthority.new(principal, caller_policy(opts), Path.expand(cwd || "")) do
      {:ok, authority} -> {:ok, authority}
      {:error, :session_identity_required} -> {:error, "goal requires a trusted session identity"}
      {:error, _reason} -> {:error, "session working directory is unavailable"}
    end
  end

  defp target_directory(authority, value) do
    case GoalAuthority.target(authority, value) do
      {:ok, target} ->
        {:ok, target}

      {:error, _} ->
        {:error, "cwd must name an existing directory within the session working directory"}
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

  defp model_options(nil), do: {:ok, []}

  defp model_options(value) do
    with {:ok, model} <- required_string(value, "model"), do: {:ok, [model: model]}
  end

  defp required_string(value, name) when is_binary(value) do
    if String.trim(value) == "", do: {:error, "missing #{name}"}, else: {:ok, String.trim(value)}
  end

  defp required_string(_value, name), do: {:error, "missing #{name}"}

  defp error_message(:already_running),
    do: "goal has active or unresolved work; inspect status before retrying"

  defp error_message(:not_found), do: "no goal set for this session"
  defp error_message(:paused), do: "goal is paused; resume before starting"
  defp error_message(:completed), do: "goal is complete; set a new objective before starting"

  defp error_message(:outcome_unknown),
    do: "goal operation outcome unknown; inspect status, do not retry automatically"

  defp error_message(:goal_runtime_unavailable), do: "goal automation runtime unavailable"

  defp error_message(:goal_authority_missing),
    do: "goal has no recorded authority for this session; set it again before starting"

  defp error_message(:workspace_changed),
    do: "goal directory changed or left the session working directory; set the goal again"

  defp error_message(:starter_not_permitted),
    do: "goal belongs to another agent; this session cannot start it"

  defp error_message(:workspace_outside_root),
    do: "goal directory is outside this session's working directory; this session cannot start it"

  defp error_message(_reason), do: "goal operation failed"
end
