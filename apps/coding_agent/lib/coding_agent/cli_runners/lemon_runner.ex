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
    EventFactory,
    ResumeToken
  }

  alias AgentCore.EventStream

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
          system_prompt: String.t() | nil
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
  - `:timeout` - Stream timeout in ms (default: 10 minutes)
  - `:model` - Model to use (optional, uses session default)
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
  def cancel(pid) do
    GenServer.cast(pid, :cancel)
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
    timeout = Keyword.get(opts, :timeout, 600_000)
    model = Keyword.get(opts, :model)
    system_prompt = Keyword.get(opts, :system_prompt)

    # Create the event stream
    {:ok, stream} =
      EventStream.start_link(
        max_queue: 10_000,
        drop_strategy: :drop_oldest,
        owner: self(),
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
      started_emitted: false,
      completed_emitted: false,
      # Delta streaming
      run_id: run_id,
      delta_seq: 0,
      delta_callback: delta_callback,
      first_token_emitted: false
    }

    # Get tool policy and approval context from opts
    tool_policy = Keyword.get(opts, :tool_policy)
    session_key = Keyword.get(opts, :session_key)
    agent_id = Keyword.get(opts, :agent_id)

    # Build approval context if policy provided
    approval_context =
      if tool_policy do
        %{
          session_key: session_key || run_id,
          agent_id: agent_id || "default",
          run_id: run_id,
          timeout_ms: timeout
        }
      else
        nil
      end

    # Build session options
    session_opts =
      [cwd: cwd]
      |> maybe_add_opt(:model, model)
      |> maybe_add_opt(:system_prompt, system_prompt)
      |> maybe_add_opt(:tool_policy, tool_policy)
      |> maybe_add_opt(:approval_context, approval_context)
      |> maybe_add_opt(:session_key, session_key)
      |> maybe_add_opt(:agent_id, agent_id)

    # Start or resume session
    case start_or_resume_session(resume, session_opts, state) do
      {:ok, session, session_id, state} ->
        # Subscribe to session events
        {:ok, _stream} = CodingAgent.Session.subscribe(session, mode: :stream, max_queue: 10_000)

        # We subscribe ourselves directly for event processing
        _unsub = CodingAgent.Session.subscribe(session)

        # Send the prompt to start the agent
        :ok = CodingAgent.Session.prompt(session, prompt)

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
    if state.session do
      CodingAgent.Session.abort(state.session)
    end

    # Emit completed event if not already done
    state =
      if state.started_emitted and not state.completed_emitted do
        emit_completed_error(state, "Cancelled by user")
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
  # Session Management
  # ============================================================================

  defp start_or_resume_session(nil, session_opts, state) do
    # Start new session
    case CodingAgent.Session.start_link(session_opts) do
      {:ok, session} ->
        session_id = get_session_id(session)
        {:ok, session, session_id, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_or_resume_session(
         %ResumeToken{engine: @engine, value: session_id},
         session_opts,
         state
       ) do
    # Resume existing session
    # First try to find an existing session, or load from file
    session_file = session_file_path(session_id, state.cwd)

    session_opts =
      if File.exists?(session_file) do
        Keyword.put(session_opts, :session_file, session_file)
      else
        # If no file, start fresh with the session_id
        Keyword.put(session_opts, :session_id, session_id)
      end

    case CodingAgent.Session.start_link(session_opts) do
      {:ok, session} ->
        {:ok, session, session_id, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_or_resume_session(%ResumeToken{engine: other}, _session_opts, _state) do
    {:error, {:wrong_engine, other, @engine}}
  end

  defp get_session_id(session) do
    state = CodingAgent.Session.get_state(session)
    state.session_manager.header.id
  end

  defp session_file_path(session_id, cwd) do
    dir = CodingAgent.Config.sessions_dir(cwd)
    Path.join(dir, "#{session_id}.jsonl")
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
    kind = tool_kind(name)
    title = tool_title(name, args)
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
        kind = tool_kind(name)
        title = tool_title(name, %{})
        detail = %{name: name, result: truncate_result(result)}

        {event, factory} =
          EventFactory.action_completed(state.factory, action_id, kind, title, not is_error,
            detail: detail
          )

        emit_event(state.stream, event)
        %{state | factory: factory}

      action ->
        detail = Map.merge(action.detail, %{result: truncate_result(result)})

        {event, factory} =
          EventFactory.action_completed(
            state.factory,
            action_id,
            action.kind,
            action.title,
            not is_error,
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

  defp translate_and_emit({:message_update, _msg, _delta}, state) do
    # Non-string delta (could be structured content), skip
    state
  end

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

  defp translate_and_emit({:agent_end, messages}, state) do
    # Extract final answer from messages
    answer = extract_answer(messages, state.accumulated_text)

    # Build usage stats if available
    usage = build_usage(messages)

    emit_completed_ok(state, answer, usage)
  end

  defp translate_and_emit({:error, reason, _partial_state}, state) do
    error_msg = format_error(reason)
    emit_completed_error(state, error_msg)
  end

  defp translate_and_emit({:turn_start}, state), do: state
  defp translate_and_emit({:turn_end, _msg, _results}, state), do: state
  defp translate_and_emit({:message_start, _msg}, state), do: state
  defp translate_and_emit({:message_end, _msg}, state), do: state
  defp translate_and_emit({:extension_status_report, _report}, state), do: state
  defp translate_and_emit({:compaction_complete, _info}, state), do: state
  defp translate_and_emit({:branch_summarized, _info}, state), do: state
  defp translate_and_emit(_event, state), do: state

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
      finalize_session(state)
    end
  end

  defp emit_completed_error(state, error_msg) do
    if state.completed_emitted do
      state
    else
      token = state.factory.resume
      answer = state.accumulated_text

      {event, factory} =
        EventFactory.completed_error(state.factory, error_msg, resume: token, answer: answer)

      emit_event(state.stream, event)
      EventStream.complete(state.stream, [])
      state = %{state | factory: factory, completed_emitted: true}
      finalize_session(state)
    end
  end

  defp finalize_session(state) do
    session = state.session

    if is_pid(session) and Process.alive?(session) do
      # Best-effort save so resume tokens remain usable across runs.
      try do
        _ = CodingAgent.Session.save(session)
      rescue
        _ -> :ok
      end

      # Stop the session to avoid "already_started" conflicts on resume.
      try do
        GenServer.stop(session, :normal)
      rescue
        _ -> :ok
      end
    end

    state
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp emit_event(stream, event) do
    EventStream.push_async(stream, {:cli_event, event})
  end

  defp tool_kind(name) do
    case name do
      "Bash" -> :command
      "Read" -> :tool
      "Write" -> :file_change
      "Edit" -> :file_change
      "Glob" -> :tool
      "Grep" -> :tool
      "WebSearch" -> :web_search
      "WebFetch" -> :web_search
      "Task" -> :subagent
      _ -> :tool
    end
  end

  defp tool_title(name, args) do
    case {name, args} do
      {"Bash", %{"command" => cmd}} ->
        cmd_preview = cmd |> String.split("\n") |> hd() |> String.slice(0, 60)
        "$ #{cmd_preview}"

      {"Read", %{"file_path" => path}} ->
        "Read #{Path.basename(path)}"

      {"Write", %{"file_path" => path}} ->
        "Write #{Path.basename(path)}"

      {"Edit", %{"file_path" => path}} ->
        "Edit #{Path.basename(path)}"

      {"Glob", %{"pattern" => pattern}} ->
        "Glob #{pattern}"

      {"Grep", %{"pattern" => pattern}} ->
        "Grep #{pattern}"

      {"WebSearch", %{"query" => query}} ->
        "Search: #{String.slice(query, 0, 40)}"

      {"Task", %{"description" => desc}} ->
        "Task: #{String.slice(desc, 0, 40)}"

      {name, _} ->
        name
    end
  end

  defp truncate_result(result) when is_binary(result) do
    if String.length(result) > 500 do
      String.slice(result, 0, 500) <> "..."
    else
      result
    end
  end

  # Most tools return AgentToolResult with structured content blocks.
  # For user-facing transports (e.g., Telegram status surfaces), extract the plain text
  # so we don't leak raw Elixir struct inspection output.
  defp truncate_result(%AgentCore.Types.AgentToolResult{} = result) do
    result
    |> AgentCore.get_text()
    |> truncate_result()
  end

  defp truncate_result(%Ai.Types.TextContent{text: text}) when is_binary(text),
    do: truncate_result(text)

  defp truncate_result(content) when is_list(content) do
    content
    |> Enum.map(fn
      %Ai.Types.TextContent{text: text} when is_binary(text) -> text
      %{type: :text, text: text} when is_binary(text) -> text
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      item when is_binary(item) -> item
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> truncate_result()
  end

  defp truncate_result(result), do: inspect(result, limit: 500)

  defp extract_answer(messages, accumulated_text) do
    # Try to get the last assistant message content
    last_assistant =
      messages
      |> Enum.reverse()
      |> Enum.find(fn msg ->
        case msg do
          %{role: :assistant} -> true
          _ -> false
        end
      end)

    case last_assistant do
      %{content: content} when is_binary(content) -> content
      %{content: content} when is_list(content) -> extract_text_content(content)
      _ -> accumulated_text
    end
  end

  defp extract_text_content(content) do
    content
    |> Enum.filter(fn
      %{type: :text} -> true
      _ -> false
    end)
    |> Enum.map(fn %{text: text} -> text end)
    |> Enum.join("\n")
  end

  defp build_usage(messages) do
    # Sum up usage from all messages if available
    messages
    |> Enum.reduce(%{}, fn msg, acc ->
      case Map.get(msg, :usage) do
        nil -> acc
        usage -> merge_usage(acc, usage)
      end
    end)
    |> case do
      empty when map_size(empty) == 0 -> nil
      usage -> usage
    end
  end

  defp merge_usage(acc, usage) do
    Map.merge(acc, usage, fn _k, v1, v2 ->
      if is_number(v1) and is_number(v2), do: v1 + v2, else: v2
    end)
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error({:error, reason}), do: format_error(reason)
  defp format_error(reason), do: inspect(reason)

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
