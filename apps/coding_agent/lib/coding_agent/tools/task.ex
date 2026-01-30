defmodule CodingAgent.Tools.Task do
  @moduledoc """
  Task tool for the coding agent.

  Spawns a new CodingAgent session to run a focused subtask and returns the
  final assistant response.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent
  alias CodingAgent.Coordinator
  alias CodingAgent.Session
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
    subagent_enum = build_subagent_enum(cwd)

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
          "subagent" => %{
            "type" => "string",
            "description" => "Optional subagent type to specialize the task"
          }
        },
        "required" => ["description", "prompt"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
    |> maybe_add_enum(subagent_enum)
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
    description = Map.get(params, "description") || "Task"
    prompt = Map.get(params, "prompt", "")
    subagent_id = Map.get(params, "subagent")
    coordinator = Keyword.get(opts, :coordinator)

    if prompt == "" do
      {:error, "Prompt is required"}
    else
      # Route through coordinator if available and running, otherwise use direct session
      if coordinator && coordinator_alive?(coordinator) && subagent_id do
        execute_via_coordinator(coordinator, prompt, description, subagent_id)
      else
        start_opts = build_session_opts(cwd, opts)

        case maybe_apply_subagent_prompt(prompt, subagent_id, cwd) do
          {:error, _} = err ->
            err

          prompt ->
            start_session_with_prompt(
              start_opts,
              prompt,
              description,
              signal,
              on_update,
              subagent_id
            )
        end
      end
    end
  end

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

  defp execute_via_coordinator(coordinator, prompt, description, subagent_id) do
    # Generate a unique ID for tracking this subagent
    subagent_run_id = generate_subagent_id()

    case Coordinator.run_subagent(coordinator,
           prompt: prompt,
           subagent: subagent_id,
           description: description
         ) do
      {:ok, result_text} ->
        %AgentToolResult{
          content: [%TextContent{text: result_text}],
          details: %{
            subagent_run_id: subagent_run_id,
            description: description,
            status: "completed",
            subagent: subagent_id,
            via_coordinator: true
          }
        }

      {:error, {status, error}} ->
        {:error, "Subagent #{status}: #{inspect(error)}"}

      {:error, reason} ->
        {:error, "Coordinator error: #{inspect(reason)}"}
    end
  end

  defp generate_subagent_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp start_session_with_prompt(start_opts, prompt, description, signal, on_update, subagent_id) do
    with {:ok, session} <- CodingAgent.start_session(start_opts) do
      session_id = Session.get_stats(session).session_id
      unsubscribe = Session.subscribe(session)

      try do
        case Session.prompt(session, prompt) do
          :ok ->
            case await_result(session, session_id, signal, on_update, description, "", "", subagent_id) do
              {:ok, %{text: text, thinking: thinking}} ->
                %AgentToolResult{
                  content: build_update_content(text, thinking),
                  details: %{
                    session_id: session_id,
                    description: description,
                    status: "completed",
                    subagent: subagent_id
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

  defp maybe_apply_subagent_prompt(prompt, nil, _cwd), do: prompt
  defp maybe_apply_subagent_prompt(prompt, "", _cwd), do: prompt

  defp maybe_apply_subagent_prompt(prompt, subagent_id, cwd) do
    case Subagents.get(cwd, subagent_id) do
      nil ->
        {:error, "Unknown subagent: #{subagent_id}"}

      agent ->
        agent.prompt <> "\n\n" <> prompt
    end
  end

  defp build_description(cwd) do
    base =
      "Run a focused subtask in a fresh agent session and return the final response."

    subagents = Subagents.format_for_description(cwd)

    if subagents == "" do
      base
    else
      base <> "\n\nAvailable subagents:\n" <> subagents
    end
  end

  defp build_subagent_enum(cwd) do
    ids = Subagents.list(cwd) |> Enum.map(& &1.id)
    if ids == [], do: nil, else: ids
  end

  defp maybe_add_enum(%AgentTool{} = tool, nil), do: tool

  defp maybe_add_enum(%AgentTool{} = tool, enum) do
    params = tool.parameters
    props = params["properties"] || %{}
    subagent = Map.get(props, "subagent", %{})
    subagent = Map.put(subagent, "enum", enum)
    props = Map.put(props, "subagent", subagent)
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
         subagent_id
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
            subagent_id
          )
        await_result(session, session_id, signal, on_update, description, last_text, last_thinking, subagent_id)

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
            subagent_id
          )
        await_result(session, session_id, signal, on_update, description, last_text, last_thinking, subagent_id)

      {:session_event, ^session_id, {:agent_end, messages}} ->
        {:ok, extract_final_payload(messages, last_text, last_thinking)}

      {:session_event, ^session_id, {:error, reason, _partial_state}} ->
        {:error, reason}

      {:session_event, ^session_id, _event} ->
        await_result(session, session_id, signal, on_update, description, last_text, last_thinking, subagent_id)
    after
      200 ->
        if AbortSignal.aborted?(signal) do
          Session.abort(session)
          {:error, "Task aborted"}
        else
          await_result(session, session_id, signal, on_update, description, last_text, last_thinking, subagent_id)
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
         _subagent_id
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
         subagent_id
       ) do
    if (text != "" or thinking != "") and (text != last_text or thinking != last_thinking) do
      on_update.(%AgentToolResult{
        content: build_update_content(text, thinking),
        details: %{
          session_id: session_id,
          description: description,
          status: "running",
          subagent: subagent_id
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
