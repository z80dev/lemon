defmodule CodingAgent.Executor.SessionRunner do
  @moduledoc false

  use GenServer

  alias CodingAgent.Session.Presentation
  alias CodingAgent.Executor.RemoteRequestCodec
  alias CodingAgent.Session.RunTranslator
  alias LemonCore.ResumeToken
  alias LemonGateway.ExecutionRequest

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
    :mcp_session_id,
    :translator
  ]

  defmodule Emitter do
    @moduledoc false

    @behaviour CodingAgent.Session.RunTranslator.Emitter

    alias CodingAgent.Session.Presentation
    alias LemonGateway.Event

    defstruct [:sink_pid, :run_ref, :session]

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
      # A queued auto-resume may start as soon as the gateway sees completion.
      # Save and stop this session first so it loads the complete prior turn.
      state = Presentation.finalize_session(state, fields.ok == true)

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
        thinking_level: get_in(meta, [:thinking_level]),
        system_prompt: get_in(meta, [:system_prompt]),
        profile_instructions: get_in(meta, [:profile_instructions]),
        stream_fn: stream_fn,
        tool_policy: tool_policy,
        invocation_context_key: LemonCore.MapHelpers.get_key(meta, :invocation_context_key),
        memory_context_key: LemonCore.MapHelpers.get_key(meta, :memory_context_key),
        memory_context_verified:
          Map.get(meta, :memory_context_verified, Map.get(meta, "memory_context_verified")) ==
            true,
        shared_memory_grant:
          Map.get(meta, :shared_memory_grant, Map.get(meta, "shared_memory_grant")) == true,
        invocation_mcp_servers: Map.get(meta, :mcp_servers),
        native_managed_context: CodingAgent.Tools.Task.Params.managed_metadata?(meta),
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
        extra_tools: extra_tools
      ]
      |> Presentation.build_session_opts(cwd, run_id, session_key, agent_id)

    case start_session(resume, session_opts, state, meta) do
      {:ok, session, session_id, state} ->
        _unsub = CodingAgent.Session.subscribe(session)

        case async_followups do
          list when is_list(list) and list != [] ->
            :ok =
              CodingAgent.Session.handle_async_followup(session, %{
                content: prompt,
                async_followups: list
              })

          _ ->
            prompt = CodingAgent.Commands.prepare_prompt(cwd, prompt, request.meta || %{})
            :ok = CodingAgent.Session.prompt(session, prompt, images: request.images)
        end

        session_ref = Process.monitor(session)

        translator = %{
          state.translator
          | session_id: session_id,
            emitter_state: %{state.translator.emitter_state | session: session}
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
        emit_resume_failure(state, reason)
        {:stop, reason}
    end
  end

  defp emit_resume_failure(state, reason) do
    completed =
      LemonGateway.Event.completed(%{
        engine: @engine,
        ok: false,
        error: reason,
        answer: ""
      })

    send(state.sink_pid, {:engine_event, state.run_ref, completed})
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
    messages = CodingAgent.Session.get_messages(state.session)
    translator = state.translator

    translator = %{
      translator
      | accumulated_text: Presentation.extract_answer(messages, translator.accumulated_text)
    }

    event =
      case status do
        :completed -> {:agent_end, messages}
        :canceled -> {:canceled, :assistant_aborted}
        :error -> {:error, :session_failed, %{messages: messages}}
      end

    {:noreply, %{state | translator: RunTranslator.handle_event(translator, event)}}
  end

  def handle_info({:session_event, _, _}, %{translator: %{completed_emitted: true}} = state),
    do: {:noreply, state}

  def handle_info({:session_event, session_id, event}, %{session_id: session_id} = state) do
    {:noreply, %{state | translator: RunTranslator.handle_event(state.translator, event)}}
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
    Logger.debug("Lemon SessionRunner: Session process down: #{inspect(reason)}")

    {:stop, :normal,
     %{state | translator: RunTranslator.handle_session_down(state.translator, reason)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.mcp_session_id, do: LemonSkills.McpSession.close(state.mcp_session_id)

    if is_pid(state.session) and Process.alive?(state.session) do
      CodingAgent.Session.abort(state.session)
      Presentation.finalize_session(state)
    end

    :ok
  end

  defp start_session(resume, session_opts, state, meta) do
    with :ok <- register_native_source_floor(session_opts, state.run_id),
         :ok <- CodingAgent.Workspace.validate_profile_instructions(meta[:profile_instructions]),
         {:ok, mcp_session_id} <- open_profile_mcp(meta, state.cwd) do
      state = %{state | mcp_session_id: mcp_session_id}
      session_opts = Keyword.put(session_opts, :mcp_session_id, mcp_session_id)

      case Presentation.start_or_resume_session(resume, session_opts, state) do
        {:ok, _session, _session_id, _state} = result ->
          result

        {:error, _reason} = error ->
          if mcp_session_id, do: LemonSkills.McpSession.close(mcp_session_id)
          error
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

  defp open_profile_mcp(meta, cwd) do
    case Map.get(meta, :mcp_servers) do
      servers when servers in [nil, []] ->
        {:ok, nil}

      servers ->
        id = "profile-mcp-#{System.unique_integer([:positive, :monotonic])}"

        case LemonSkills.McpSession.open_http(id, cwd, servers, self()) do
          :ok -> {:ok, id}
          {:error, reason} -> {:error, {:profile_mcp, reason}}
        end
    end
  end

  defp normalize_resume(%ResumeToken{engine: @engine} = token), do: token

  defp normalize_resume(%{engine: @engine, value: value}) when is_binary(value),
    do: ResumeToken.new(@engine, value)

  defp normalize_resume(_), do: nil

  defp extra_tools(%ExecutionRequest{} = request, opts) do
    cwd = request.cwd || get_opt(opts, :cwd) || File.cwd!()

    sms_tools = [
      LemonGateway.Tools.SmsGetInboxNumber.tool(cwd),
      LemonGateway.Tools.SmsWaitForCode.tool(cwd, session_key: request.session_key),
      LemonGateway.Tools.SmsListMessages.tool(cwd, session_key: request.session_key),
      LemonGateway.Tools.SmsClaimMessage.tool(cwd, session_key: request.session_key)
    ]

    workspace_dir = profile_workspace(request.meta || %{})

    cond do
      telegram_session?(request) ->
        [
          LemonGateway.Tools.TelegramSendImage.tool(
            cwd,
            session_key: request.session_key,
            workspace_dir: workspace_dir
          )
          | sms_tools
        ]

      discord_session?(request) ->
        [
          LemonGateway.Tools.DiscordSendFile.tool(
            cwd,
            session_key: request.session_key,
            workspace_dir: workspace_dir
          )
          | sms_tools
        ]

      true ->
        sms_tools
    end
  end

  defp telegram_session?(request) do
    case LemonCore.SessionKey.parse(request.session_key || "") do
      %{kind: :channel_peer, channel_id: "telegram"} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp discord_session?(request) do
    case LemonCore.SessionKey.parse(request.session_key || "") do
      %{kind: :channel_peer, channel_id: "discord"} -> true
      _ -> false
    end
  rescue
    _ -> false
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
    config = LemonCore.Config.load_base_from_disk(cwd)

    ids =
      Enum.uniq([id, profile_id, LemonCore.SessionKey.agent_id(request.session_key || "")]) --
        [nil]

    destination_policy =
      Enum.reduce(ids, %{}, fn profile, policy ->
        LemonCore.ToolPolicy.intersect(policy, get_in(config.agents, [profile, :tool_policy]))
      end)

    floor =
      Enum.reduce(ids, destination_policy, fn profile, policy ->
        case LemonCore.ProfileStore.get(profile) do
          {:ok, stored} -> LemonCore.ToolPolicy.intersect(policy, stored["toolPolicy"])
          {:error, :not_found} -> policy
          {:error, _} -> LemonCore.ToolPolicy.intersect(policy, %{allow: []})
        end
      end)

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

  defp get_opt(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp get_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp get_opt(_opts, _key), do: nil
end
