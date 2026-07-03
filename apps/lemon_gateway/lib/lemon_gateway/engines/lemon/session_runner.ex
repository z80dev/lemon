defmodule LemonGateway.Engines.Lemon.SessionRunner do
  @moduledoc false

  use GenServer

  alias CodingAgent.Session.Presentation
  alias CodingAgent.Session.RunTranslator
  alias LemonCore.ResumeToken
  alias LemonGateway.Types.Job

  require Logger

  @engine "lemon"

  defstruct [
    :session,
    :session_ref,
    :session_id,
    :sink_pid,
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
      event = Event.completed(fields)

      emit_event(state, event)
      Presentation.finalize_session(state)
    end

    defp emit_event(state, event) do
      send(state.sink_pid, {:engine_event, state.run_ref, event})
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def cancel(pid, reason \\ :user_requested) do
    GenServer.cast(pid, {:cancel, reason})
  end

  def steer(pid, text) do
    GenServer.call(pid, {:steer, text})
  end

  @impl true
  def init(opts) do
    case LemonGateway.DependencyManager.ensure_app(:coding_agent) do
      :ok ->
        init_session(opts)

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp init_session(opts) do
    job = Keyword.fetch!(opts, :job)
    run_opts = Keyword.get(opts, :opts, %{})
    sink_pid = Keyword.fetch!(opts, :sink_pid)
    run_ref = Keyword.fetch!(opts, :run_ref)

    prompt = job.prompt
    cwd = job.cwd || get_opt(run_opts, :cwd) || File.cwd!()
    resume = normalize_resume(job.resume)
    run_id = job.run_id || get_opt(run_opts, :run_id)
    session_key = job.session_key
    agent_id = job_agent_id(job)
    async_followups = async_followups(job)
    extra_tools = gateway_extra_tools(job, run_opts)
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

    session_opts =
      [
        model: get_in(job.meta || %{}, [:model]),
        thinking_level: get_in(job.meta || %{}, [:thinking_level]),
        system_prompt: get_in(job.meta || %{}, [:system_prompt]),
        stream_fn: stream_fn,
        tool_policy: job.tool_policy,
        approval_timeout_ms: get_opt(run_opts, :approval_timeout_ms),
        acp_session_id: get_in(job.meta || %{}, [:acp_session_id]),
        acp_client_fs_read_text_file: get_in(job.meta || %{}, [:acp_client_fs_read_text_file]),
        acp_client_fs_write_text_file: get_in(job.meta || %{}, [:acp_client_fs_write_text_file]),
        stream_options: get_opt(run_opts, :stream_options),
        extra_tools: extra_tools
      ]
      |> Presentation.build_session_opts(cwd, run_id, session_key, agent_id)

    case Presentation.start_or_resume_session(resume, session_opts, state) do
      {:ok, session, session_id, state} ->
        {:ok, _stream} = CodingAgent.Session.subscribe(session, mode: :stream, max_queue: 10_000)
        _unsub = CodingAgent.Session.subscribe(session)

        case async_followups do
          list when is_list(list) and list != [] ->
            :ok =
              CodingAgent.Session.handle_async_followup(session, %{
                content: prompt,
                async_followups: list
              })

          _ ->
            :ok = CodingAgent.Session.prompt(session, prompt, images: job.images)
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

  @impl true
  def handle_cast({:cancel, reason}, state) do
    if state.session do
      CodingAgent.Session.abort(state.session)
    end

    {:noreply, %{state | translator: RunTranslator.handle_cancel(state.translator, reason)}}
  end

  @impl true
  def handle_info({:session_event, _session_id, event}, state) do
    {:noreply, %{state | translator: RunTranslator.handle_event(state.translator, event)}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.debug("Lemon SessionRunner: Session process down: #{inspect(reason)}")

    {:stop, :normal,
     %{state | translator: RunTranslator.handle_session_down(state.translator, reason)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp normalize_resume(%ResumeToken{engine: @engine} = token), do: token

  defp normalize_resume(%{engine: @engine, value: value}) when is_binary(value),
    do: ResumeToken.new(@engine, value)

  defp normalize_resume(_), do: nil

  defp gateway_extra_tools(%Job{} = job, opts) do
    cwd = job.cwd || get_opt(opts, :cwd) || File.cwd!()

    cron_tool =
      LemonGateway.Tools.Cron.tool(
        cwd,
        session_key: job.session_key,
        agent_id: job_agent_id(job)
      )

    sms_tools = [
      cron_tool,
      LemonGateway.Tools.SmsGetInboxNumber.tool(cwd),
      LemonGateway.Tools.SmsWaitForCode.tool(cwd, session_key: job.session_key),
      LemonGateway.Tools.SmsListMessages.tool(cwd, session_key: job.session_key),
      LemonGateway.Tools.SmsClaimMessage.tool(cwd, session_key: job.session_key)
    ]

    workspace_dir = CodingAgent.Config.workspace_dir()

    cond do
      telegram_session?(job) ->
        [
          LemonGateway.Tools.TelegramSendImage.tool(
            cwd,
            session_key: job.session_key,
            workspace_dir: workspace_dir
          )
          | sms_tools
        ]

      discord_session?(job) ->
        [
          LemonGateway.Tools.DiscordSendFile.tool(
            cwd,
            session_key: job.session_key,
            workspace_dir: workspace_dir
          )
          | sms_tools
        ]

      true ->
        sms_tools
    end
  end

  defp telegram_session?(job) do
    case LemonCore.SessionKey.parse(job.session_key || "") do
      %{kind: :channel_peer, channel_id: "telegram"} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp discord_session?(job) do
    case LemonCore.SessionKey.parse(job.session_key || "") do
      %{kind: :channel_peer, channel_id: "discord"} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp job_agent_id(job) do
    meta = job.meta || %{}

    agent_id =
      meta[:agent_id] ||
        meta["agent_id"] ||
        LemonCore.SessionKey.agent_id(job.session_key || "")

    case agent_id do
      id when is_binary(id) ->
        id = String.trim(id)
        if id == "", do: nil, else: id

      _ ->
        nil
    end
  end

  defp async_followups(job) do
    meta = job.meta || %{}
    meta[:async_followups] || meta["async_followups"]
  end

  defp get_opt(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp get_opt(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp get_opt(_opts, _key), do: nil
end
