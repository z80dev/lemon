defmodule LemonRouter.RunOrchestrator do
  @moduledoc """
  Orchestrates run submission and lifecycle.

  The orchestrator is responsible for:
  - Resolving agent configuration
  - Merging tool policies
  - Selecting engine/model
  - Building gateway jobs
  - Starting runs under DynamicSupervisor
  - Subscribing to and routing gateway events
  """

  use GenServer

  require Logger

  alias LemonRouter.{Policy, SessionKey, RunProcess}
  alias LemonGateway.EngineRegistry
  alias AgentCore.CliRunners.Types.ResumeToken, as: CliResume

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Submit a run request.

  ## Parameters

  - `:origin` - Source of the request (:channel, :control_plane, :cron, :node)
  - `:session_key` - Session key for routing
  - `:agent_id` - Agent identifier
  - `:prompt` - User prompt text
  - `:queue_mode` - Queue mode (:collect, :followup, :steer, :steer_backlog, :interrupt)
  - `:engine_id` - Optional engine override
  - `:meta` - Additional metadata

  ## Returns

  `{:ok, run_id}` on success, `{:error, reason}` on failure.
  """
  @spec submit(map()) :: {:ok, binary()} | {:error, term()}
  def submit(params) do
    GenServer.call(__MODULE__, {:submit, params})
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:submit, params}, _from, state) do
    result = do_submit(params)
    {:reply, result, state}
  end

  defp do_submit(params) do
    origin = params[:origin] || :unknown
    session_key = params[:session_key]
    agent_id = params[:agent_id] || SessionKey.agent_id(session_key) || "default"
    prompt = params[:prompt]
    queue_mode = params[:queue_mode] || :collect
    engine_id = params[:engine_id]
    meta = params[:meta] || %{}

    # Extract cwd and tool_policy overrides from params
    cwd_override = params[:cwd]
    tool_policy_override = params[:tool_policy]

    # Generate run_id
    run_id = LemonCore.Id.run_id()

    # Get session policies (includes model, thinkingLevel, and tool_policy)
    session_config = get_session_config(session_key)

    # Resolve base tool policy from agent/session/channel
    base_tool_policy =
      Policy.resolve_for_run(%{
        agent_id: agent_id,
        session_key: session_key,
        origin: origin,
        channel_context: meta[:channel_context]
      })

    # Merge in operator-provided tool_policy override
    # Operator overrides take highest precedence
    tool_policy =
      if tool_policy_override && is_map(tool_policy_override) do
        Policy.merge(base_tool_policy, tool_policy_override)
      else
        base_tool_policy
      end

    # Resolve cwd: operator override > meta cwd > nil
    cwd = cwd_override || meta[:cwd]

    # Extract explicit resume token from prompt or reply-to (Telegram) context.
    # If a resume token is present, prefer its engine and strip strict resume lines
    # from the prompt so we don't send `codex resume ...` as the user prompt.
    {resume, prompt} = extract_resume_and_strip_prompt(prompt, meta)

    # Resolve engine_id: explicit param > session config model > nil
    # Session config can set model which maps to engine_id
    resolved_engine_id =
      cond do
        match?(%LemonGateway.Types.ResumeToken{}, resume) ->
          # Resume must win; otherwise scheduler won't apply the resume token.
          resume.engine

        true ->
          engine_id || resolve_engine_from_session(session_config)
      end

    # Resolve thinking_level from session config
    thinking_level = session_config[:thinking_level] || session_config["thinking_level"]

    # Backward compatibility: a lot of legacy gateway code and tests still expect
    # `job.text`, `job.engine_hint`, and (for Telegram) `job.scope/user_msg_id`.
    legacy_scope = legacy_scope_from_meta(meta)
    legacy_user_msg_id = meta[:user_msg_id] || meta["user_msg_id"]

    # Build gateway job
    job = %LemonGateway.Types.Job{
      run_id: run_id,
      session_key: session_key,
      prompt: prompt,
      text: prompt,
      engine_id: resolved_engine_id,
      engine_hint: resolved_engine_id,
      cwd: cwd,
      resume: resume,
      queue_mode: queue_mode,
      lane: meta[:lane] || :main,
      tool_policy: tool_policy,
      scope: legacy_scope,
      user_msg_id: legacy_user_msg_id,
      meta:
        Map.merge(meta, %{
          origin: origin,
          agent_id: agent_id,
          thinking_level: thinking_level,
          model: session_config[:model] || session_config["model"]
        })
    }

    # Start run process
    case start_run_process(run_id, session_key, job) do
      {:ok, _pid} ->
        # Subscribe control-plane EventBridge to run events for WS delivery
        subscribe_event_bridge(run_id)

        # Emit telemetry
        LemonCore.Telemetry.run_submit(session_key, origin, engine_id || "default")
        {:ok, run_id}

      {:error, reason} ->
        Logger.error("Failed to start run process: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp start_run_process(run_id, session_key, job) do
    spec = {RunProcess, %{run_id: run_id, session_key: session_key, job: job}}

    case DynamicSupervisor.start_child(LemonRouter.RunSupervisor, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Subscribe the control-plane EventBridge to run events for WS delivery
  defp subscribe_event_bridge(run_id) do
    if Code.ensure_loaded?(LemonControlPlane.EventBridge) do
      LemonControlPlane.EventBridge.subscribe_run(run_id)
    end
  rescue
    _ -> :ok
  end

  # Get session configuration from store (includes model, thinking_level, tool_policy)
  defp get_session_config(nil), do: %{}

  defp get_session_config(session_key) do
    case LemonCore.Store.get(:session_policies, session_key) do
      nil -> %{}
      config when is_map(config) -> config
    end
  rescue
    _ -> %{}
  end

  # Resolve engine_id from session config's model setting
  defp resolve_engine_from_session(nil), do: nil

  defp resolve_engine_from_session(config) when is_map(config) do
    model = config[:model] || config["model"]

    if model do
      # Map common model names to engine_ids
      # This allows sessions.patch to set model: "claude-3-opus" etc.
      map_model_to_engine(model)
    else
      nil
    end
  end

  # Map model name to engine ID
  # This provides a flexible mapping layer between user-friendly model names
  # and internal engine identifiers
  defp map_model_to_engine(model) when is_binary(model) do
    # Check if it's already an engine_id format
    if String.contains?(model, ":") do
      model
    else
      # Map common model names to engine formats
      case String.downcase(model) do
        "claude-3-opus" -> "claude:claude-3-opus"
        "claude-3-sonnet" -> "claude:claude-3-sonnet"
        "claude-3-haiku" -> "claude:claude-3-haiku"
        "claude-3.5-sonnet" -> "claude:claude-3-5-sonnet"
        "gpt-4" -> "openai:gpt-4"
        "gpt-4-turbo" -> "openai:gpt-4-turbo"
        "gpt-4o" -> "openai:gpt-4o"
        "gpt-3.5-turbo" -> "openai:gpt-3.5-turbo"
        # Default: pass through as-is (might be a valid engine_id)
        _ -> model
      end
    end
  end

  defp map_model_to_engine(_), do: nil

  defp legacy_scope_from_meta(meta) when is_map(meta) do
    channel_id = meta[:channel_id] || meta["channel_id"]

    if channel_id == "telegram" do
      chat_id =
        cond do
          is_integer(meta[:chat_id]) -> meta[:chat_id]
          is_integer(meta["chat_id"]) -> meta["chat_id"]
          is_binary(meta[:chat_id]) -> parse_int(meta[:chat_id])
          is_binary(meta["chat_id"]) -> parse_int(meta["chat_id"])
          is_map(meta[:peer]) -> parse_int(meta[:peer][:id] || meta[:peer]["id"])
          is_map(meta["peer"]) -> parse_int(meta["peer"][:id] || meta["peer"]["id"])
          true -> nil
        end

      topic_id =
        cond do
          is_integer(meta[:topic_id]) -> meta[:topic_id]
          is_integer(meta["topic_id"]) -> meta["topic_id"]
          is_binary(meta[:topic_id]) -> parse_int(meta[:topic_id])
          is_binary(meta["topic_id"]) -> parse_int(meta["topic_id"])
          is_map(meta[:peer]) -> parse_int(meta[:peer][:thread_id] || meta[:peer]["thread_id"])
          is_map(meta["peer"]) -> parse_int(meta["peer"][:thread_id] || meta["peer"]["thread_id"])
          true -> nil
        end

      if is_integer(chat_id) do
        %LemonGateway.Types.ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id}
      else
        nil
      end
    end
  rescue
    _ -> nil
  end

  defp legacy_scope_from_meta(_), do: nil

  defp parse_int(nil), do: nil

  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp extract_resume_and_strip_prompt(prompt, meta) do
    prompt = prompt || ""

    reply_to_text =
      meta[:reply_to_text] || meta["reply_to_text"] ||
        get_in(meta, [:raw, "message", "reply_to_message", "text"]) ||
        get_in(meta, [:raw, "message", "reply_to_message", "caption"])

    resume =
      cond do
        Code.ensure_loaded?(EngineRegistry) ->
          case EngineRegistry.extract_resume(prompt) do
            {:ok, token} -> token
            :none ->
              if is_binary(reply_to_text) and reply_to_text != "" do
                case EngineRegistry.extract_resume(reply_to_text) do
                  {:ok, token} -> token
                  :none -> nil
                end
              end
          end

        true ->
          nil
      end

    stripped = strip_strict_resume_lines(prompt)

    stripped =
      if stripped == "" and not is_nil(resume) do
        # Many CLIs require a prompt even when resuming.
        "Continue."
      else
        stripped
      end

    {resume, stripped}
  rescue
    _ -> {nil, prompt}
  end

  defp strip_strict_resume_lines(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reject(fn line -> CliResume.is_resume_line(line) end)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp strip_strict_resume_lines(_), do: ""
end
