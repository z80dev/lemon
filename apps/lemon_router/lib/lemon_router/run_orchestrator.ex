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

  alias LemonGateway.ExecutionRequest
  alias LemonRouter.{
    AgentProfiles,
    ConversationKey,
    ModelSelection,
    Policy,
    ResumeResolver,
    RunProcess,
    SessionCoordinator,
    StickyEngine
  }
  alias LemonCore.{Cwd, Introspection, RunRequest, RoutingFeedbackStore, SessionKey, TaskFingerprint}

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
  Start a run process from a prepared submission.

  This entrypoint is used by `LemonRouter.SessionCoordinator`, which owns
  queue semantics and decides when a submission should become an active run.
  """
  @spec start_run_process(GenServer.server(), map(), pid(), term()) ::
          {:ok, pid()} | {:error, term()}
  def start_run_process(server, submission, coordinator_pid, conversation_key)
      when is_map(submission) and is_pid(coordinator_pid) do
    GenServer.call(
      server,
      {:start_run_process, submission, coordinator_pid, conversation_key},
      15_000
    )
  end

  @doc """
  Lightweight run counts for status UIs.

  `active` reflects current supervised run processes.
  `queued` and `completed_today` are derived from telemetry counters
  maintained by `LemonRouter.RunCountTracker`.
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

    {queued, completed_today} =
      try do
        {LemonRouter.RunCountTracker.queued(), LemonRouter.RunCountTracker.completed_today()}
      rescue
        _ -> {0, 0}
      end

    %{active: active, queued: queued, completed_today: completed_today}
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

  def handle_call(
        {:start_run_process, submission, coordinator_pid, conversation_key},
        _from,
        state
      ) do
    result = do_start_run_process(submission, coordinator_pid, conversation_key, state)
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

    # Emit introspection event for orchestration start
    Introspection.record(
      :orchestration_started,
      %{
        origin: origin,
        agent_id: agent_id,
        queue_mode: queue_mode,
        engine_id: engine_id
      },
      run_id: run_id,
      session_key: session_key,
      agent_id: agent_id,
      engine: "lemon",
      provenance: :direct
    )

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

      prompt =
        if meta[:voice_transcribed] do
          base = prompt || ""
          "(voice transcribed) " <> base
        else
          prompt
        end

      session_model = session_config[:model] || session_config["model"]
      session_thinking_level = session_config[:thinking_level] || session_config["thinking_level"]
      request_thinking_level = map_get(meta, :thinking_level)

      session_preferred_engine =
        session_config[:preferred_engine] || session_config["preferred_engine"]

      profile_model = map_get(agent_profile, :model)
      profile_default_engine = map_get(agent_profile, :default_engine)
      profile_system_prompt = map_get(agent_profile, :system_prompt)
      default_model = default_model_from_config()

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

      # Look up best historical model as a tie-breaker (behind routing_feedback flag)
      history_model = resolve_history_model(prompt, cwd, explicit_model, meta)

      selection =
        ModelSelection.resolve(%{
          explicit_model: explicit_model,
          meta_model: map_get(meta, :model),
          session_model: session_model,
          profile_model: profile_model,
          history_model: history_model,
          default_model: default_model,
          explicit_engine_id: effective_engine_id,
          profile_default_engine: profile_default_engine,
          resume_engine: params.resume && params.resume.engine
        })

      resolved_model = selection.model
      resolved_thinking_level =
        normalize_thinking_level(request_thinking_level || session_thinking_level)
      resolved_system_prompt = explicit_system_prompt || profile_system_prompt

      if is_binary(selection.warning) do
        Logger.warning(
          "Model/engine mismatch for run_id=#{inspect(run_id)}: #{selection.warning}"
        )
      end

      {resolved_resume, resolved_engine_id} =
        ResumeResolver.resolve(params.resume, session_key, selection.engine_id, meta)

      conversation_key = ConversationKey.resolve(session_key, resolved_resume)

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
        |> maybe_put(:routing_feedback_model, history_model)

      execution_request = %ExecutionRequest{
        run_id: run_id,
        session_key: session_key,
        prompt: prompt,
        engine_id: resolved_engine_id,
        cwd: cwd,
        resume: resolved_resume,
        lane: meta[:lane] || :main,
        tool_policy: tool_policy,
        meta: enriched_meta,
        conversation_key: conversation_key
      }

      submission = %{
        run_id: run_id,
        session_key: session_key,
        queue_mode: queue_mode,
        execution_request: execution_request,
        run_supervisor: orchestrator_state.run_supervisor,
        run_process_module: orchestrator_state.run_process_module,
        run_process_opts: orchestrator_state.run_process_opts,
        meta: enriched_meta
      }

      case SessionCoordinator.submit(conversation_key, submission) do
        :ok ->
          subscribe_event_bridge(run_id)

          Introspection.record(
            :orchestration_resolved,
            %{
              engine_id: resolved_engine_id,
              model: resolved_model,
              conversation_key: inspect(conversation_key)
            },
            run_id: run_id,
            session_key: session_key,
            agent_id: agent_id,
            engine: "lemon",
            provenance: :direct
          )

          LemonCore.Telemetry.run_submit(session_key, origin, resolved_engine_id || "default")
          {:ok, run_id}

        {:error, reason} ->
          Introspection.record(
            :orchestration_failed,
            %{
              reason: safe_error_label(reason)
            },
            run_id: run_id,
            session_key: session_key,
            agent_id: agent_id,
            engine: "lemon",
            provenance: :direct
          )

          Logger.error("Failed to submit run to session coordinator: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp do_start_run_process(submission, coordinator_pid, conversation_key, state)
       when is_map(submission) do
    run_id = map_get(submission, :run_id)
    session_key = map_get(submission, :session_key)
    queue_mode = map_get(submission, :queue_mode) || :collect
    execution_request = map_get(submission, :execution_request)

    run_opts =
      state.run_process_opts
      |> Map.merge(%{
        run_id: run_id,
        session_key: session_key,
        queue_mode: queue_mode,
        execution_request: execution_request,
        coordinator_pid: coordinator_pid,
        conversation_key: conversation_key,
        manage_session_registry?: false
      })

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
    existing = LemonCore.PolicyStore.get_session(session_key) || %{}
    updated = Map.merge(existing, updates)
    LemonCore.PolicyStore.put_session(session_key, updated)
  rescue
    e ->
      Logger.warning(
        "Failed to persist sticky engine for session=#{inspect(session_key)}: #{Exception.message(e)}"
      )
  end

  # Get session configuration from store (includes model, thinking_level, tool_policy)
  defp get_session_config(nil), do: %{}

  defp get_session_config(session_key) do
    case LemonCore.PolicyStore.get_session(session_key) do
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
        Cwd.default_cwd()
  end

  defp normalize_cwd(cwd) when is_binary(cwd) do
    cwd = String.trim(cwd)
    if cwd == "", do: nil, else: Path.expand(cwd)
  end

  defp normalize_cwd(_), do: nil

  defp normalize_run_process_opts(opts) when is_map(opts), do: opts
  defp normalize_run_process_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_run_process_opts(_), do: %{}

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_map, _key), do: nil

  defp default_model_from_config do
    LemonCore.Config.cached().agent.default_model
  rescue
    _ -> nil
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @thinking_levels %{
    "off" => :off,
    "minimal" => :minimal,
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "xhigh" => :xhigh
  }

  defp normalize_thinking_level(nil), do: nil
  defp normalize_thinking_level(level) when is_atom(level), do: level
  defp normalize_thinking_level(level) when is_binary(level), do: Map.get(@thinking_levels, level)
  defp normalize_thinking_level(_), do: nil

  # Look up the best historically-performing model for this prompt/workspace context.
  # Returns nil (no-op) when:
  #   - routing_feedback feature flag is off
  #   - an explicit model override is already present (caller intent wins)
  #   - insufficient data in the store
  #   - any error (fail-open)
  defp resolve_history_model(prompt, cwd, explicit_model, _meta)
       when is_binary(explicit_model) and byte_size(explicit_model) > 0 do
    _ = {prompt, cwd}
    nil
  end

  defp resolve_history_model(prompt, cwd, _explicit_model, _meta) do
    try do
      config = LemonCore.Config.Modular.load()

      if LemonCore.Config.Features.enabled?(config.features, :routing_feedback) do
        fp = %TaskFingerprint{
          task_family: TaskFingerprint.classify_prompt(prompt),
          workspace_key: cwd
        }

        context_key = TaskFingerprint.context_key(fp)

        case RoutingFeedbackStore.best_model_for_context(context_key) do
          {:ok, model} -> model
          _ -> nil
        end
      else
        nil
      end
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  # Produce a safe, bounded label for introspection error payloads.
  defp safe_error_label(nil), do: nil
  defp safe_error_label(err) when is_atom(err), do: Atom.to_string(err)
  defp safe_error_label(err) when is_binary(err), do: String.slice(err, 0, 80)

  defp safe_error_label(%{__exception__: true} = err),
    do: err.__struct__ |> Module.split() |> Enum.join(".") |> String.slice(0, 80)

  defp safe_error_label({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp safe_error_label(_), do: "unknown_error"
end
