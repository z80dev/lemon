defmodule LemonChannels.GoalStatusMessage do
  @moduledoc """
  `/goal` chat commands.

  The transport supplies trusted context only: the chat session (the
  `session_key` argument), `:agent_id`, the bound workspace (`:workspace`) and
  the channel context used to resolve the chat's run tool policy
  (`:channel_context`). `set` records the chat as the goal principal, the
  chat's effective channel-run policy (`LemonRouter.Policy`, including the
  group approval floor) and the bound workspace (or the assistant home) as the
  goal authority (`LemonAgent.Workspace.GoalAuthority`). `continue`,
  `loop once` and `loop start` pass the same chat authority as the starter:
  the goal must belong to this chat and agent and its target must lie inside
  the chat's workspace, and the recorded authority is durably narrowed to it.
  Without trusted channel context the chat cannot set or start goal work.
  """

  alias LemonAgent.Workspace.GoalAuthority

  @spec handle(binary(), binary() | nil, keyword()) :: String.t()
  def handle(session_key, args, opts \\ []) when is_binary(session_key) do
    case parse_args(args) do
      {:set, objective, budget} ->
        set_text(session_key, objective, Keyword.put(opts, :budget, budget))

      {:continue, command_opts} ->
        with_chat_starter(session_key, opts, fn opts ->
          continue_text(session_key, Keyword.merge(opts, command_opts))
        end)

      {:loop_once, command_opts} ->
        with_chat_starter(session_key, opts, fn opts ->
          loop_once_text(session_key, Keyword.merge(opts, command_opts))
        end)

      {:loop_start, command_opts} ->
        with_chat_starter(session_key, opts, fn opts ->
          loop_start_text(session_key, Keyword.merge(opts, command_opts))
        end)

      :loop_status ->
        loop_status_text(session_key, opts)

      :loop_stop ->
        loop_stop_text(session_key, opts)

      :pause ->
        pause_text(session_key, opts)

      :resume ->
        resume_text(session_key, opts)

      :clear ->
        clear_text(session_key, opts)

      :status ->
        status_text(session_key)

      :help ->
        help_text()
    end
  end

  @spec status_text(binary()) :: String.t()
  def status_text(session_key) when is_binary(session_key) do
    case LemonAgent.Workspace.GoalStore.get(session_key) do
      %{} = goal when map_size(goal) == 0 ->
        Enum.join(
          [
            "Goal Status",
            "State: none",
            "Set one with /goal set <objective>."
          ],
          "\n"
        )

      goal ->
        goal_lines(goal)
    end
  end

  @spec set_text(binary(), binary(), keyword()) :: String.t()
  def set_text(session_key, objective, opts \\ [])
      when is_binary(session_key) and is_binary(objective) do
    with {:ok, authority} <- chat_authority(session_key, opts),
         {:ok, goal} <-
           call_module(loop_module(opts), :set_goal, [
             session_key,
             objective,
             opts
             |> Keyword.take([:agent_id, :budget, :meta])
             |> Keyword.put(:authority, authority)
           ]) do
      Enum.join(
        [
          "Goal Set",
          "Status: #{goal.status}",
          "Goal id: #{goal.id}",
          "Objective bytes: #{byte_size(goal.objective || "")}",
          budget_line(goal),
          "Use /goal continue or /goal loop once for supervised follow-up."
        ]
        |> Enum.reject(&is_nil/1),
        "\n"
      )
    else
      {:error, :empty_objective} ->
        "Goal objective is required. Use /goal set <objective>."

      {:error, :already_running} ->
        "Goal has active or unresolved work. Stop it with /goal loop stop before replacing it."

      {:error, :policy_unavailable} ->
        "Goal update failed: this chat's tool policy is unavailable."

      {:error, :session_identity_required} ->
        "Goal update failed: this chat has no trusted session identity."

      {:error, reason}
      when reason in [:enoent, :not_a_directory, :relative_path, :invalid_path] ->
        "Goal update failed: this chat's working directory is unavailable."

      {:error, reason} ->
        "Goal update failed: #{inspect(reason)}"
    end
  end

  # The chat's goal authority: this chat session and agent as principal, the
  # chat's channel-run policy and its bound workspace (or the assistant home).
  defp chat_authority(session_key, opts) do
    with {:ok, policy} <- chat_policy(session_key, opts) do
      GoalAuthority.new(
        %{agent_id: opts[:agent_id], session_key: session_key},
        policy,
        opts[:workspace] || LemonCore.Cwd.channel_default_cwd(),
        granted_by: "channel"
      )
    end
  end

  defp with_chat_starter(session_key, opts, fun) do
    case chat_authority(session_key, opts) do
      {:ok, starter} ->
        fun.(Keyword.put(opts, :starter, starter))

      {:error, :policy_unavailable} ->
        "Goal work refused: this chat's tool policy is unavailable."

      {:error, _reason} ->
        "Goal work refused: this chat has no trusted session identity or working directory."
    end
  end

  # The chat's effective channel-run policy, resolved exactly as the router
  # resolves a run from this chat. Missing context or resolution fails closed.
  defp chat_policy(session_key, opts) do
    module = :"Elixir.LemonRouter.Policy"

    with %{} = context <- opts[:channel_context],
         true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :resolve_validated_for_run, 1),
         {:ok, policy} <-
           apply(module, :resolve_validated_for_run, [
             %{
               session_key: session_key,
               origin: :channel,
               channel_context: context
             }
           ]) do
      {:ok, policy}
    else
      _ -> {:error, :policy_unavailable}
    end
  end

  @spec clear_text(binary(), keyword()) :: String.t()
  def clear_text(session_key, opts \\ []) when is_binary(session_key) do
    case LemonAgent.Workspace.GoalStore.clear(session_key, opts) do
      :ok -> "Goal cleared."
      {:error, reason} -> "Goal clear failed: #{inspect(reason)}"
    end
  end

  @spec pause_text(binary(), keyword()) :: String.t()
  def pause_text(session_key, opts \\ []) when is_binary(session_key) do
    case LemonAgent.Workspace.GoalStore.pause(session_key, opts) do
      {:ok, goal} -> transition_text("Goal Paused", goal)
      {:error, :not_found} -> "No goal is set for this session."
      {:error, reason} -> "Goal pause failed: #{inspect(reason)}"
    end
  end

  @spec resume_text(binary(), keyword()) :: String.t()
  def resume_text(session_key, opts \\ []) when is_binary(session_key) do
    case LemonAgent.Workspace.GoalStore.resume(session_key, opts) do
      {:ok, goal} -> transition_text("Goal Resumed", goal)
      {:error, :not_found} -> "No goal is set for this session."
      {:error, reason} -> "Goal resume failed: #{inspect(reason)}"
    end
  end

  @doc """
  Submits one continuation off the caller's process and returns the
  acknowledgement at once. The result (run id or refusal) is handed to the
  transport's `:deliver` callback from a task started with `:start_task`.
  """
  @spec continue_text(binary(), keyword()) :: String.t()
  def continue_text(session_key, opts \\ []) when is_binary(session_key) do
    run_off_transport("Goal Continuation Queued", opts, fn ->
      args = [session_key, Keyword.put(automation_opts(opts), :verdict, :continue)]

      case call_module(loop_module(opts), :run_once, args) do
        {:ok, %{run_id: run_id, goal: goal}} ->
          goal_run_text("Goal Continuation Submitted", goal, run_id)

        {:error, :not_found} ->
          "No goal is set for this session."

        {:error, reason} ->
          "Goal continuation failed: #{inspect(reason)}"
      end
    end)
  end

  @doc "Runs one judge tick off the caller's process; see `continue_text/2`."
  @spec loop_once_text(binary(), keyword()) :: String.t()
  def loop_once_text(session_key, opts \\ []) when is_binary(session_key) do
    run_off_transport("Goal Loop Tick Queued", opts, fn ->
      case call_module(loop_module(opts), :run_once, [session_key, automation_opts(opts)]) do
        {:ok, %{run_id: run_id, goal: goal, verdict: verdict}} ->
          goal_loop_tick_text(goal, run_id, verdict)

        {:error, :not_found} ->
          "No goal is set for this session."

        {:error, reason} ->
          "Goal loop tick failed: #{inspect(reason)}"
      end
    end)
  end

  # The judge and continuation can take minutes and may wait on an approval in
  # this same chat, so they never run in the transport process. A crash or call
  # timeout is reported as an unknown outcome and never retried.
  defp run_off_transport(title, opts, work) do
    deliver = opts[:deliver]
    start_task = opts[:start_task]

    with true <- is_function(deliver, 1) and is_function(start_task, 1),
         {:ok, _pid} <- start_task.(fn -> deliver.(guarded_work(work)) end) do
      Enum.join([title, "The result will be posted here when it is ready."], "\n")
    else
      _ -> "Goal work unavailable: this chat cannot run goal work in the background."
    end
  end

  defp guarded_work(work) do
    work.()
  rescue
    _ -> unknown_outcome_text()
  catch
    _, _ -> unknown_outcome_text()
  end

  defp unknown_outcome_text do
    "Goal work outcome unknown: the goal service did not answer in time. " <>
      "It may still be running and was not retried. Check /goal loop status."
  end

  @spec loop_start_text(binary(), keyword()) :: String.t()
  def loop_start_text(session_key, opts \\ []) when is_binary(session_key) do
    case call_module(loop_module(opts), :start_loop, [session_key, automation_opts(opts)]) do
      {:ok, loop} ->
        loop_text("Goal Loop Started", loop)

      {:error, :not_found} ->
        "No goal is set for this session."

      {:error, reason} ->
        "Goal loop start failed: #{inspect(reason)}"
    end
  end

  @spec loop_status_text(binary(), keyword()) :: String.t()
  def loop_status_text(session_key, opts \\ []) when is_binary(session_key) do
    case call_module(loop_module(opts), :status, [session_key]) do
      {:ok, %{running: running, loop: loop, goal: goal}} ->
        Enum.join(
          [
            "Goal Loop Status",
            "Running: #{running}",
            loop && "Loop status: #{field(loop, :status) || "unknown"}",
            loop && "Max ticks: #{field(loop, :max_ticks) || "unknown"}",
            auto_line(loop_status_auto(goal)),
            goal_line(goal)
          ]
          |> Enum.reject(&is_nil/1),
          "\n"
        )

      {:error, reason} ->
        "Goal loop status failed: #{inspect(reason)}"
    end
  end

  @spec loop_stop_text(binary(), keyword()) :: String.t()
  def loop_stop_text(session_key, opts \\ []) when is_binary(session_key) do
    case call_module(loop_module(opts), :stop_loop, [session_key]) do
      {:ok, %{loop: loop, goal: goal}} ->
        Enum.join(
          [
            loop_text("Goal Loop Stopped", loop),
            goal_line(goal)
          ]
          |> Enum.reject(&is_nil/1),
          "\n"
        )

      {:error, :not_running} ->
        "No goal loop is running for this session."

      {:error, reason} ->
        "Goal loop stop failed: #{inspect(reason)}"
    end
  end

  defp parse_args(args) when is_binary(args) do
    trimmed = String.trim(args)
    lowered = String.downcase(trimmed)

    cond do
      trimmed == "" or trimmed == "status" ->
        :status

      lowered == "pause" ->
        :pause

      lowered == "resume" ->
        :resume

      lowered == "clear" ->
        :clear

      lowered == "continue" or String.starts_with?(lowered, "continue ") ->
        {:continue, parse_command_opts(command_rest(trimmed))}

      lowered == "loop status" ->
        :loop_status

      lowered == "loop stop" ->
        :loop_stop

      lowered == "loop once" or String.starts_with?(lowered, "loop once ") ->
        {:loop_once, parse_command_opts(command_rest(trimmed, ["loop", "once"]))}

      lowered == "loop start" or String.starts_with?(lowered, "loop start ") ->
        {:loop_start, parse_command_opts(command_rest(trimmed, ["loop", "start"]))}

      String.starts_with?(lowered, "set ") ->
        parse_set_args(trimmed |> String.split(~r/\s+/, parts: 2) |> List.last())

      true ->
        :help
    end
  end

  defp parse_args(_), do: :status

  defp command_rest(trimmed, drop_tokens \\ nil) do
    tokens = String.split(trimmed, ~r/\s+/, trim: true)
    drop_count = if drop_tokens, do: length(drop_tokens), else: 1
    tokens |> Enum.drop(drop_count) |> Enum.join(" ")
  end

  defp parse_command_opts(args) do
    args
    |> String.split(~r/\s+/, trim: true)
    |> parse_command_tokens([])
  end

  defp parse_command_tokens([], opts), do: Enum.reverse(opts)

  defp parse_command_tokens(["--auto" | rest], opts) do
    parse_command_tokens(rest, [{:auto, true} | opts])
  end

  defp parse_command_tokens(["--max-continuations=" <> value | rest], opts) do
    parse_command_tokens(rest, put_integer_opt(opts, :max_continuations, value, :non_negative))
  end

  defp parse_command_tokens(["--max-continuations", value | rest], opts) do
    parse_command_tokens(rest, put_integer_opt(opts, :max_continuations, value, :non_negative))
  end

  defp parse_command_tokens(["--max", value | rest], opts) do
    parse_command_tokens(rest, put_integer_opt(opts, :max_continuations, value, :non_negative))
  end

  defp parse_command_tokens(["--max-ticks=" <> value | rest], opts) do
    parse_command_tokens(rest, put_integer_opt(opts, :max_ticks, value, :positive))
  end

  defp parse_command_tokens(["--max-ticks", value | rest], opts) do
    parse_command_tokens(rest, put_integer_opt(opts, :max_ticks, value, :positive))
  end

  defp parse_command_tokens(["--interval-ms=" <> value | rest], opts) do
    parse_command_tokens(rest, put_integer_opt(opts, :interval_ms, value, :non_negative))
  end

  defp parse_command_tokens(["--interval-ms", value | rest], opts) do
    parse_command_tokens(rest, put_integer_opt(opts, :interval_ms, value, :non_negative))
  end

  defp parse_command_tokens(["--wait-timeout-ms=" <> value | rest], opts) do
    parse_command_tokens(rest, put_integer_opt(opts, :wait_timeout_ms, value, :positive))
  end

  defp parse_command_tokens(["--wait-timeout-ms", value | rest], opts) do
    parse_command_tokens(rest, put_integer_opt(opts, :wait_timeout_ms, value, :positive))
  end

  defp parse_command_tokens(["--judge-model=" <> value | rest], opts) do
    parse_command_tokens(rest, put_string_opt(opts, :judge_model, value))
  end

  defp parse_command_tokens(["--judge-model", value | rest], opts) do
    parse_command_tokens(rest, put_string_opt(opts, :judge_model, value))
  end

  defp parse_command_tokens(["--judge-failure-policy=" <> value | rest], opts) do
    parse_command_tokens(rest, put_policy_opt(opts, value))
  end

  defp parse_command_tokens(["--judge-failure-policy", value | rest], opts) do
    parse_command_tokens(rest, put_policy_opt(opts, value))
  end

  defp parse_command_tokens(["--model=" <> value | rest], opts) do
    parse_command_tokens(rest, put_string_opt(opts, :model, value))
  end

  defp parse_command_tokens(["--model", value | rest], opts) do
    parse_command_tokens(rest, put_string_opt(opts, :model, value))
  end

  defp parse_command_tokens([_token | rest], opts), do: parse_command_tokens(rest, opts)

  defp parse_set_args(args) do
    {tokens, budget} =
      args
      |> String.split(~r/\s+/, trim: true)
      |> parse_set_tokens([], %{})

    {:set, Enum.join(tokens, " "), budget}
  end

  defp parse_set_tokens([], acc, budget), do: {Enum.reverse(acc), budget}

  defp parse_set_tokens(["--max-continuations=" <> value | rest], acc, budget) do
    parse_set_tokens(rest, acc, put_max_continuations(budget, value))
  end

  defp parse_set_tokens(["--max-continuations", value | rest], acc, budget) do
    parse_set_tokens(rest, acc, put_max_continuations(budget, value))
  end

  defp parse_set_tokens(["--max", value | rest], acc, budget) do
    parse_set_tokens(rest, acc, put_max_continuations(budget, value))
  end

  defp parse_set_tokens([token | rest], acc, budget) do
    parse_set_tokens(rest, [token | acc], budget)
  end

  defp goal_lines(goal) do
    Enum.join(
      [
        "Goal Status",
        "State: #{goal.status}",
        "Goal id: #{goal.id}",
        "Objective bytes: #{byte_size(goal.objective || "")}",
        budget_line(goal),
        loop_line(goal),
        loop_auto_line(goal),
        "Continuations: #{goal.continuation_count || 0}",
        "Last run: #{goal.last_run_id || "none"}"
      ]
      |> Enum.reject(&is_nil/1),
      "\n"
    )
  end

  defp transition_text(title, goal) do
    Enum.join(
      [
        title,
        "Status: #{goal.status}",
        "Goal id: #{goal.id}",
        "Objective bytes: #{byte_size(goal.objective || "")}",
        budget_line(goal),
        "Continuations: #{goal.continuation_count || 0}"
      ]
      |> Enum.reject(&is_nil/1),
      "\n"
    )
  end

  defp help_text do
    Enum.join(
      [
        "Goal Commands",
        "/goal - show current goal status",
        "/goal set [--max-continuations N] <objective> - set the current session goal",
        "/goal pause - pause the current session goal",
        "/goal resume - resume the current session goal",
        "/goal continue [--max-continuations N] - submit one continuation",
        "/goal loop once - run one judge tick",
        "/goal loop start [--auto] [--max-ticks N] - start a bounded loop",
        "/goal loop status - show loop status",
        "/goal loop stop - stop a bounded loop",
        "/goal clear - clear the current session goal"
      ],
      "\n"
    )
  end

  defp put_max_continuations(budget, value) do
    case Integer.parse(value || "") do
      {integer, ""} when integer >= 0 -> Map.put(budget, "max_continuations", integer)
      _ -> budget
    end
  end

  defp put_integer_opt(opts, key, value, mode) do
    case Integer.parse(value || "") do
      {integer, ""} when integer >= 0 and mode == :non_negative -> [{key, integer} | opts]
      {integer, ""} when integer > 0 and mode == :positive -> [{key, integer} | opts]
      _ -> opts
    end
  end

  defp put_string_opt(opts, key, value) do
    value = String.trim(value || "")
    if value == "", do: opts, else: [{key, value} | opts]
  end

  defp put_policy_opt(opts, value) do
    case value do
      "continue_once" -> [{:judge_failure_policy, :continue_once} | opts]
      "continueOnce" -> [{:judge_failure_policy, :continue_once} | opts]
      "needs_input" -> [{:judge_failure_policy, :needs_input} | opts]
      "needsInput" -> [{:judge_failure_policy, :needs_input} | opts]
      "pause" -> [{:judge_failure_policy, :pause} | opts]
      _ -> opts
    end
  end

  defp automation_opts(opts) do
    opts
    |> Keyword.take([
      :max_continuations,
      :max_ticks,
      :interval_ms,
      :wait_timeout_ms,
      :judge_model,
      :judge_failure_policy,
      :model,
      :auto,
      :starter
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp goal_run_text(title, goal, run_id) do
    Enum.join(
      [
        title,
        goal && "Status: #{field(goal, :status) || "unknown"}",
        goal && "Goal id: #{field(goal, :id) || "unknown"}",
        goal && "Objective bytes: #{objective_bytes(goal)}",
        goal && "Continuations: #{field(goal, :continuation_count) || 0}",
        run_id && "Run id: #{run_id}"
      ]
      |> Enum.reject(&is_nil/1),
      "\n"
    )
  end

  defp goal_loop_tick_text(goal, run_id, verdict) do
    Enum.join(
      [
        goal_run_text("Goal Loop Tick", goal, run_id),
        "Verdict: #{field(verdict, :action) || "unknown"}",
        "Reason: #{field(verdict, :reason) || ""}"
      ],
      "\n"
    )
  end

  defp loop_text(title, loop) do
    Enum.join(
      [
        title,
        "Loop status: #{field(loop, :status) || "unknown"}",
        "Max ticks: #{field(loop, :max_ticks) || "unknown"}"
      ],
      "\n"
    )
  end

  defp goal_line(%{} = goal) when map_size(goal) > 0 do
    "Goal: #{field(goal, :status) || "unknown"} / #{field(goal, :continuation_count) || 0} continuations"
  end

  defp goal_line(_), do: nil

  defp budget_line(goal) do
    case max_continuations(goal.budget) do
      nil -> nil
      value -> "Max continuations: #{value}"
    end
  end

  defp loop_line(goal) do
    loop = (goal.meta || %{})["goalLoop"] || (goal.meta || %{})[:goalLoop] || %{}
    status = loop["status"] || loop[:status]

    if is_binary(status) and status != "" do
      "Loop: #{status}"
    end
  end

  defp loop_auto_line(goal), do: auto_line(loop_status_auto(goal))

  defp loop_status_auto(goal) do
    meta = field(goal, :meta) || %{}
    loop = meta["goalLoop"] || meta[:goalLoop] || %{}

    case loop["auto"] || loop[:auto] do
      %{} = auto -> auto
      _ -> %{"enabled" => false}
    end
  end

  defp auto_line(%{} = auto) do
    if auto["enabled"] == true or auto[:enabled] == true do
      "Auto loop: enabled"
    end
  end

  defp max_continuations(%{} = budget) do
    budget["max_continuations"] || budget[:max_continuations]
  end

  defp max_continuations(_), do: nil

  defp objective_bytes(goal) do
    case field(goal, :objective) do
      objective when is_binary(objective) -> byte_size(objective)
      _ -> field(goal, :objective_bytes) || 0
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

  defp call_module(module, function, args) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      _ -> {:error, :not_available}
    end
  end

  defp loop_module(opts) do
    opts[:loop_module] ||
      Application.get_env(
        :lemon_channels,
        :goal_loop_module,
        :"Elixir.LemonAutomation.GoalLoopManager"
      )
  end
end
