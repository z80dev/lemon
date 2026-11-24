defmodule LemonRouter.SubmissionBuilder do
  @moduledoc """
  Builds the router-owned submission handed from orchestration to coordination.

  This module resolves profile/session defaults, resume behavior, and
  conversation selection, and pending-compaction preparation before constructing the canonical
  `%LemonCore.ExecutionCommand{}` and wrapping it in `%LemonRouter.Submission{}`.
  """

  alias LemonCore.{
    Cwd,
    ExecutionCommand,
    ExecutionContext,
    MapHelpers,
    RunRequest,
    SessionKey
  }

  alias LemonCore.Config.Features

  alias LemonMemory.TaskFingerprint

  alias LemonRouter.{
    AgentProfiles,
    ConversationKey,
    ModelSelection,
    PendingCompaction,
    Policy,
    ResumeResolver,
    RoutingFeedbackStore,
    Submission
  }

  alias LemonRouter.ThinkingLevel

  @queue_modes [:collect, :followup, :steer, :steer_backlog, :redirect, :interrupt]

  @doc """
  Check the fields the durable admission claim and the queue rely on: a
  non-empty run ID and UTF-8 session key, a known queue mode and an atom origin.
  A failure is a definite rejection, checked before anything is written.
  """
  @spec validate_request(RunRequest.t()) :: :ok | {:error, :invalid_submission}
  def validate_request(%RunRequest{
        run_id: run_id,
        session_key: session_key,
        queue_mode: queue_mode,
        origin: origin
      })
      when is_binary(run_id) and run_id != "" and is_binary(session_key) and session_key != "" and
             queue_mode in @queue_modes and is_atom(origin) and not is_nil(origin) do
    if String.valid?(session_key), do: :ok, else: {:error, :invalid_submission}
  end

  def validate_request(_request), do: {:error, :invalid_submission}

  @doc """
  Snapshot the config admission needs (operator default model, routing-feedback
  and crash-resume features, configured agent IDs).

  Read once per admission in the submitting caller's process, before the durable
  claim: a config that cannot be read (for example a mid-edit invalid TOML) is
  the definite `{:error, :config_unavailable}`, never an exception inside the
  admission owner.
  """
  @spec admission_settings() :: {:ok, map()} | {:error, :config_unavailable}
  def admission_settings do
    config = LemonCore.Config.cached()

    {:ok,
     %{
       default_model: operator_default_model(config),
       routing_feedback: Features.enabled?(config.features, :routing_feedback),
       crash_resume: Features.enabled?(config.features, :crash_resume),
       agent_ids: Map.keys(config.agents || %{})
     }}
  rescue
    _ -> {:error, :config_unavailable}
  catch
    :exit, _ -> {:error, :config_unavailable}
  end

  @doc """
  Build the submission for `params`. Admission passes the `:admission_settings`
  its caller read before the durable claim; any other caller has them read here.
  """
  @spec build(RunRequest.t(), map()) :: {:ok, Submission.t()} | {:error, term()}
  def build(%RunRequest{} = params, opts) when is_map(opts) do
    origin = params.origin || :unknown
    session_key = params.session_key
    agent_id = params.agent_id || SessionKey.agent_id(session_key) || "default"
    prompt = params.prompt
    images = params.images || []
    queue_mode = params.queue_mode || :collect
    request_model = params.model

    meta = params.meta || %{}

    cwd_override = params.cwd
    tool_policy_override = params.tool_policy
    run_id = params.run_id

    with {:ok, settings} <- settings(opts),
         :ok <- require_channel_provenance(origin, meta),
         :ok <- require_goal_binding(origin, meta, cwd_override),
         {:ok, session_config} <- get_session_config(session_key),
         {:ok, agent_profile} <- get_execution_profile(agent_id, meta, settings),
         {:ok, tool_policy} <-
           resolve_tool_policy(agent_profile, tool_policy_override, %{
             agent_id: agent_id,
             session_key: session_key,
             channel_context: MapHelpers.get_key(meta, :channel_context)
           }),
         cwd <- resolve_effective_cwd(cwd_override, meta, origin),
         {:ok, execution_context} <-
           resolve_execution_context(
             params.execution_context,
             run_id,
             agent_id,
             origin,
             cwd,
             tool_policy,
             meta
           ),
         tool_policy <- execution_context.tool_policy,
         meta <-
           Map.put(
             meta,
             :resume_policy_override,
             is_map(tool_policy_override) or not is_nil(params.execution_context)
           ),
         {:ok, resolved_resume, resume_source} <-
           ResumeResolver.resolve(
             params.resume,
             session_key,
             meta,
             tool_policy,
             LemonCore.Store,
             run_id
           ) do
      {prompt, pending_compaction_marker} =
        PendingCompaction.prepare(prompt, session_key, origin,
          meta: meta,
          tool_policy: tool_policy,
          run_id: run_id
        )

      prompt =
        if MapHelpers.get_key(meta, :voice_transcribed) do
          "(voice transcribed) " <> (prompt || "")
        else
          prompt
        end

      session_model = MapHelpers.get_key(session_config, :model)
      session_thinking_level = MapHelpers.get_key(session_config, :thinking_level)
      request_thinking_level = MapHelpers.get_key(meta, :thinking_level)
      profile_model = MapHelpers.get_key(agent_profile, :model)
      profile_system_prompt = MapHelpers.get_key(agent_profile, :system_prompt)
      default_model = settings.default_model

      explicit_model = request_model || MapHelpers.get_key(meta, :model)
      explicit_system_prompt = MapHelpers.get_key(meta, :system_prompt)

      history_model = resolve_history_model(prompt, cwd, explicit_model, settings)

      selection_input = %{
        explicit_model: request_model,
        model_explicit: params.model_explicit,
        meta_model: MapHelpers.get_key(meta, :model),
        session_model: session_model,
        profile_model: profile_model,
        history_model: history_model,
        default_model: default_model
      }

      selection = ModelSelection.resolve(selection_input)
      resolved_model = selection.model

      resolved_thinking_level =
        normalize_thinking_level(request_thinking_level || session_thinking_level)

      resolved_system_prompt = explicit_system_prompt || profile_system_prompt

      # Auto-resume can become available while a session backlog is draining.
      # Keep that backlog under its original session owner; explicit shared
      # resume tokens still coordinate across session keys.
      conversation_key =
        ConversationKey.resolve(session_key, if(resume_source == :explicit, do: resolved_resume))

      enriched_meta =
        meta
        |> Map.merge(%{
          node: MapHelpers.get_key(meta, :node) || MapHelpers.get_key(agent_profile, :node),
          origin: origin,
          agent_id: agent_id,
          thinking_level: resolved_thinking_level,
          model: resolved_model,
          model_explicit: selection.model_explicit,
          # A profile or router-default selector is operator configuration: the
          # session resolves it (roles included) against operator settings only.
          # Always set here, so a caller's meta cannot claim it.
          model_source: if(ModelSelection.operator_source?(selection_input), do: :operator),
          # A delegating session's admitted request model carries its project
          # origin; only that tightening claim survives, never an operator one.
          model_origin:
            if(
              not is_nil(request_model) and
                MapHelpers.get_key(meta, :model_origin) in [:project, "project"],
              do: :project
            ),
          resume_source: resume_source
        })
        |> maybe_put(:system_prompt, resolved_system_prompt)
        |> maybe_put(:routing_feedback_model, history_model)

      execution_request = %ExecutionCommand{
        run_id: run_id,
        session_key: session_key,
        prompt: prompt,
        images: images,
        cwd: cwd,
        resume: resolved_resume,
        lane: MapHelpers.get_key(meta, :lane) || :main,
        tool_policy: tool_policy,
        execution_context: execution_context,
        meta: enriched_meta,
        conversation_key: conversation_key
      }

      Submission.new(%{
        run_id: run_id,
        session_key: session_key,
        conversation_key: conversation_key,
        queue_mode: queue_mode,
        execution_request: execution_request,
        run_supervisor: MapHelpers.get_key(opts, :run_supervisor),
        run_process_module: MapHelpers.get_key(opts, :run_process_module),
        run_process_opts: MapHelpers.get_key(opts, :run_process_opts),
        pending_compaction_marker: pending_compaction_marker,
        meta: LemonCore.RunStore.execution_projection(enriched_meta),
        request: params
      })
    end
  end

  def build(_request, _opts), do: {:error, :invalid_submission}

  defp settings(%{admission_settings: %{} = settings}), do: {:ok, settings}
  defp settings(_opts), do: admission_settings()

  # Channel-origin runs carry the transport-derived context (channel policy and
  # group approval floor) and sender identity (memory isolation, approvals) that
  # `LemonChannels.RunRequestBuilder` attaches. A channel request without them,
  # such as work persisted before they existed and replayed after an upgrade, is
  # definitively refused rather than run with no channel restrictions.
  defp require_channel_provenance(:channel, meta) do
    context = MapHelpers.get_key(meta, :channel_context)
    identity = MapHelpers.get_key(meta, :channel_identity)

    with true <- is_map(context) and is_map(identity),
         channel when is_binary(channel) and channel != "" <- Map.get(context, :channel_id),
         ^channel <- Map.get(identity, :channel_id),
         sender when is_binary(sender) and sender != "" <- Map.get(identity, :sender_id),
         true <- is_boolean(Map.get(identity, :verified?)),
         true <- is_boolean(Map.get(identity, :owner?)) do
      :ok
    else
      _ -> {:error, :missing_channel_provenance}
    end
  end

  # Webhook and A2A ingress authenticate an integration or peer, not a channel
  # sender. Their producers attach provenance naming the `webhook` or `a2a`
  # channel, derived from that authenticated principal, so the channel's policy
  # applies whatever the submission origin. A request without it, or naming
  # another channel, is refused rather than run without those restrictions.
  defp require_channel_provenance(:webhook, meta), do: require_ingress_context(meta, "webhook")

  defp require_channel_provenance(_origin, meta) do
    if MapHelpers.get_key(meta, :a2a) == true,
      do: require_ingress_context(meta, "a2a"),
      else: :ok
  end

  defp require_ingress_context(meta, channel) do
    case MapHelpers.get_key(meta, :channel_context) do
      %{channel_id: ^channel, account_id: account, peer_id: peer}
      when is_binary(account) and account != "" and is_binary(peer) and peer != "" ->
        :ok

      _ ->
        {:error, :missing_channel_provenance}
    end
  end

  # Goal judge and continuation runs execute later, without a live caller, in
  # the directory the automation checked against the goal's recorded root.
  # They must name that directory and carry its identity (`meta.cwd_identity`),
  # which the session runner re-verifies at start and before every tool call.
  defp require_goal_binding(origin, meta, cwd) when origin in [:goal, :goal_judge] do
    case MapHelpers.get_key(meta, :cwd_identity) do
      %{"major" => _, "minor" => _, "inode" => _} when is_binary(cwd) and cwd != "" -> :ok
      _ -> {:error, :goal_cwd_identity_required}
    end
  end

  defp require_goal_binding(_origin, _meta, _cwd), do: :ok

  @doc false
  def current_native_target_policy(profile_id, session_key, meta) do
    with {:ok, profile} <- get_managed_profile(profile_id),
         {:ok, policy} <-
           resolve_tool_policy(profile, nil, %{
             agent_id: profile_id,
             session_key: session_key,
             channel_context: MapHelpers.get_key(meta || %{}, :channel_context)
           }) do
      LemonCore.ToolPolicy.normalize(policy)
    end
  end

  defp resolve_tool_policy(agent_profile, override, context) do
    with {:ok, base} <- Policy.resolve_validated_for_run(context),
         {:ok, profile} <-
           Policy.merge_validated(base, normalize_profile_tool_policy(agent_profile)) do
      Policy.merge_validated(profile, override)
    end
  end

  defp get_session_config(nil), do: {:ok, %{}}

  defp get_session_config(session_key) do
    case LemonCore.PolicyStore.fetch_session(session_key) do
      {:ok, nil} -> {:ok, %{}}
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, _invalid} -> {:error, :invalid_session_policy}
      {:error, _reason} -> {:error, :policy_unavailable}
    end
  end

  defp get_execution_profile(agent_id, meta, settings) do
    case {Map.get(meta, :invocation_proof_verified) == true,
          MapHelpers.get_key(meta, :profile_id)} do
      {_, ^agent_id} -> get_managed_profile(agent_id)
      {true, _} -> {:error, {:unknown_agent_id, agent_id}}
      {false, profile_id} when is_binary(profile_id) -> {:error, {:unknown_agent_id, agent_id}}
      {false, _} -> get_agent_profile(agent_id, settings)
    end
  end

  defp get_agent_profile(agent_id, settings) when is_binary(agent_id) do
    # Durable managed policy wins over a stale registry or project overlay.
    case LemonCore.ProfileStore.get(agent_id) do
      {:ok, profile} ->
        {:ok,
         %{
           id: agent_id,
           model: profile["model"],
           system_prompt: profile["systemPrompt"],
           tool_policy: profile["toolPolicy"],
           node: profile["node"]
         }}

      {:error, :not_found} ->
        if agent_profile_exists?(agent_id, settings) do
          {:ok, AgentProfiles.get(agent_id) || %{}}
        else
          {:error, {:unknown_agent_id, agent_id}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    # The managed profile or registry could not answer: its tool policy, model
    # and node are unknown, so admission must not proceed without them.
    :exit, _ -> {:error, :profile_unavailable}
  end

  defp get_agent_profile(_agent_id, _settings), do: {:error, {:unknown_agent_id, nil}}

  defp get_managed_profile(agent_id) do
    case LemonCore.ProfileStore.get(agent_id) do
      {:ok, profile} ->
        {:ok,
         %{
           id: agent_id,
           model: profile["model"],
           system_prompt: profile["systemPrompt"],
           tool_policy: profile["toolPolicy"] || %{}
         }}

      {:error, _} ->
        {:error, {:unknown_agent_id, agent_id}}
    end
  end

  defp agent_profile_exists?(agent_id, settings) when is_binary(agent_id) and agent_id != "" do
    AgentProfiles.exists?(agent_id) == true
  catch
    :exit, _ -> agent_id in settings.agent_ids or agent_id == "default"
  end

  defp agent_profile_exists?(_agent_id, _settings), do: false

  defp normalize_profile_tool_policy(profile) when is_map(profile) do
    case MapHelpers.get_key(profile, :tool_policy) do
      nil -> nil
      policy -> policy
    end
  end

  defp normalize_profile_tool_policy(_), do: nil

  defp resolve_effective_cwd(cwd_override, meta, origin) do
    if MapHelpers.get_key(meta, :node) not in [nil, "", "local", :local] and
         Map.get(meta, :remote_cwd_explicit, Map.get(meta, "remote_cwd_explicit")) == false do
      nil
    else
      normalize_cwd(cwd_override) || normalize_cwd(MapHelpers.get_key(meta, :cwd)) ||
        default_cwd_for(origin)
    end
  end

  defp resolve_execution_context(
         nil,
         run_id,
         agent_id,
         origin,
         cwd,
         tool_policy,
         _meta
       ) do
    ExecutionContext.new(
      run_id: run_id,
      agent_id: agent_id,
      origin: origin,
      cwd: cwd,
      tool_policy: tool_policy
    )
  end

  defp resolve_execution_context(
         %ExecutionContext{} = parent,
         run_id,
         agent_id,
         origin,
         cwd,
         tool_policy,
         meta
       ) do
    with {:ok, parent, child_cwd} <- context_parent_for_destination(parent, cwd, meta) do
      ExecutionContext.child(parent,
        run_id: run_id,
        principal: %{type: "agent", id: agent_id},
        provenance: %{origin: origin, delegated_by: ExecutionContext.identity(parent)},
        cwd: child_cwd,
        tool_policy: tool_policy
      )
    end
  end

  defp resolve_execution_context(
         _context,
         _run_id,
         _agent_id,
         _origin,
         _cwd,
         _tool_policy,
         _meta
       ),
       do: {:error, :invalid_execution_context}

  defp context_parent_for_destination(parent, cwd, meta) do
    case MapHelpers.get_key(meta, :node) do
      node when is_binary(node) and node not in ["", "local"] ->
        with {:ok, remote_parent} <- ExecutionContext.for_remote(parent, nil) do
          {:ok, remote_parent, nil}
        end

      _ ->
        {:ok, parent, cwd}
    end
  end

  # Remote chat runs default to the assistant home, never the user's $HOME.
  defp default_cwd_for(:channel), do: Cwd.channel_default_cwd()
  defp default_cwd_for(_origin), do: Cwd.default_cwd()

  defp normalize_cwd(cwd) when is_binary(cwd) do
    cwd = String.trim(cwd)
    if cwd == "", do: nil, else: Path.expand(cwd)
  end

  defp normalize_cwd(_), do: nil

  # The router default is operator configuration: the global layer, never a
  # project file under the router's working directory.
  defp operator_default_model(config) do
    case config.provenance do
      %{operator: operator} -> operator.agent.default_model
      _ -> config.agent.default_model
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_thinking_level(nil), do: nil
  defp normalize_thinking_level(level) when is_atom(level), do: level
  defp normalize_thinking_level(level) when is_binary(level), do: ThinkingLevel.normalize(level)
  defp normalize_thinking_level(_), do: nil

  defp resolve_history_model(prompt, cwd, explicit_model, _settings)
       when is_binary(explicit_model) and byte_size(explicit_model) > 0 do
    _ = {prompt, cwd}
    nil
  end

  defp resolve_history_model(_prompt, _cwd, _explicit_model, %{routing_feedback: false}), do: nil

  defp resolve_history_model(prompt, cwd, _explicit_model, _settings) do
    fp = %TaskFingerprint{
      task_family: TaskFingerprint.classify_prompt(prompt),
      workspace_key: cwd
    }

    case RoutingFeedbackStore.best_model_for_context(TaskFingerprint.context_key(fp)) do
      {:ok, model} -> model
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end
end
