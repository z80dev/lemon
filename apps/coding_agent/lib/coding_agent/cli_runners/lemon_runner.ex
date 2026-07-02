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

  alias AgentCore.CliRunners.Types.{
    Action,
    EventFactory
  }

  alias LemonCore.ResumeToken

  alias AgentCore.EventStream
  alias CodingAgent.Session.Presentation

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
    :factory,
    :prompt,
    :cwd,
    :resume,
    :accumulated_text,
    :pending_actions,
    :reasoning_accumulator,
    :started_emitted,
    :completed_emitted,
    # Delta streaming support
    :run_id,
    :delta_seq,
    :delta_callback,
    :first_token_emitted
  ]

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

    # Initialize state
    state = %__MODULE__{
      stream: stream,
      factory: EventFactory.new(@engine),
      prompt: prompt,
      cwd: cwd,
      resume: resume,
      accumulated_text: "",
      pending_actions: %{},
      reasoning_accumulator: Presentation.new_reasoning_accumulator(),
      started_emitted: false,
      completed_emitted: false,
      # Delta streaming
      run_id: run_id,
      delta_seq: 0,
      delta_callback: delta_callback,
      first_token_emitted: false
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
        state = %{state | session: session, session_ref: session_ref, session_id: session_id}

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
    handle_cancel(:user_requested, state)
  end

  def handle_cast({:cancel, reason}, state) do
    handle_cancel(reason, state)
  end

  defp handle_cancel(reason, state) do
    if state.session do
      CodingAgent.Session.abort(state.session)
    end

    # Emit completed event if not already done
    state =
      if state.started_emitted and not state.completed_emitted do
        emit_completed_error(state, Presentation.cancel_error_message(reason))
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:session_event, _session_id, event}, state) do
    state = translate_and_emit(event, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.debug("LemonRunner: Session process down: #{inspect(reason)}")

    # Emit error completion if not already completed
    state =
      if state.started_emitted and not state.completed_emitted do
        emit_completed_error(state, "Session terminated: #{inspect(reason)}")
      else
        state
      end

    {:stop, :normal, state}
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

  # ============================================================================
  # Event Translation
  # ============================================================================

  defp translate_and_emit({:agent_start}, state) do
    # Emit StartedEvent
    token = ResumeToken.new(@engine, state.session_id)
    {event, factory} = EventFactory.started(state.factory, token, meta: %{cwd: state.cwd})

    emit_event(state.stream, event)
    %{state | factory: factory, started_emitted: true}
  end

  defp translate_and_emit({:tool_execution_start, id, name, args}, state) do
    action_id = "tool_#{id}"
    kind = Presentation.tool_kind(name)
    title = Presentation.tool_title(name, args)
    detail = %{name: name, args: args}

    action = Action.new(action_id, kind, title, detail)

    {event, factory} =
      EventFactory.action_started(state.factory, action_id, kind, title, detail: detail)

    emit_event(state.stream, event)
    pending = Map.put(state.pending_actions, action_id, action)
    %{state | factory: factory, pending_actions: pending}
  end

  defp translate_and_emit({:tool_execution_update, id, _name, _args, partial_result}, state) do
    action_id = "tool_#{id}"

    case Map.get(state.pending_actions, action_id) do
      nil ->
        state

      action ->
        detail = Map.merge(action.detail, %{partial_result: partial_result})

        {event, factory} =
          EventFactory.action_updated(state.factory, action_id, action.kind, action.title,
            detail: detail
          )

        emit_event(state.stream, event)

        updated_action = %{action | detail: detail}
        pending = Map.put(state.pending_actions, action_id, updated_action)
        %{state | factory: factory, pending_actions: pending}
    end
  end

  defp translate_and_emit({:tool_execution_end, id, name, result, is_error}, state) do
    action_id = "tool_#{id}"

    case Map.get(state.pending_actions, action_id) do
      nil ->
        # Tool wasn't tracked, create standalone completed action
        kind = Presentation.tool_kind(name)
        title = Presentation.tool_title(name, %{})

        detail =
          %{name: name, result: Presentation.truncate_result(result)}
          |> Presentation.maybe_put_result_meta(result, name)

        ok? = Presentation.action_ok?(name, result, is_error)

        {event, factory} =
          EventFactory.action_completed(
            state.factory,
            action_id,
            kind,
            title,
            ok?,
            detail: detail
          )

        emit_event(state.stream, event)
        %{state | factory: factory}

      action ->
        detail =
          action.detail
          |> Map.merge(%{result: Presentation.truncate_result(result)})
          |> Presentation.maybe_put_result_meta(result, name)

        ok? = Presentation.action_ok?(name, result, is_error)

        {event, factory} =
          EventFactory.action_completed(
            state.factory,
            action_id,
            action.kind,
            action.title,
            ok?,
            detail: detail
          )

        emit_event(state.stream, event)

        pending = Map.delete(state.pending_actions, action_id)
        %{state | factory: factory, pending_actions: pending}
    end
  end

  defp translate_and_emit({:message_update, _msg, delta}, state) when is_binary(delta) do
    # Emit delta event for streaming
    state = emit_delta(state, delta)

    # Accumulate text for final answer
    %{state | accumulated_text: state.accumulated_text <> delta}
  end

  defp translate_and_emit({:message_update, msg, event}, state) when is_tuple(event) do
    case emit_reasoning_action(event, state) do
      {true, state} ->
        state

      {false, state} ->
        case Presentation.text_delta_from_message_update(msg, event, state.accumulated_text) do
          text when is_binary(text) and text != "" ->
            state = emit_delta(state, text)
            %{state | accumulated_text: state.accumulated_text <> text}

          _ ->
            state
        end
    end
  end

  defp translate_and_emit({:message_update, _msg, _delta}, state) do
    state
  end

  defp translate_and_emit({:agent_end, messages}, state) do
    # Extract final answer from messages
    answer = Presentation.extract_answer(messages, state.accumulated_text)

    # Build usage stats if available
    usage = Presentation.build_usage(messages)

    emit_completed_ok(state, answer, usage)
  end

  defp translate_and_emit({:error, reason, partial_state}, state) do
    error_msg = Presentation.format_error(reason, state)

    Logger.error(
      "LemonRunner stream error " <>
        "run_id=#{inspect(state.run_id)} " <>
        "session_id=#{inspect(state.session_id)} " <>
        "error=#{error_msg} " <>
        "reason=#{inspect(reason, limit: 80, printable_limit: 8_000)} " <>
        "answer_bytes=#{byte_size(state.accumulated_text || "")} " <>
        "pending_actions=#{map_size(state.pending_actions || %{})}"
    )

    emit_completed_error(state, error_msg, partial_state)
  end

  defp translate_and_emit({:turn_start}, state), do: state
  defp translate_and_emit({:turn_end, _msg, _results}, state), do: state
  defp translate_and_emit({:message_start, _msg}, state), do: state
  defp translate_and_emit({:message_end, _msg}, state), do: state
  defp translate_and_emit({:extension_status_report, _report}, state), do: state
  defp translate_and_emit({:compaction_complete, _info}, state), do: state
  defp translate_and_emit({:branch_summarized, _info}, state), do: state
  defp translate_and_emit(_event, state), do: state

  # Emit a delta event for streaming output
  defp emit_delta(state, text) when is_binary(text) and byte_size(text) > 0 do
    new_seq = state.delta_seq + 1

    # Track first token for telemetry
    state =
      if not state.first_token_emitted do
        # Optionally emit first token telemetry if we have a callback
        if state.delta_callback do
          state.delta_callback.(:first_token, %{run_id: state.run_id, seq: new_seq})
        end

        %{state | first_token_emitted: true}
      else
        state
      end

    # Create delta event
    delta_event = %{
      type: :delta,
      run_id: state.run_id,
      ts_ms: System.system_time(:millisecond),
      seq: new_seq,
      text: text
    }

    # Emit to stream as a delta event
    emit_event(state.stream, {:delta, delta_event})

    # Call delta callback if provided (for gateway integration)
    if state.delta_callback do
      state.delta_callback.(:delta, delta_event)
    end

    %{state | delta_seq: new_seq}
  end

  defp emit_delta(state, _text), do: state

  defp emit_reasoning_action(event, state) do
    case Presentation.reasoning_action(event, state.reasoning_accumulator) do
      {:emit, action, accumulator} ->
        {event, factory} =
          EventFactory.action(state.factory,
            phase: action.phase,
            action_id: action.id,
            kind: action.kind,
            title: action.title,
            ok: action.ok,
            detail: action.detail
          )

        emit_event(state.stream, event)
        {true, %{state | factory: factory, reasoning_accumulator: accumulator}}

      {:skip, %Presentation.ReasoningAccumulator{} = accumulator} ->
        handled? =
          match?({kind, _, _} when kind in [:thinking_start, :thinking_end], event) or
            match?({:thinking_delta, _, _, _}, event)

        {handled?, %{state | reasoning_accumulator: accumulator}}
    end
  end

  @doc false
  def text_delta_from_message_update(msg, event, accumulated_text \\ "") do
    Presentation.text_delta_from_message_update(msg, event, accumulated_text)
  end

  # ============================================================================
  # Completion Helpers
  # ============================================================================

  defp emit_completed_ok(state, answer, usage) do
    if state.completed_emitted do
      state
    else
      token = state.factory.resume

      {event, factory} =
        EventFactory.completed_ok(state.factory, answer, resume: token, usage: usage)

      emit_event(state.stream, event)
      EventStream.complete(state.stream, [])
      state = %{state | factory: factory, completed_emitted: true}
      Presentation.finalize_session(state)
    end
  end

  defp emit_completed_error(state, error_msg, partial_state \\ nil) do
    if state.completed_emitted do
      state
    else
      token = state.factory.resume
      answer = state.accumulated_text
      usage = Presentation.build_failure_usage(state, partial_state)

      {event, factory} =
        EventFactory.completed_error(state.factory, error_msg,
          resume: token,
          answer: answer,
          usage: usage
        )

      emit_event(state.stream, event)
      EventStream.complete(state.stream, [])
      state = %{state | factory: factory, completed_emitted: true}
      Presentation.finalize_session(state)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp emit_event(stream, event) do
    EventStream.push_async(stream, {:cli_event, event})
  end
end
