defmodule CodingAgent.CliRunners.LemonRunner do
  @moduledoc """
  Native Lemon engine runner that wraps CodingAgent.Session.

  Unlike ClaudeRunner and CodexRunner which manage CLI subprocesses,
  LemonRunner wraps the native CodingAgent.Session and translates its
  events to the unified CLI runner event model.

  ## Features

  - Session lifecycle management (start, resume, cancel)
  - Event translation from CodingAgent events to normalized events
  - Steering support (inject messages mid-run)
  - Follow-up queue support (queue messages for after run completes)

  ## Event Translation

  CodingAgent events are mapped as follows:

  | CodingAgent Event              | Normalized Event                    |
  |-------------------------------|-------------------------------------|
  | `{:agent_start}`              | `StartedEvent`                      |
  | `{:tool_execution_start, ...}`| `ActionEvent` (phase: :started)     |
  | `{:tool_execution_update,...}`| `ActionEvent` (phase: :updated)     |
  | `{:tool_execution_end, ...}`  | `ActionEvent` (phase: :completed)   |
  | `{:message_update, ...}`      | Text accumulation (for answer)      |
  | `{:agent_end, ...}`           | `CompletedEvent`                    |
  | `{:error, ...}`               | `CompletedEvent` (ok: false)        |

  Completed tool actions preserve structured `AgentToolResult.details` failure metadata
  under `action.detail.result_meta`, including `:error_type` for unknown tools,
  invalid arguments, task crashes, timeouts, aborted tool calls, and nonzero
  command exits.

  ## Example

      {:ok, pid} = LemonRunner.start_link(
        prompt: "Create a GenServer",
        cwd: "/path/to/project"
      )

      stream = LemonRunner.stream(pid)

      for event <- AgentCore.EventStream.events(stream) do
        case event do
          {:cli_event, %StartedEvent{resume: token}} ->
            IO.puts("Session: \#{token.value}")

          {:cli_event, %ActionEvent{action: action, phase: :completed}} ->
            IO.puts("Tool done: \#{action.title}")

          {:cli_event, %CompletedEvent{answer: answer}} ->
            IO.puts("Answer: \#{answer}")
        end
      end

  """

  use GenServer

  alias AgentCore.CliRunners.Types.EventFactory

  alias LemonCore.ResumeToken

  alias AgentCore.EventStream
  alias CodingAgent.Session.Presentation
  alias CodingAgent.Session.RunTranslator

  require Logger

  @engine "lemon"

  # ============================================================================
  # Types
  # ============================================================================

  @type start_opts :: [
          prompt: String.t(),
          cwd: String.t(),
          resume: ResumeToken.t() | nil,
          timeout: non_neg_integer(),
          model: term(),
          thinking_level: term(),
          images: [map()],
          system_prompt: String.t() | nil,
          async_followups: [map()],
          stream_fn: function()
        ]

  defstruct [
    :session,
    :session_ref,
    :session_id,
    :stream,
    :prompt,
    :cwd,
    :resume,
    :run_id,
    :translator
  ]

  defmodule Emitter do
    @moduledoc false

    @behaviour CodingAgent.Session.RunTranslator.Emitter

    alias AgentCore.CliRunners.Types.EventFactory
    alias AgentCore.EventStream
    alias CodingAgent.Session.Presentation

    defstruct [:stream, :factory, :session]

    @impl true
    def emit_started(state, fields) do
      {event, factory} = EventFactory.started(state.factory, fields.resume, meta: fields.meta)

      emit_event(state.stream, event)
      %{state | factory: factory}
    end

    @impl true
    def emit_action_event(state, fields) do
      {event, factory} =
        EventFactory.action(state.factory,
          phase: fields.phase,
          action_id: fields.id,
          kind: fields.kind,
          title: fields.title,
          ok: fields.ok,
          detail: fields.detail,
          message: fields.message,
          level: fields.level
        )

      emit_event(state.stream, event)
      %{state | factory: factory}
    end

    @impl true
    def emit_delta(state, _text, delta_event) do
      emit_event(state.stream, {:delta, delta_event})
      state
    end

    @impl true
    def emit_completed(state, %{ok: true} = fields) do
      {event, factory} =
        EventFactory.completed_ok(state.factory, fields.answer,
          resume: fields.resume,
          usage: fields.usage
        )

      emit_event(state.stream, event)
      EventStream.complete(state.stream, [])

      %{state | factory: factory}
      |> Presentation.finalize_session()
    end

    def emit_completed(state, fields) do
      {event, factory} =
        EventFactory.completed_error(state.factory, fields.error,
          resume: fields.resume,
          answer: fields.answer,
          usage: fields.usage
        )

      emit_event(state.stream, event)
      EventStream.complete(state.stream, [])

      %{state | factory: factory}
      |> Presentation.finalize_session()
    end

    defp emit_event(stream, event) do
      EventStream.push_async(stream, {:cli_event, event})
    end
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a LemonRunner process.

  ## Options

  - `:prompt` - The initial prompt (required)
  - `:cwd` - Working directory (default: current directory)
  - `:resume` - ResumeToken for resuming an existing session
  - `:timeout` - Stream timeout in ms (default: `:infinity`)
  - `:approval_timeout_ms` - Approval wait timeout for tool calls that require approval (default: `:infinity`)
  - `:model` - Model to use (optional, uses session default)
  - `:thinking_level` - Thinking level to use (optional, uses session default)
  - `:system_prompt` - Custom system prompt (optional)

  """
  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Get the event stream for this runner.

  Returns an EventStream that emits `{:cli_event, event}` tuples
  where event is one of StartedEvent, ActionEvent, or CompletedEvent.
  """
  @spec stream(pid()) :: EventStream.t()
  def stream(pid) do
    GenServer.call(pid, :get_stream)
  end

  @doc """
  Cancel the running session.

  Sends an abort signal to the underlying CodingAgent.Session.
  """
  @spec cancel(pid()) :: :ok
  @spec cancel(pid(), term()) :: :ok
  def cancel(pid, reason \\ :user_requested) do
    GenServer.cast(pid, {:cancel, reason})
  end

  @doc """
  Inject a steering message mid-run.

  The message will be processed by the agent during the current run,
  potentially interrupting its current line of work.
  """
  @spec steer(pid(), String.t()) :: :ok | {:error, term()}
  def steer(pid, text) do
    GenServer.call(pid, {:steer, text})
  end

  @doc """
  Queue a follow-up message for after the run completes.

  The message will be delivered after the current agent turn finishes.
  """
  @spec follow_up(pid(), String.t()) :: :ok | {:error, term()}
  def follow_up(pid, text) do
    GenServer.call(pid, {:follow_up, text})
  end

  @doc """
  Check if this engine supports steering.

  Lemon native always supports steering.
  """
  @spec supports_steer?() :: boolean()
  def supports_steer?, do: true

  @doc "Get the engine identifier"
  @spec engine() :: String.t()
  def engine, do: @engine

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    resume = Keyword.get(opts, :resume)
    # Tool calls should not time out by default; allow callers to opt in.
    timeout = Keyword.get(opts, :timeout, :infinity)
    model = Keyword.get(opts, :model)
    thinking_level = Keyword.get(opts, :thinking_level)
    images = Keyword.get(opts, :images, [])
    system_prompt = Keyword.get(opts, :system_prompt)
    async_followups = Keyword.get(opts, :async_followups)
    approval_timeout_ms = Keyword.get(opts, :approval_timeout_ms, :infinity)
    extra_tools = Keyword.get(opts, :extra_tools)
    stream_fn = Keyword.get(opts, :stream_fn)
    owner = Keyword.get(opts, :owner, self())

    # Create the event stream
    {:ok, stream} =
      EventStream.start_link(
        max_queue: 10_000,
        drop_strategy: :drop_oldest,
        owner: owner,
        timeout: timeout
      )

    # Delta streaming configuration
    run_id = Keyword.get(opts, :run_id)
    delta_callback = Keyword.get(opts, :delta_callback)

    emitter_state = %Emitter{stream: stream, factory: EventFactory.new(@engine)}

    translator =
      RunTranslator.new(
        emitter: Emitter,
        emitter_state: emitter_state,
        engine: @engine,
        label: "LemonRunner",
        cwd: cwd,
        run_id: run_id,
        delta_callback: delta_callback
      )

    state = %__MODULE__{
      stream: stream,
      prompt: prompt,
      cwd: cwd,
      resume: resume,
      run_id: run_id,
      translator: translator
    }

    session_key = Keyword.get(opts, :session_key)
    agent_id = Keyword.get(opts, :agent_id)

    session_opts =
      opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:thinking_level, thinking_level)
      |> Keyword.put(:system_prompt, system_prompt)
      |> Keyword.put(:stream_fn, stream_fn)
      |> Keyword.put(:tool_policy, Keyword.get(opts, :tool_policy))
      |> Keyword.put(:approval_timeout_ms, approval_timeout_ms)
      |> Keyword.put(:extra_tools, extra_tools)
      |> Presentation.build_session_opts(cwd, run_id, session_key, agent_id)

    # Start or resume session
    case Presentation.start_or_resume_session(resume, session_opts, state) do
      {:ok, session, session_id, state} ->
        # Subscribe to session events
        {:ok, _stream} = CodingAgent.Session.subscribe(session, mode: :stream, max_queue: 10_000)

        # We subscribe ourselves directly for event processing
        _unsub = CodingAgent.Session.subscribe(session)

        # Send the prompt to start the agent
        case async_followups do
          list when is_list(list) and list != [] ->
            :ok =
              CodingAgent.Session.handle_async_followup(session, %{
                content: prompt,
                async_followups: list
              })

          _ ->
            :ok = CodingAgent.Session.prompt(session, prompt, images: images)
        end

        session_ref = Process.monitor(session)

        translator = %{
          state.translator
          | session_id: session_id,
            emitter_state: %{state.translator.emitter_state | session: session}
        }

        state = %{
          state
          | session: session,
            session_ref: session_ref,
            session_id: session_id,
            translator: translator
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_stream, _from, state) do
    {:reply, state.stream, state}
  end

  def handle_call({:steer, text}, _from, state) do
    case state.session do
      nil ->
        {:reply, {:error, :no_session}, state}

      session ->
        CodingAgent.Session.steer(session, text)
        {:reply, :ok, state}
    end
  end

  def handle_call({:follow_up, text}, _from, state) do
    case state.session do
      nil ->
        {:reply, {:error, :no_session}, state}

      session ->
        CodingAgent.Session.follow_up(session, text)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast(:cancel, state) do
    handle_cancel(state, :user_requested)
  end

  def handle_cast({:cancel, reason}, state) do
    handle_cancel(state, reason)
  end

  defp handle_cancel(state, reason) do
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
    Logger.debug("LemonRunner: Session process down: #{inspect(reason)}")

    {:stop, :normal,
     %{state | translator: RunTranslator.handle_session_down(state.translator, reason)}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.stream do
      EventStream.complete(state.stream, [])
    end

    :ok
  end

  @doc false
  def text_delta_from_message_update(msg, event, accumulated_text \\ "") do
    Presentation.text_delta_from_message_update(msg, event, accumulated_text)
  end
end
