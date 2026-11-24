defmodule CodingAgent.Executor.SessionRunner do
  @moduledoc false

  use GenServer

  @impl true
  def format_status(status) do
    LemonCore.StatusRedaction.gen_server(status, [:session_id, :run_id, :session_key, :agent_id])
  end

  import CodingAgent.Executor, only: [get_opt: 2, normalize_resume: 1]

  alias CodingAgent.Executor.RemoteRequestCodec
  alias CodingAgent.Session.Presentation
  alias CodingAgent.Session.RunTranslator
  alias CodingAgent.Tools.SendFile
  alias CodingAgent.Tools.Task.Params
  alias LemonGateway.ExecutionRequest
  alias LemonGateway.Tools.SmsClaimMessage
  alias LemonGateway.Tools.SmsGetInboxNumber
  alias LemonGateway.Tools.SmsListMessages
  alias LemonGateway.Tools.SmsReleaseInbox
  alias LemonGateway.Tools.SmsWaitForCode

  require Logger

  @engine "lemon"

  defstruct [
    :session,
    :session_ref,
    :session_id,
    :sink_pid,
    :sink_ref,
    :run_ref,
    :prompt,
    :cwd,
    :resume,
    :run_id,
    :session_key,
    :agent_id,
    :translator
  ]

  defmodule Emitter do
    @moduledoc false

    @behaviour CodingAgent.Session.RunTranslator.Emitter

    alias CodingAgent.Session.Presentation
    alias LemonGateway.Event

    defstruct [:sink_pid, :run_ref, :session, :session_id]

    @impl true
    def emit_started(state, fields) do
      event =
        Event.started(%{
          engine: fields.engine,
          resume: fields.resume,
          meta: fields.meta
        })

      emit_event(state, event)
      state
    end

    @impl true
    def emit_action_event(state, fields) do
      action =
        Event.action(%{
          id: fields.id,
          kind: to_string(fields.kind),
          title: fields.title,
          detail: fields.detail
        })

      event =
        Event.action_event(%{
          engine: fields.engine,
          action: action,
          phase: fields.phase,
          ok: fields.ok,
          message: fields.message,
          level: fields.level
        })

      emit_event(state, event)
      state
    end

    @impl true
    def emit_delta(state, text, _meta) do
      send(state.sink_pid, {:engine_delta, state.run_ref, text})
      state
    end

    @impl true
    def emit_completed(state, fields) do
      fields = attach_context_budget(state, fields)
      event = Event.completed(fields)
      # Retain only after the prior-turn mailbox/persistence barrier. A queued
      # auto-resume can now prompt this same owner with the complete history.
      state = Presentation.finalize_session(state, true)

      emit_event(state, event)
      state
    end

    defp attach_context_budget(state, fields) do
      case CodingAgent.Session.context_budget(state.session) do
        {:ok, budget} ->
          Map.update(fields, :usage, %{context_budget: budget}, fn usage ->
            Map.put(usage || %{}, :context_budget, budget)
          end)

        _ ->
          fields
      end
    catch
      :exit, _ -> fields
    end

    defp emit_event(state, event) do
      send(state.sink_pid, {:engine_event, state.run_ref, event})
    end
  end

  def start(opts), do: GenServer.start(__MODULE__, opts)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def cancel(pid, reason \\ :user_requested) do
    GenServer.call(pid, {:cancel, reason})
  end

  def steer(pid, text) do
    GenServer.call(pid, {:steer, text})
  end

  def redirect(pid, text) do
    GenServer.call(pid, {:redirect, text})
  end

  @impl true
  def init(opts) do
    case Application.ensure_all_started(:coding_agent) do
      {:ok, _started} -> init_session(opts)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_session(opts) do
    request = Keyword.fetch!(opts, :request)
    request = %{request | meta: RemoteRequestCodec.normalize_meta(request.meta)}
    run_opts = Keyword.get(opts, :opts, %{})

    request =
      case request.execution_context do
        nil -> %{request | execution_context: get_opt(run_opts, :execution_context)}
        _context -> request
      end

    case request.execution_context do
      nil ->
        init_native_session(opts, request, run_opts)

      supplied ->
        run_id = request.run_id || get_opt(run_opts, :run_id)

        with {:ok, context} <- LemonCore.ExecutionContext.validate(supplied),
             true <- is_nil(run_id) or context.run_id == run_id do
          init_native_session(
            opts,
            %{request | run_id: context.run_id, execution_context: context},
            run_opts
          )
        else
          false -> {:stop, :execution_context_run_id_mismatch}
          {:error, reason} -> {:stop, reason}
        end
    end
  end

  defp init_native_session(opts, request, run_opts) do
    sink_pid = Keyword.fetch!(opts, :sink_pid)
    run_ref = Keyword.fetch!(opts, :run_ref)

    prompt = request.prompt
    cwd = request.cwd || get_opt(run_opts, :cwd) || File.cwd!()
    resume = normalize_resume(request.resume)
    run_id = request.run_id || get_opt(run_opts, :run_id)
    session_key = request.session_key
    agent_id = request_agent_id(request)
    async_followups = async_followups(request)
    extra_tools = extra_tools(request, run_opts)

    # Passed through to CodingAgent.Session, whose Lifecycle.initialize applies
    # CodingAgent.Session.ProviderFallback.maybe_wrap (a no-op when no runtime
    # fallback candidates exist). Do not wrap here: that would double-wrap.
    stream_fn = get_opt(run_opts, :stream_fn)

    emitter_state = %Emitter{sink_pid: sink_pid, run_ref: run_ref}

    translator =
      RunTranslator.new(
        emitter: Emitter,
        emitter_state: emitter_state,
        engine: @engine,
        label: "Lemon SessionRunner",
        cwd: cwd,
        run_id: run_id,
        delta_callback: get_opt(run_opts, :delta_callback)
      )

    state = %__MODULE__{
      sink_pid: sink_pid,
      run_ref: run_ref,
      prompt: prompt,
      cwd: cwd,
      resume: resume,
      run_id: run_id,
      session_key: session_key,
      agent_id: agent_id,
      translator: translator
    }

    state = %{state | sink_ref: Process.monitor(sink_pid)}

    meta = request.meta || %{}
    workspace_dir = profile_workspace(meta)
    tool_policy = execution_tool_policy(request, cwd, run_opts)

    session_opts =
      [
        model: get_in(meta, [:model]),
        model_explicit: model_explicit_from_meta(meta),
        model_source: model_source_from_meta(meta),
        model_origin: model_origin_from_meta(meta),
        thinking_level: get_in(meta, [:thinking_level]),
        system_prompt: get_in(meta, [:system_prompt]),
        profile_instructions: get_in(meta, [:profile_instructions]),
        project_memory_capture: Map.get(meta, :project_memory_capture, true),
        session_mode: Map.get(meta, :session_mode),
        persona: Map.get(meta, :persona),
        stream_fn: stream_fn,
        tool_policy: tool_policy,
        bot_folder_root: get_opt(run_opts, :bot_folder_root),
        config_cwd: get_opt(run_opts, :config_cwd),
        channel_identity: LemonCore.MapHelpers.get_key(meta, :channel_identity),
        tern_pane: Map.get(meta, :tern_pane),
        delegated_budget: LemonCore.MapHelpers.get_key(meta, :delegated_budget),
        invocation_context_key: LemonCore.MapHelpers.get_key(meta, :invocation_context_key),
        memory_context_key: LemonCore.MapHelpers.get_key(meta, :memory_context_key),
        memory_context_verified:
          Map.get(meta, :memory_context_verified, Map.get(meta, "memory_context_verified")) ==
            true,
        shared_memory_grant:
          Map.get(meta, :shared_memory_grant, Map.get(meta, "shared_memory_grant")) == true,
        invocation_mcp_servers: Map.get(meta, :mcp_servers),
        native_managed_context: Params.managed_metadata?(meta),
        native_lineage_handle: Map.get(meta, :native_lineage_handle),
        native_lineage_run_id: Map.get(meta, :native_lineage_run_id),
        native_source_profile_id: Map.get(meta, :profile_id),
        native_source_session_key: request.session_key,
        native_followup_submit: get_opt(run_opts, :native_followup_submit),
        native_source_floor_fun: get_opt(run_opts, :native_source_floor_fun),
        invocation_proof: Map.get(meta, :invocation_proof),
        invocation_proof_verified: Map.get(meta, :invocation_proof_verified) == true,
        execution_context: request.execution_context,
        approval_timeout_ms: get_opt(run_opts, :approval_timeout_ms),
        acp_session_id: get_in(meta, [:acp_session_id]),
        acp_client_terminal: get_in(meta, [:acp_client_terminal]),
        acp_client_elicitation_form:
          Map.get(
            meta,
            :acp_client_elicitation_form,
            Map.get(meta, "acp_client_elicitation_form")
          ),
        acp_mcp_session_id:
          get_in(meta, [:acp_mcp_session_id]) || get_in(meta, ["acp_mcp_session_id"]),
        acp_client_fs_read_text_file: get_in(meta, [:acp_client_fs_read_text_file]),
        acp_client_fs_write_text_file: get_in(meta, [:acp_client_fs_write_text_file]),
        stream_options: get_opt(run_opts, :stream_options),
        resume_source: get_in(meta, [:resume_source]) || get_in(meta, ["resume_source"]),
        workspace_dir: workspace_dir,
        extra_tools: extra_tools,
        cwd_identity: Map.get(meta, :cwd_identity),
        # A trusted submitter (kanban) may confine file-mutation tools to one
        # directory; see `CodingAgent.Tools.FileValidation.confined/2`.
        confine_mutations_to: confinement(Map.get(meta, :mutation_root)),
        # A cron run (LemonAutomation.RunSubmitter) may update its own memory
        # file; `CodingAgent.Tools.OperatorState` admits only a
        # `cron_memory/<job>.md` path here and refuses other operator state.
        operator_state_grant: cron_memory_grant(Map.get(meta, :cron_memory_file))
      ]
      |> Presentation.build_session_opts(cwd, run_id, session_key, agent_id)

    case start_bound_session(cwd, resume, session_opts, state, meta) do
      {:ok, session, session_id, state} ->
        # Restored children launch before the prompt; subscription stays atomic
        # with the prompt (or the follow-up submission) below.
        :ok =
          CodingAgent.Tools.Task.Restore.restore_parent(run_id, meta,
            parent_session: session_id,
            session_pid: session,
            agent_id: agent_id,
            session_key: session_key
          )

        case async_followups do
          list when is_list(list) and list != [] ->
            _unsubscribe = CodingAgent.Session.subscribe(session)

            :ok =
              CodingAgent.Session.handle_async_followup(session, %{
                content: prompt,
                async_followups: list
              })

          _ ->
            # File commands come from the trusted config directory, never a
            # Bot folder used as the execution cwd.
            command_cwd = get_opt(run_opts, :config_cwd) || cwd

            prompt =
              CodingAgent.Commands.prepare_prompt(command_cwd, prompt, request.meta || %{})

            {:ok, _unsubscribe} =
              CodingAgent.Session.subscribe_prompt(session, prompt, images: request.images)
        end

        session_ref = Process.monitor(session)

        translator = %{
          state.translator
          | session_id: session_id,
            emitter_state: %{
              state.translator.emitter_state
              | session: session,
                session_id: session_id
            }
        }

        {:ok,
         %{
           state
           | session: session,
             session_ref: session_ref,
             session_id: session_id,
             translator: translator
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:steer, text}, _from, state) do
    case state.session do
      nil ->
        {:reply, {:error, :no_session}, state}

      session ->
        CodingAgent.Session.steer(session, text)
        {:reply, :ok, state}
    end
  end

  def handle_call({:redirect, text}, _from, state) do
    case state.session do
      nil ->
        {:reply, {:error, :no_session}, state}

      session ->
        CodingAgent.Session.redirect(session, text)
        {:reply, :ok, state}
    end
  end

  def handle_call({:cancel, reason}, _from, state) do
    translator = RunTranslator.mark_cancelled(state.translator, reason)

    if state.session do
      CodingAgent.Session.abort(state.session)
    end

    {:reply, :ok, %{state | translator: translator}}
  end

  @impl true
  def handle_info({:session_terminal, _, _}, %{translator: %{completed_emitted: true}} = state),
    do: {:noreply, state}

  def handle_info({:session_terminal, session_id, status}, %{session_id: session_id} = state) do
    # Transient delivery was fenced, but the owner persisted terminal truth before
    # this compact notification. Recover the canonical answer, not missed deltas.
    terminal_event = CodingAgent.Session.get_state(state.session).terminal_event

    messages =
      case terminal_event do
        {:agent_end, terminal_messages} -> terminal_messages
        _ -> CodingAgent.Session.get_messages(state.session)
      end
      |> Enum.reverse()
      |> Enum.take_while(&(Map.get(&1, :role) != :user))
      |> Enum.reverse()

    translator = state.translator

    translator =
      RunTranslator.replace_text(
        translator,
        Presentation.extract_answer(messages, nil) || RunTranslator.snapshot_text(translator)
      )

    event =
      case status do
        :completed ->
          {:agent_end, messages}

        :canceled ->
          {:canceled, :assistant_aborted}

        :error ->
          failed_message = Enum.find(Enum.reverse(messages), &match?(%{role: :assistant}, &1))
          reason = (failed_message && Map.get(failed_message, :error_message)) || :session_failed
          {:error, reason, %{messages: messages}}
      end

    event =
      case terminal_event do
        {:agent_end, _} -> event
        nil -> event
        terminal_event -> terminal_event
      end

    state = %{state | translator: RunTranslator.handle_event(translator, event)}
    if state.translator.completed_emitted, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info({:session_event, _, _, _}, %{translator: %{completed_emitted: true}} = state),
    do: {:noreply, state}

  def handle_info({:session_event, session_id, event, _cursor}, %{session_id: session_id} = state) do
    state = %{state | translator: RunTranslator.handle_event(state.translator, event)}
    if state.translator.completed_emitted, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{sink_ref: ref, sink_pid: pid} = state
      ) do
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{session_ref: ref, session: pid} = state
      ) do
    Logger.debug(
      "Lemon SessionRunner: Session process down: #{LemonCore.StatusRedaction.inspect_reason(reason)}"
    )

    {:stop, :normal,
     %{state | translator: RunTranslator.handle_session_down(state.translator, reason)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if not state.translator.completed_emitted and is_pid(state.session) and
         Process.alive?(state.session) do
      CodingAgent.Session.abort(state.session)
      Presentation.finalize_session(state)
    end

    :ok
  end

  # nil: unconfined. A malformed confinement fails closed (every mutation is
  # refused) rather than lifting the restriction.
  defp confinement(nil), do: nil
  defp confinement(root) when is_binary(root) and root != "", do: Path.expand(root)
  defp confinement(_root), do: :invalid

  defp cron_memory_grant(path) when is_binary(path) and path != "", do: path
  defp cron_memory_grant(_path), do: nil

  # A request may bind its working directory to the `{dev, inode}` identity a
  # trusted submitter checked (`meta.cwd_identity`, e.g. kanban workers and goal
  # runs); see `CodingAgent.CwdIdentity`. The session starts only in that exact
  # directory object, and its tools re-verify it before every call. Goal judge
  # and continuation runs must carry the binding.
  defp start_bound_session(cwd, resume, session_opts, state, meta) do
    with :ok <- require_goal_binding(meta),
         :ok <- CodingAgent.CwdIdentity.verify(cwd, Map.get(meta, :cwd_identity)),
         do: start_session(resume, session_opts, state, meta)
  end

  @goal_origins [:goal, :goal_judge, "goal", "goal_judge"]

  defp require_goal_binding(meta) do
    if Map.get(meta, :origin) in @goal_origins and is_nil(Map.get(meta, :cwd_identity)),
      do: {:error, :cwd_identity_mismatch},
      else: :ok
  end

  defp start_session(resume, session_opts, state, meta) do
    with :ok <- register_native_source_floor(session_opts, state.run_id),
         :ok <- CodingAgent.Workspace.validate_profile_instructions(meta[:profile_instructions]) do
      case Presentation.start_or_resume_session(resume, session_opts, state) do
        {:ok, session, session_id, _next_state} = result ->
          case checkpoint_native_resume(session, session_id, state.run_id, meta) do
            :ok ->
              result

            {:error, _reason} = error ->
              GenServer.stop(session, :normal)
              error
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp checkpoint_native_resume(_session, _session_id, nil, _meta), do: :ok

  defp checkpoint_native_resume(session, session_id, run_id, meta) do
    if CodingAgent.Tools.Task.Restore.enabled?(),
      do: persist_native_resume(session, session_id, run_id, meta),
      else: :ok
  end

  defp persist_native_resume(session, session_id, run_id, meta) do
    token = %LemonCore.ResumeToken{engine: @engine, value: session_id}

    with :ok <- CodingAgent.Session.save(session) do
      case LemonCore.RouterBridge.register_native_resume(run_id, token) do
        {:error, :unavailable} = error ->
          if Params.managed_metadata?(meta), do: error, else: :ok

        result ->
          result
      end
    end
  end

  defp register_native_source_floor(opts, actual_run_id) do
    source = %{
      run_id: Keyword.get(opts, :native_lineage_run_id),
      lineage_handle: Keyword.get(opts, :native_lineage_handle)
    }

    receipt =
      Keyword.get(opts, :native_source_floor_fun) ||
        (&LemonCore.RouterBridge.register_native_source_floor/2)

    if is_nil(source.run_id) and is_nil(source.lineage_handle) do
      if Keyword.get(opts, :native_managed_context) == true,
        do: receipt.(%{run_id: actual_run_id}, Keyword.get(opts, :tool_policy)),
        else: :ok
    else
      if source.run_id == actual_run_id and is_binary(source.lineage_handle) do
        receipt.(source, Keyword.get(opts, :tool_policy))
      else
        {:error, :invalid_native_source}
      end
    end
  catch
    _, _ -> {:error, :native_source_floor_unavailable}
  end

  defp extra_tools(%ExecutionRequest{} = request, opts) do
    cwd = request.cwd || get_opt(opts, :cwd) || File.cwd!()
    send_file_tools(request, opts) ++ sms_tools(cwd, request.session_key)
  end

  # Only an explicit run cwd (or profile workspace) is a send root; the process
  # cwd fallback is never one, so a cwd-less run cannot attach host files.
  defp send_file_tools(%ExecutionRequest{} = request, opts) do
    if SendFile.channel(request.session_key) do
      [
        SendFile.tool(request.cwd || get_opt(opts, :cwd),
          session_key: request.session_key,
          workspace_dir: profile_workspace(request.meta || %{})
        )
      ]
    else
      []
    end
  end

  # SMS tools are offered only when SMS ingress is usable (webhook enabled with
  # an auth token) and both the inbox and its listener are running; otherwise
  # their schemas are not offered to the model at all.
  defp sms_tools(cwd, session_key) do
    if LemonGateway.Sms.Inbox.available?() do
      [
        SmsGetInboxNumber.tool(cwd, session_key: session_key),
        SmsWaitForCode.tool(cwd, session_key: session_key),
        SmsListMessages.tool(cwd, session_key: session_key),
        SmsClaimMessage.tool(cwd, session_key: session_key),
        SmsReleaseInbox.tool(cwd, session_key: session_key)
      ]
    else
      []
    end
  end

  defp request_agent_id(request) do
    meta = request.meta || %{}

    agent_id =
      meta[:agent_id] ||
        meta["agent_id"] ||
        LemonCore.SessionKey.agent_id(request.session_key || "")

    case agent_id do
      id when is_binary(id) ->
        id = String.trim(id)
        if id == "", do: nil, else: id

      _ ->
        nil
    end
  end

  defp async_followups(request) do
    meta = request.meta || %{}
    meta[:async_followups] || meta["async_followups"]
  end

  @doc false
  def execution_tool_policy(request, cwd, run_opts \\ %{}) do
    meta = request.meta || %{}
    id = request_agent_id(request)
    profile_id = meta[:profile_id] || meta["profile_id"]
    config = LemonCore.Config.load_base_from_disk(get_opt(run_opts, :config_cwd) || cwd)

    ids =
      Enum.uniq([id, profile_id, LemonCore.SessionKey.agent_id(request.session_key || "")]) --
        [nil]

    floor =
      case destination_policy_floor(ids, config) do
        {:ok, policy} -> policy
        {:error, _} -> %{allow: []}
      end

    floor
    |> LemonCore.ToolPolicy.intersect(
      if request.execution_context, do: request.execution_context.tool_policy
    )
    |> LemonCore.ToolPolicy.intersect(request.tool_policy)
    |> LemonCore.ToolPolicy.intersect(
      meta[:tool_policy] || meta["tool_policy"] || meta["toolPolicy"]
    )
    |> LemonCore.ToolPolicy.intersect(get_opt(run_opts, :tool_policy))
  end

  @doc """
  Destination tool-policy floor for agent/profile `ids`: each id's
  `config.agents[id].tool_policy` intersected with its `ProfileStore`
  `toolPolicy`. A profile store read error is returned, never ignored.
  """
  @spec destination_policy_floor([String.t()], LemonCore.Config.t()) ::
          {:ok, map()} | {:error, term()}
  def destination_policy_floor(ids, config) when is_list(ids) do
    config_floor =
      Enum.reduce(ids, %{}, fn profile, policy ->
        LemonCore.ToolPolicy.intersect(policy, get_in(config.agents, [profile, :tool_policy]))
      end)

    Enum.reduce_while(ids, {:ok, config_floor}, fn profile, {:ok, policy} ->
      case LemonCore.ProfileStore.get(profile) do
        {:ok, stored} ->
          {:cont, {:ok, LemonCore.ToolPolicy.intersect(policy, stored["toolPolicy"])}}

        {:error, :not_found} ->
          {:cont, {:ok, policy}}

        {:error, reason} ->
          {:halt, {:error, {:profile_store, reason}}}
      end
    end)
  end

  @doc false
  @spec profile_workspace(map()) :: String.t()
  def profile_workspace(meta) when is_map(meta) do
    profile_id = meta[:profile_id] || meta["profile_id"]

    case LemonCore.ProfileStore.paths(profile_id) do
      {:ok, %{"workspace" => workspace}} -> workspace
      _ -> CodingAgent.Config.workspace_dir()
    end
  end

  def profile_workspace(_), do: CodingAgent.Config.workspace_dir()

  # Missing flag stays nil so direct paths keep "nonnil model means explicit".
  defp model_explicit_from_meta(meta) do
    case Map.get(meta, :model_explicit, Map.get(meta, "model_explicit")) do
      value when is_boolean(value) -> value
      _ -> nil
    end
  end

  # The router marks a profile or router-default model as operator-sourced.
  defp model_source_from_meta(meta) do
    if Map.get(meta, :model_source, Map.get(meta, "model_source")) in [:operator, "operator"],
      do: :operator
  end

  # A delegating session's admitted model may carry its project origin (only
  # that tightening value is honored).
  defp model_origin_from_meta(meta) do
    if Map.get(meta, :model_origin, Map.get(meta, "model_origin")) in [:project, "project"],
      do: :project
  end
end
