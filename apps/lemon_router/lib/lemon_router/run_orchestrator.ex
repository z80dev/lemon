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
  alias LemonCore.RunRequest
  alias LemonGateway.Cwd, as: GatewayCwd
  alias LemonGateway.EngineRegistry
  alias AgentCore.CliRunners.Types.ResumeToken, as: CliResume

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Submit a run request.

  ## Parameters

  Accepts either `%LemonCore.RunRequest{}` or a legacy map with these fields:

  - `:origin` - Source of the request (:channel, :control_plane, :cron, :node)
  - `:session_key` - Session key for routing
  - `:agent_id` - Agent identifier
  - `:prompt` - User prompt text
  - `:queue_mode` - Queue mode (:collect, :followup, :steer, :steer_backlog, :interrupt)
  - `:engine_id` - Optional engine override
  - `:meta` - Additional metadata
  - `:cwd` - Optional cwd override
  - `:tool_policy` - Optional tool policy override

  ## Returns

  `{:ok, run_id}` on success, `{:error, reason}` on failure.
  """
  @spec submit(RunRequest.t() | map()) :: {:ok, binary()} | {:error, term()}
  def submit(%RunRequest{} = request), do: submit(__MODULE__, request)
  def submit(params) when is_map(params), do: submit(__MODULE__, params)

  @doc """
  Submit a run request to a specific orchestrator server.
  """
  @spec submit(GenServer.server(), RunRequest.t() | map()) :: {:ok, binary()} | {:error, term()}
  def submit(server, %RunRequest{} = request), do: GenServer.call(server, {:submit, request})
  def submit(server, params) when is_map(params), do: GenServer.call(server, {:submit, params})

  @doc """
  Lightweight run counts for status UIs.

  `queued` and `completed_today` are placeholders (the router does not own a
  durable queue); `active` reflects current supervised run processes.
  """
  @spec counts() :: %{
          active: non_neg_integer(),
          queued: non_neg_integer(),
          completed_today: non_neg_integer()
        }
  def counts do
    active =
      try do
        %{active: n} = DynamicSupervisor.count_children(LemonRouter.RunSupervisor)
        n
      rescue
        _ -> 0
      end

    %{active: active, queued: 0, completed_today: 0}
  end

  @impl true
  def init(opts) do
    run_process_opts =
      opts
      |> Keyword.get(:run_process_opts, %{})
      |> normalize_run_process_opts()

    state = %{
      run_supervisor: Keyword.get(opts, :run_supervisor, LemonRouter.RunSupervisor),
      run_process_module: Keyword.get(opts, :run_process_module, RunProcess),
      run_process_opts: run_process_opts
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, params}, _from, state) do
    params = RunRequest.normalize(params)
    result = do_submit(params, state)
    {:reply, result, state}
  end

  defp do_submit(%RunRequest{} = params, orchestrator_state) do
    origin = params.origin || :unknown
    session_key = params.session_key
    agent_id = params.agent_id || SessionKey.agent_id(session_key) || "default"
    prompt = params.prompt
    queue_mode = params.queue_mode || :collect
    engine_id = params.engine_id
    meta = params.meta || %{}

    # Extract cwd and tool_policy overrides from params
    cwd_override = params.cwd
    tool_policy_override = params.tool_policy

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

    # Resolve cwd: operator override > meta cwd > gateway default
    cwd = resolve_effective_cwd(cwd_override, meta)

    # Extract explicit resume token from prompt or reply-to (Telegram) context.
    # If a resume token is present, prefer its engine and strip strict resume lines
    # from the prompt so we don't send `codex resume ...` as the user prompt.
    {resume, prompt} = extract_resume_and_strip_prompt(prompt, meta)

    prompt =
      if meta[:voice_transcribed] do
        base = prompt || ""
        "(voice transcribed) " <> base
      else
        prompt
      end

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
    case start_run_process(orchestrator_state, run_id, session_key, job) do
      {:ok, _pid} ->
        # Subscribe control-plane EventBridge to run events for WS delivery
        subscribe_event_bridge(run_id)

        # Emit telemetry
        LemonCore.Telemetry.run_submit(session_key, origin, engine_id || "default")
        {:ok, run_id}

      {:error, reason} ->
        if reason == :run_capacity_reached do
          Logger.warning(
            "Run admission control rejected run_id=#{inspect(run_id)} session_key=#{inspect(session_key)}: #{inspect(reason)}"
          )
        else
          Logger.error("Failed to start run process: #{inspect(reason)}")
        end

        {:error, reason}
    end
  end

  defp start_run_process(state, run_id, session_key, job) do
    run_opts =
      state.run_process_opts
      |> Map.merge(%{run_id: run_id, session_key: session_key, job: job})

    spec = {state.run_process_module, run_opts}

    case DynamicSupervisor.start_child(state.run_supervisor, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, :max_children} ->
        {:error, :run_capacity_reached}

      {:error, {:noproc, _}} ->
        {:error, :router_not_ready}

      {:error, :noproc} ->
        {:error, :router_not_ready}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Subscribe the control-plane EventBridge to run events for WS delivery
  defp subscribe_event_bridge(run_id) do
    LemonCore.EventBridge.subscribe_run(run_id)
  end

  # Get session configuration from store (includes model, thinking_level, tool_policy)
  defp get_session_config(nil), do: %{}

  defp get_session_config(session_key) do
    case LemonCore.Store.get_session_policy(session_key) do
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

  defp resolve_effective_cwd(cwd_override, meta) do
    normalize_cwd(cwd_override) || normalize_cwd(meta[:cwd] || meta["cwd"]) ||
      GatewayCwd.default_cwd()
  end

  defp normalize_cwd(cwd) when is_binary(cwd) do
    cwd = String.trim(cwd)
    if cwd == "", do: nil, else: Path.expand(cwd)
  end

  defp normalize_cwd(_), do: nil

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

  @doc false
  @spec extract_resume_and_strip_prompt(String.t() | nil, map()) ::
          {LemonGateway.Types.ResumeToken.t() | nil, String.t()}
  def extract_resume_and_strip_prompt(prompt, meta) do
    prompt = prompt || ""

    reply_to_text =
      meta[:reply_to_text] || meta["reply_to_text"] ||
        get_in(meta, [:raw, "message", "reply_to_message", "text"]) ||
        get_in(meta, [:raw, "message", "reply_to_message", "caption"])

    resume =
      cond do
        true ->
          case EngineRegistry.extract_resume(prompt) do
            {:ok, token} ->
              token

            :none ->
              if is_binary(reply_to_text) and reply_to_text != "" do
                case EngineRegistry.extract_resume(reply_to_text) do
                  {:ok, token} -> token
                  :none -> nil
                end
              else
                nil
              end
          end
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

  defp normalize_run_process_opts(opts) when is_map(opts), do: opts
  defp normalize_run_process_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_run_process_opts(_), do: %{}
end
