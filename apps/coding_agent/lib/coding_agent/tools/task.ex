defmodule CodingAgent.Tools.Task do
  @moduledoc """
  Task tool for the coding agent.

  Spawns a new CodingAgent session to run a focused subtask and returns the
  final assistant response.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.CliRunners.{ClaudeSubagent, CodexSubagent}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent
  alias CodingAgent.Coordinator
  alias CodingAgent.Session
  alias CodingAgent.SettingsManager
  alias CodingAgent.Subagents

  @doc """
  Returns the Task tool definition.

  ## Options

  - `:model` - Model to use for the subtask session
  - `:thinking_level` - Thinking level for the subtask session
  - `:parent_session` - Parent session ID for lineage tracking
  - `:coordinator` - Optional Coordinator pid/name to use for subagent execution
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    description = build_description(cwd)
    role_enum = build_role_enum(cwd)

    %AgentTool{
      name: "task",
      description: description,
      label: "Run Task",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "description" => %{
            "type" => "string",
            "description" => "Short (3-5 words) description of the task"
          },
          "prompt" => %{
            "type" => "string",
            "description" => "The task for the agent to perform"
          },
          "engine" => %{
            "type" => "string",
            "description" => "Execution engine: internal (default), codex, or claude"
          },
          "role" => %{
            "type" => "string",
            "description" => "Optional role to specialize the task (e.g., research, implement, review, test)"
          }
        },
        "required" => ["description", "prompt"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
    |> maybe_add_enum(role_enum)
  end

  @doc """
  Execute the task tool.

  Spawns a new session, forwards the prompt, streams partial assistant text via
  `on_update`, and returns the final assistant output.
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, on_update, cwd, opts) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      do_execute(params, signal, on_update, cwd, opts)
    end
  end

  defp do_execute(params, signal, on_update, cwd, opts) do
    with {:ok, validated} <- validate_params(params, cwd) do
      description = validated.description
      prompt = validated.prompt
      role_id = validated.role_id
      engine = validated.engine
      coordinator = Keyword.get(opts, :coordinator)

      cond do
        engine in ["codex", "claude"] ->
          apply_cli_settings(engine, cwd)
          execute_via_cli_engine(engine, prompt, cwd, description, role_id, on_update, signal)

        coordinator && coordinator_alive?(coordinator) && role_id ->
          execute_via_coordinator(coordinator, prompt, description, role_id)

        true ->
          start_opts = build_session_opts(cwd, opts)

          case maybe_apply_role_prompt(prompt, role_id, cwd) do
            {:error, _} = err ->
              err

            prompt ->
              start_session_with_prompt(
                start_opts,
                prompt,
                description,
                signal,
                on_update,
                role_id
              )
          end
      end
    end
  end

  defp validate_params(params, cwd) do
    description = Map.get(params, "description")
    prompt = Map.get(params, "prompt")
    role_id = normalize_optional_string(Map.get(params, "role"))
    engine = Map.get(params, "engine")

    cond do
      not Map.has_key?(params, "description") ->
        {:error, "Description is required"}

      not is_binary(description) or String.trim(description) == "" ->
        {:error, "Description must be a non-empty string"}

      not Map.has_key?(params, "prompt") ->
        {:error, "Prompt is required"}

      is_nil(prompt) ->
        {:error, "Prompt must be a non-empty string"}

      not is_binary(prompt) or String.trim(prompt) == "" ->
        {:error, "Prompt must be a non-empty string"}

      not is_nil(role_id) and not is_binary(role_id) ->
        {:error, "Role must be a string"}

      not is_nil(engine) and not is_binary(engine) ->
        {:error, "Engine must be a string"}

      not is_nil(engine) and engine not in ["internal", "codex", "claude"] ->
        {:error, "Engine must be one of: internal, codex, claude"}

      not is_nil(role_id) and Subagents.get(cwd, role_id) == nil ->
        {:error, "Unknown role: #{role_id}"}

      true ->
        normalized_engine = if engine == "internal", do: nil, else: engine

        {:ok,
         %{
           description: description,
           prompt: prompt,
           role_id: role_id,
           engine: normalized_engine
         }}
    end
  end

  defp normalize_optional_string(nil), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(value), do: value

  defp coordinator_alive?(coordinator) when is_pid(coordinator), do: Process.alive?(coordinator)

  defp coordinator_alive?(coordinator) when is_atom(coordinator) do
    case Process.whereis(coordinator) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp coordinator_alive?({:via, _, _} = name) do
    case GenServer.whereis(name) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp coordinator_alive?(_), do: false

  defp execute_via_coordinator(coordinator, prompt, description, role_id) do
    # Generate a unique ID for tracking this task run
    task_run_id = generate_task_run_id()

    case Coordinator.run_subagent(coordinator,
           prompt: prompt,
           subagent: role_id,
           description: description
         ) do
      {:ok, result_text} ->
        %AgentToolResult{
          content: [%TextContent{text: result_text}],
          details: %{
            task_run_id: task_run_id,
            description: description,
            status: "completed",
            role: role_id,
            via_coordinator: true
          }
        }

      {:error, {status, error}} ->
        {:error, "Task #{status}: #{inspect(error)}"}

      {:error, reason} ->
        {:error, "Coordinator error: #{inspect(reason)}"}
    end
  end

  defp execute_via_cli_engine(engine, prompt, cwd, description, role_id, on_update, signal) do
    {module, engine_label} =
      case engine do
        "codex" -> {CodexSubagent, "codex"}
        "claude" -> {ClaudeSubagent, "claude"}
      end

    # Get role prompt if role_id is specified
    role_prompt = if role_id, do: get_role_prompt(cwd, role_id), else: nil

    with {:ok, session} <- module.start(prompt: prompt, cwd: cwd, role_prompt: role_prompt) do
      abort_monitor = maybe_start_abort_monitor(signal, session.pid)
      result = reduce_cli_events(module.events(session), description, engine_label, on_update, signal)
      maybe_stop_abort_monitor(abort_monitor)

      details = %{
        description: description,
        status: if(result.error, do: "error", else: "completed"),
        engine: engine_label,
        role: role_id,
        resume_token: result.resume_token,
        error: result.error,
        stderr: result[:stderr]
      }

      tool_result = %AgentToolResult{
        content: [%TextContent{text: result.answer || ""}],
        details: details
      }

      if result.error do
        # Include stderr in error message if available and different from error
        error_msg = format_cli_error(result.error)
        error_msg =
          if result[:stderr] && result[:stderr] != "" && result[:stderr] != result.error do
            "#{error_msg}\nstderr: #{result[:stderr]}"
          else
            error_msg
          end

        {:error, %{message: error_msg, details: details, answer: result.answer || ""}}
      else
        tool_result
      end
    end
  end

  defp apply_cli_settings("codex", cwd) do
    settings = SettingsManager.load(cwd)
    codex = Map.get(settings, :codex, %{})

    config = if is_map(codex), do: codex, else: %{}
    Application.put_env(:agent_core, :codex, config)
  end

  defp apply_cli_settings(_engine, _cwd), do: :ok

  defp maybe_start_abort_monitor(nil, _pid), do: nil

  defp maybe_start_abort_monitor(signal, pid) when is_reference(signal) and is_pid(pid) do
    spawn(fn -> abort_monitor_loop(signal, pid) end)
  end

  defp maybe_start_abort_monitor(_signal, _pid), do: nil

  defp maybe_stop_abort_monitor(nil), do: :ok

  defp maybe_stop_abort_monitor(pid) when is_pid(pid) do
    send(pid, :stop)
    :ok
  end

  defp maybe_emit_cli_update(on_update, description, engine, status, text, extra_details \\ %{})

  defp maybe_emit_cli_update(nil, _description, _engine, _status, _text, _extra_details), do: :ok

  defp maybe_emit_cli_update(on_update, description, engine, status, text, extra_details) do
    details =
      %{
        description: description,
        status: status,
        engine: engine
      }
      |> Map.merge(extra_details)

    on_update.(%AgentToolResult{
      content: [%TextContent{text: text}],
      details: details
    })
  end

  @doc false
  def reduce_cli_events(events, description, engine_label, on_update) do
    reduce_cli_events(events, description, engine_label, on_update, nil)
  end

  @doc false
  def reduce_cli_events(events, description, engine_label, on_update, signal) do
    Enum.reduce_while(events, %{answer: nil, resume_token: nil, error: nil, stderr: nil}, fn
      {:started, token}, acc ->
        maybe_emit_cli_update(on_update, description, engine_label, "started", token.value)
        {:cont, %{acc | resume_token: token}}

      {:action, %{title: title, kind: kind} = _action, :started, _opts}, acc ->
        # Emit update for action started phase with rich details
        maybe_emit_cli_update(
          on_update,
          description,
          engine_label,
          "running",
          title,
          %{
            current_action: %{title: title, kind: to_string(kind), phase: "started"}
          }
        )

        {:cont, acc}

      {:action, %{title: title, detail: detail, kind: kind} = _action, :updated, _opts}, acc ->
        # Emit update for action progress with any available detail text
        text = extract_action_detail_text(detail) || title

        extra_details =
          %{
            current_action: %{title: title, kind: to_string(kind), phase: "updated"}
          }
          |> maybe_add_action_detail(detail)

        maybe_emit_cli_update(on_update, description, engine_label, "running", text, extra_details)

        {:cont, acc}

      {:action, %{title: title, detail: detail, kind: kind}, :completed, _opts}, acc ->
        maybe_emit_cli_update(
          on_update,
          description,
          engine_label,
          "running",
          "Completed: #{title}",
          %{
            current_action: %{title: title, kind: to_string(kind), phase: "completed"}
          }
        )

        acc =
          if kind == :warning and is_map(detail) do
            cond do
              Map.has_key?(detail, :stderr) ->
                stderr = detail[:stderr] || detail.stderr
                # Capture stderr for debugging even if we already have an error
                acc = %{acc | stderr: stderr}
                if acc.error == nil, do: %{acc | error: stderr}, else: acc

              Map.has_key?(detail, :decode_error) ->
                if acc.error == nil, do: %{acc | error: detail.decode_error}, else: acc

              true ->
                acc
            end
          else
            acc
          end

        {:cont, acc}

      {:completed, answer, opts}, acc ->
        resume = opts[:resume] || acc.resume_token
        error = acc.error || opts[:error]
        {:cont, %{acc | answer: answer, resume_token: resume, error: error}}

      {:error, reason}, acc ->
        maybe_emit_cli_update(on_update, description, engine_label, "error", format_cli_error(reason))
        {:cont, %{acc | error: acc.error || reason}}

      _, acc ->
        {:cont, acc}
    end)
    |> maybe_apply_abort(signal)
  end

  defp maybe_apply_abort(result, signal) do
    if AbortSignal.aborted?(signal) do
      %{result | error: result.error || "Task aborted"}
    else
      result
    end
  end

  defp extract_action_detail_text(detail) when is_map(detail) do
    cond do
      is_binary(Map.get(detail, :message)) -> Map.get(detail, :message)
      is_binary(Map.get(detail, "message")) -> Map.get(detail, "message")
      is_binary(Map.get(detail, :output)) -> Map.get(detail, :output)
      is_binary(Map.get(detail, "output")) -> Map.get(detail, "output")
      is_binary(Map.get(detail, :stdout)) -> Map.get(detail, :stdout)
      is_binary(Map.get(detail, "stdout")) -> Map.get(detail, "stdout")
      is_binary(Map.get(detail, :stderr)) -> Map.get(detail, :stderr)
      is_binary(Map.get(detail, "stderr")) -> Map.get(detail, "stderr")
      is_binary(Map.get(detail, :result)) -> Map.get(detail, :result)
      is_binary(Map.get(detail, "result")) -> Map.get(detail, "result")
      true -> nil
    end
  end

  defp extract_action_detail_text(_detail), do: nil

  defp maybe_add_action_detail(details, detail) when is_map(detail) and map_size(detail) > 0 do
    Map.put(details, :action_detail, detail)
  end

  defp maybe_add_action_detail(details, _detail), do: details

  defp abort_monitor_loop(signal, pid) do
    receive do
      :stop ->
        :ok
    after
      200 ->
        if AbortSignal.aborted?(signal) do
          Process.exit(pid, :kill)
          :ok
        else
          abort_monitor_loop(signal, pid)
        end
    end
  end

  defp format_cli_error(reason) when is_binary(reason), do: reason
  defp format_cli_error(reason), do: inspect(reason)

  defp generate_task_run_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp start_session_with_prompt(start_opts, prompt, description, signal, on_update, role_id) do
    with {:ok, session} <- CodingAgent.start_session(start_opts) do
      session_id = Session.get_stats(session).session_id
      unsubscribe = Session.subscribe(session)

      try do
        case Session.prompt(session, prompt) do
          :ok ->
            case await_result(session, session_id, signal, on_update, description, "", "", role_id) do
              {:ok, %{text: text, thinking: thinking}} ->
                %AgentToolResult{
                  content: build_update_content(text, thinking),
                  details: %{
                    session_id: session_id,
                    description: description,
                    status: "completed",
                    role: role_id
                  }
                }

              {:error, reason} ->
                {:error, reason}
            end

          {:error, :already_streaming} ->
            {:error, "Task session is already running"}
        end
      after
        if is_function(unsubscribe, 0) do
          unsubscribe.()
        end

        stop_session(session)
      end
    else
      {:error, reason} ->
        {:error, "Failed to start task session: #{inspect(reason)}"}
    end
  end

  defp maybe_apply_role_prompt(prompt, nil, _cwd), do: prompt
  defp maybe_apply_role_prompt(prompt, "", _cwd), do: prompt

  defp maybe_apply_role_prompt(prompt, role_id, cwd) do
    case Subagents.get(cwd, role_id) do
      nil ->
        {:error, "Unknown role: #{role_id}"}

      role ->
        role.prompt <> "\n\n" <> prompt
    end
  end

  defp get_role_prompt(cwd, role_id) do
    case Subagents.get(cwd, role_id) do
      nil -> nil
      role -> role.prompt
    end
  end

  defp build_description(cwd) do
    base =
      "Run a focused subtask and return the final response.\n\n" <>
        "Parameters:\n" <>
        "- engine: Which executor runs the task\n" <>
        "  - \"internal\" (default): Lemon's built-in agent\n" <>
        "  - \"codex\": OpenAI Codex CLI\n" <>
        "  - \"claude\": Claude Code CLI\n" <>
        "- role: Optional specialization that applies to ANY engine\n\n" <>
        "The role prepends a system prompt to focus the executor on a specific type of work. " <>
        "You can combine any engine with any role."

    roles = Subagents.format_for_description(cwd)

    if roles == "" do
      base
    else
      base <> "\n\nAvailable roles:\n" <> roles
    end
  end

  defp build_role_enum(cwd) do
    ids = Subagents.list(cwd) |> Enum.map(& &1.id)
    if ids == [], do: nil, else: ids
  end

  defp maybe_add_enum(%AgentTool{} = tool, nil), do: tool

  defp maybe_add_enum(%AgentTool{} = tool, enum) do
    params = tool.parameters
    props = params["properties"] || %{}
    role = Map.get(props, "role", %{})
    role = Map.put(role, "enum", enum)
    props = Map.put(props, "role", role)
    %{tool | parameters: Map.put(params, "properties", props)}
  end

  defp build_session_opts(cwd, opts) do
    base_opts =
      opts
      |> Keyword.take([
        :model,
        :thinking_level,
        :system_prompt,
        :prompt_template,
        :get_api_key,
        :stream_fn,
        :stream_options,
        :settings_manager,
        :ui_context,
        :parent_session
      ])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    [{:cwd, cwd}, {:register, true} | base_opts]
  end

  defp await_result(
         session,
         session_id,
         signal,
         on_update,
         description,
         last_text,
         last_thinking,
         role_id
       ) do
    receive do
      {:session_event, ^session_id, {:message_update, %Ai.Types.AssistantMessage{} = msg, _event}} ->
        text = Ai.get_text(msg)
        thinking = Ai.get_thinking(msg)
        {last_text, last_thinking} =
          maybe_emit_update(
            on_update,
            text,
            thinking,
            last_text,
            last_thinking,
            description,
            session_id,
            role_id
          )
        await_result(session, session_id, signal, on_update, description, last_text, last_thinking, role_id)

      {:session_event, ^session_id, {:message_end, %Ai.Types.AssistantMessage{} = msg}} ->
        text = Ai.get_text(msg)
        thinking = Ai.get_thinking(msg)
        {last_text, last_thinking} =
          maybe_emit_update(
            on_update,
            text,
            thinking,
            last_text,
            last_thinking,
            description,
            session_id,
            role_id
          )
        await_result(session, session_id, signal, on_update, description, last_text, last_thinking, role_id)

      {:session_event, ^session_id, {:agent_end, messages}} ->
        {:ok, extract_final_payload(messages, last_text, last_thinking)}

      {:session_event, ^session_id, {:error, reason, _partial_state}} ->
        {:error, reason}

      {:session_event, ^session_id, _event} ->
        await_result(session, session_id, signal, on_update, description, last_text, last_thinking, role_id)
    after
      200 ->
        if AbortSignal.aborted?(signal) do
          Session.abort(session)
          {:error, "Task aborted"}
        else
          await_result(session, session_id, signal, on_update, description, last_text, last_thinking, role_id)
        end
    end
  end

  defp extract_final_payload(messages, fallback_text, fallback_thinking) do
    messages
    |> Enum.filter(&match?(%Ai.Types.AssistantMessage{}, &1))
    |> List.last()
    |> case do
      nil ->
        %{text: fallback_text || "", thinking: fallback_thinking || ""}

      msg ->
        %{text: Ai.get_text(msg), thinking: Ai.get_thinking(msg)}
    end
  end

  defp maybe_emit_update(
         nil,
         _text,
         _thinking,
         last_text,
         last_thinking,
         _description,
         _session_id,
         _role_id
       ) do
    {last_text, last_thinking}
  end

  defp maybe_emit_update(
         on_update,
         text,
         thinking,
         last_text,
         last_thinking,
         description,
         session_id,
         role_id
       ) do
    if (text != "" or thinking != "") and (text != last_text or thinking != last_thinking) do
      on_update.(%AgentToolResult{
        content: build_update_content(text, thinking),
        details: %{
          session_id: session_id,
          description: description,
          status: "running",
          role: role_id
        }
      })
    end

    {text, thinking}
  end

  defp build_update_content(text, thinking) do
    text = text || ""
    thinking = truncate_thinking(thinking || "")

    base =
      if text != "" do
        [%TextContent{text: text}]
      else
        []
      end

    if thinking != "" do
      prefix = if text != "", do: "\n[thinking] ", else: "[thinking] "
      base ++ [%TextContent{text: prefix <> thinking}]
    else
      base
    end
  end

  defp truncate_thinking(thinking) do
    max_len = 240
    trimmed = String.trim(thinking)

    if trimmed == "" do
      ""
    else
      if String.length(trimmed) > max_len do
        "..." <> String.slice(trimmed, -max_len, max_len)
      else
        trimmed
      end
    end
  end

  defp stop_session(session) when is_pid(session) do
    try do
      if Process.whereis(CodingAgent.SessionSupervisor) do
        _ = CodingAgent.SessionSupervisor.stop_session(session)
      else
        GenServer.stop(session, :normal, 5_000)
      end
    rescue
      _ -> :ok
    end

    :ok
  end
end
