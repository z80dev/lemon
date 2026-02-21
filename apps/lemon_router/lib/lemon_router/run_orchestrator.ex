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

  alias LemonRouter.{AgentProfiles, ModelSelection, Policy, RunProcess, StickyEngine}
  alias LemonCore.{RunRequest, SessionKey}
  alias LemonChannels.Types.ResumeToken
  alias LemonGateway.Cwd, as: GatewayCwd
  alias LemonChannels.EngineRegistry
  alias AgentCore.CliRunners.Types.ResumeToken, as: CliResume

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Submit a run request.

  ## Parameters

  Accepts a `%LemonCore.RunRequest{}` with these fields:

  - `:origin` - Source of the request (:channel, :control_plane, :cron, :node)
  - `:session_key` - Session key for routing
  - `:agent_id` - Agent identifier
  - `:prompt` - User prompt text
  - `:queue_mode` - Queue mode (:collect, :followup, :steer, :steer_backlog, :interrupt)
  - `:engine_id` - Optional engine override
  - `:model` - Optional model override (independent of profile binding)
  - `:meta` - Additional metadata
  - `:cwd` - Optional cwd override
  - `:tool_policy` - Optional tool policy override

  ## Returns

  `{:ok, run_id}` on success, `{:error, reason}` on failure.
  """
  @spec submit(RunRequest.t() | map() | keyword()) :: {:ok, binary()} | {:error, term()}
  def submit(%RunRequest{} = request), do: submit(__MODULE__, request)

  def submit(request) when is_map(request) or is_list(request) do
    normalized = RunRequest.new(request)
    submit(__MODULE__, normalized)
  end

  @doc """
  Submit a run request to a specific orchestrator server.
  """
  @spec submit(GenServer.server(), RunRequest.t() | map() | keyword()) ::
          {:ok, binary()} | {:error, term()}
  def submit(server, %RunRequest{} = request), do: GenServer.call(server, {:submit, request})

  def submit(server, request) when is_map(request) or is_list(request) do
    normalized = RunRequest.new(request)
    submit(server, normalized)
  end

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
  def handle_call({:submit, %RunRequest{} = params}, _from, state) do
    result = do_submit(params, state)
    {:reply, result, state}
  end

  def handle_call({:submit, _invalid}, _from, state) do
    {:reply, {:error, :invalid_run_request}, state}
  end

  defp do_submit(%RunRequest{} = params, orchestrator_state) do
    origin = params.origin || :unknown
    session_key = params.session_key
    agent_id = params.agent_id || SessionKey.agent_id(session_key) || "default"
    prompt = params.prompt
    queue_mode = params.queue_mode || :collect
    engine_id = params.engine_id
    request_model = params.model
    meta = params.meta || %{}

    # Extract cwd and tool_policy overrides from params
    cwd_override = params.cwd
    tool_policy_override = params.tool_policy

    # Generate run_id (honor caller-provided run_id for cron jobs to avoid race conditions)
    run_id = params.run_id || LemonCore.Id.run_id()

    # Get session policies (includes model, thinkingLevel, and tool_policy)
    session_config = get_session_config(session_key)

    with {:ok, agent_profile} <- get_agent_profile(agent_id) do
      # Resolve base tool policy from agent/session/channel
      base_tool_policy =
        Policy.resolve_for_run(%{
          agent_id: agent_id,
          session_key: session_key,
          origin: origin,
          channel_context: meta[:channel_context]
        })

      # Merge agent profile tool policy before operator overrides.
      profile_tool_policy = normalize_profile_tool_policy(agent_profile)

      base_tool_policy =
        if is_map(profile_tool_policy) and map_size(profile_tool_policy) > 0 do
          Policy.merge(base_tool_policy, profile_tool_policy)
        else
          base_tool_policy
        end

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

      session_model = session_config[:model] || session_config["model"]
      session_thinking_level = session_config[:thinking_level] || session_config["thinking_level"]
      session_preferred_engine = session_config[:preferred_engine] || session_config["preferred_engine"]
      profile_model = map_get(agent_profile, :model)
      profile_default_engine = map_get(agent_profile, :default_engine)
      profile_system_prompt = map_get(agent_profile, :system_prompt)
      default_model = Application.get_env(:lemon_router, :default_model)

      explicit_model = request_model || map_get(meta, :model)
      explicit_system_prompt = map_get(meta, :system_prompt)

      # Resolve sticky engine: explicit request > prompt directive > session preference
      {sticky_engine_id, sticky_session_updates} =
        StickyEngine.resolve(%{
          explicit_engine_id: engine_id,
          prompt: prompt,
          session_preferred_engine: session_preferred_engine
        })

      # Persist sticky engine preference to session policy if changed
      persist_sticky_engine(session_key, sticky_session_updates)

      # Use sticky engine as explicit_engine_id if no request-level override was given
      effective_engine_id = engine_id || sticky_engine_id

      selection =
        ModelSelection.resolve(%{
          explicit_model: explicit_model,
          meta_model: map_get(meta, :model),
          session_model: session_model,
          profile_model: profile_model,
          default_model: default_model,
          explicit_engine_id: effective_engine_id,
          profile_default_engine: profile_default_engine,
          resume_engine: resume && resume.engine
        })

      resolved_model = selection.model
      resolved_thinking_level = session_thinking_level
      resolved_system_prompt = explicit_system_prompt || profile_system_prompt

      if is_binary(selection.warning) do
        Logger.warning(
          "Model/engine mismatch for run_id=#{inspect(run_id)}: #{selection.warning}"
        )
      end

      resolved_engine_id = selection.engine_id

      # Build gateway job
      enriched_meta =
        meta
        |> Map.merge(%{
          origin: origin,
          agent_id: agent_id,
          thinking_level: resolved_thinking_level,
          model: resolved_model
        })
        |> maybe_put(:model_resolution_warning, selection.warning)
        |> maybe_put(:system_prompt, resolved_system_prompt)

      job = %LemonGateway.Types.Job{
        run_id: run_id,
        session_key: session_key,
        prompt: prompt,
        engine_id: resolved_engine_id,
        cwd: cwd,
        resume: resume,
        queue_mode: queue_mode,
        lane: meta[:lane] || :main,
        tool_policy: tool_policy,
        meta: enriched_meta
      }

      # Start run process
      case start_run_process(orchestrator_state, run_id, session_key, job) do
        {:ok, _pid} ->
          # Subscribe control-plane EventBridge to run events for WS delivery
          subscribe_event_bridge(run_id)

          # Emit telemetry
          LemonCore.Telemetry.run_submit(session_key, origin, resolved_engine_id || "default")
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

  # Persist sticky engine preference updates to session policy
  defp persist_sticky_engine(nil, _updates), do: :ok
  defp persist_sticky_engine(_session_key, updates) when map_size(updates) == 0, do: :ok

  defp persist_sticky_engine(session_key, updates) do
    existing = LemonCore.Store.get_session_policy(session_key) || %{}
    updated = Map.merge(existing, updates)
    LemonCore.Store.put_session_policy(session_key, updated)
  rescue
    e ->
      Logger.warning(
        "Failed to persist sticky engine for session=#{inspect(session_key)}: #{Exception.message(e)}"
      )
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

  defp get_agent_profile(agent_id) when is_binary(agent_id) do
    if agent_profile_exists?(agent_id) do
      case AgentProfiles.get(agent_id) do
        profile when is_map(profile) -> {:ok, profile}
        _ -> {:ok, %{}}
      end
    else
      {:error, {:unknown_agent_id, agent_id}}
    end
  rescue
    _ ->
      if fallback_agent_profile_exists?(agent_id) do
        {:ok, %{}}
      else
        {:error, {:unknown_agent_id, agent_id}}
      end
  catch
    :exit, _ ->
      if fallback_agent_profile_exists?(agent_id) do
        {:ok, %{}}
      else
        {:error, {:unknown_agent_id, agent_id}}
      end
  end

  defp get_agent_profile(_), do: {:error, {:unknown_agent_id, nil}}

  defp agent_profile_exists?(agent_id) when is_binary(agent_id) and agent_id != "" do
    AgentProfiles.exists?(agent_id) == true
  rescue
    _ -> fallback_agent_profile_exists?(agent_id)
  catch
    :exit, _ -> fallback_agent_profile_exists?(agent_id)
  end

  defp agent_profile_exists?(_), do: false

  defp fallback_agent_profile_exists?(agent_id) when is_binary(agent_id) and agent_id != "" do
    cfg = LemonCore.Config.cached()
    agents = map_get(cfg, :agents) || %{}
    Map.has_key?(agents, agent_id) or agent_id == "default"
  rescue
    _ -> agent_id == "default"
  catch
    :exit, _ -> agent_id == "default"
  end

  defp fallback_agent_profile_exists?(_), do: false

  defp normalize_profile_tool_policy(profile) when is_map(profile) do
    case map_get(profile, :tool_policy) do
      policy when is_map(policy) -> policy
      _ -> %{}
    end
  end

  defp normalize_profile_tool_policy(_), do: %{}

  defp resolve_effective_cwd(cwd_override, meta) do
    normalize_cwd(cwd_override) || normalize_cwd(meta[:cwd] || meta["cwd"]) ||
      GatewayCwd.default_cwd()
  end

  defp normalize_cwd(cwd) when is_binary(cwd) do
    cwd = String.trim(cwd)
    if cwd == "", do: nil, else: Path.expand(cwd)
  end

  defp normalize_cwd(_), do: nil

  @doc false
  @spec extract_resume_and_strip_prompt(String.t() | nil, map()) ::
          {ResumeToken.t() | nil, String.t()}
  def extract_resume_and_strip_prompt(prompt, meta) do
    prompt = prompt || ""

    reply_to_text =
      meta[:reply_to_text] || meta["reply_to_text"] ||
        get_in(meta, [:raw, "message", "reply_to_message", "text"]) ||
        get_in(meta, [:raw, "message", "reply_to_message", "caption"])

    resume =
      case EngineRegistry.extract_resume(prompt) do
        {:ok, token} ->
          token

        :none ->
          extract_resume_from_reply(reply_to_text)
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

  @spec extract_resume_from_reply(binary() | nil) :: ResumeToken.t() | nil
  defp extract_resume_from_reply(text) when is_binary(text) and text != "" do
    case EngineRegistry.extract_resume(text) do
      {:ok, token} -> token
      :none -> nil
    end
  end

  defp extract_resume_from_reply(_), do: nil

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

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_map, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
