defmodule AgentCore.CliRunners.ClaudeRunner do
  @moduledoc """
  Claude CLI subprocess runner.

  This module wraps the `claude` CLI tool (Claude Code), spawning it as a subprocess
  and streaming its JSONL events. It enables using Claude as a subagent
  with full session persistence and resumption support.

  ## Usage

      # Start a new Claude session
      {:ok, pid} = ClaudeRunner.start_link(
        prompt: "Create a new Elixir module that...",
        cwd: "/path/to/project"
      )

      # Get the event stream
      stream = ClaudeRunner.stream(pid)

      # Process events
      for event <- AgentCore.EventStream.events(stream) do
        case event do
          {:cli_event, %StartedEvent{resume: token}} ->
            IO.puts("Session started: \#{token.value}")

          {:cli_event, %ActionEvent{action: action, phase: :completed}} ->
            IO.puts("Completed: \#{action.title}")

          {:cli_event, %CompletedEvent{ok: true, answer: answer}} ->
            IO.puts("Done: \#{answer}")

          _ ->
            :ok
        end
      end

  ## Resuming Sessions

      # Resume a previous session
      token = %ResumeToken{engine: "claude", value: "session_abc123"}

      {:ok, pid} = ClaudeRunner.start_link(
        prompt: "Continue with the implementation",
        resume: token,
        cwd: "/path/to/project"
      )

  ## Configuration

  The runner uses the following command:

      claude -p --output-format stream-json --verbose [--resume SESSION_ID] -- <PROMPT>

  """

  use AgentCore.CliRunners.JsonlRunner

  alias AgentCore.CliRunners.ClaudeSchema
  alias AgentCore.CliRunners.ClaudeSchema.{
    StreamAssistantMessage,
    StreamResultMessage,
    StreamSystemMessage,
    StreamUserMessage,
    TextBlock,
    ThinkingBlock,
    ToolResultBlock,
    ToolUseBlock
  }
  alias AgentCore.CliRunners.Types.{EventFactory, ResumeToken}

  require Logger

  @engine "claude"

  # ============================================================================
  # Runner State
  # ============================================================================

  defmodule RunnerState do
    @moduledoc false
    defstruct [
      :factory,
      :found_session,
      :last_assistant_text,
      :pending_actions,
      :thinking_seq
    ]

    def new do
      %__MODULE__{
        factory: AgentCore.CliRunners.Types.EventFactory.new("claude"),
        found_session: nil,
        last_assistant_text: nil,
        pending_actions: %{},
        thinking_seq: 0
      }
    end
  end

  # ============================================================================
  # Callbacks
  # ============================================================================

  @impl true
  def engine, do: @engine

  @impl true
  def init_state(_prompt, _resume) do
    RunnerState.new()
  end

  @impl true
  def build_command(prompt, resume, _state) do
    base_args = [
      "-p",
      "--output-format", "stream-json",
      "--verbose",
      # Intentionally keep --dangerously-skip-permissions in Lemon (explicitly desired).
      "--dangerously-skip-permissions"
    ]

    # Add resume flag if resuming
    args =
      case resume do
        %ResumeToken{value: session_id} ->
          base_args ++ ["--resume", session_id]
        nil ->
          base_args
      end

    # Add prompt after --
    args = args ++ ["--", prompt]

    {"claude", args}
  end

  @impl true
  def stdin_payload(_prompt, _resume, _state) do
    # Claude takes prompt as command-line argument, not stdin
    nil
  end

  @impl true
  def decode_line(line) do
    ClaudeSchema.decode_event(line)
  end

  @impl true
  def translate_event(data, state) do
    case data do
      # Ignored event types
      :ignored ->
        {[], state, []}

      # System init message - extract session_id
      %StreamSystemMessage{subtype: "init", session_id: session_id} = event ->
        if session_id do
          token = ResumeToken.new(@engine, session_id)

          meta = %{
            cwd: event.cwd,
            tools: event.tools,
            model: event.model,
            permission_mode: event.permission_mode
          }

          {started_event, factory} = EventFactory.started(state.factory, token, title: "Claude", meta: meta)
          state = %{state | factory: factory, found_session: token}
          {[started_event], state, [found_session: token]}
        else
          {[], state, []}
        end

      # Other system messages (non-init)
      %StreamSystemMessage{} ->
        {[], state, []}

      # Assistant message - process content blocks
      %StreamAssistantMessage{message: message} ->
        {events, state} = process_assistant_content(message.content, state)
        {events, state, []}

      # User message (tool results) - complete pending actions
      %StreamUserMessage{message: message} ->
        {events, state} = process_user_content(message.content, state)
        {events, state, []}

      # Result message - session completion
      %StreamResultMessage{} = event ->
        ok = not event.is_error

        # Use result text or last assistant text
        result_text = event.result || state.last_assistant_text || ""

        usage = %{
          total_cost_usd: event.total_cost_usd,
          duration_ms: event.duration_ms,
          duration_api_ms: event.duration_api_ms,
          num_turns: event.num_turns,
          usage: if(event.usage, do: %{
            input_tokens: event.usage.input_tokens,
            output_tokens: event.usage.output_tokens,
            cache_creation_input_tokens: event.usage.cache_creation_input_tokens,
            cache_read_input_tokens: event.usage.cache_read_input_tokens
          }, else: nil)
        }

        # Get resume token from event or state
        resume_token =
          if event.session_id do
            ResumeToken.new(@engine, event.session_id)
          else
            state.found_session
          end

        if ok do
          {completed_event, factory} = EventFactory.completed_ok(
            state.factory,
            result_text,
            resume: resume_token,
            usage: usage
          )
          state = %{state | factory: factory}
          {[completed_event], state, [done: true]}
        else
          error = extract_error(event)
          {completed_event, factory} = EventFactory.completed_error(
            state.factory,
            error,
            answer: result_text,
            resume: resume_token
          )
          state = %{state | factory: factory}
          {[completed_event], state, [done: true]}
        end

      _ ->
        {[], state, []}
    end
  end

  @impl true
  def handle_exit_error(exit_code, state) do
    message = "claude failed (rc=#{exit_code})"
    {note_event, factory} = EventFactory.note(state.factory, message, ok: false)

    {completed_event, factory} = EventFactory.completed_error(
      factory,
      message,
      answer: state.last_assistant_text || "",
      resume: state.found_session
    )

    state = %{state | factory: factory}
    {[note_event, completed_event], state}
  end

  @impl true
  def handle_stream_end(state) do
    if state.found_session == nil do
      message = "claude finished but no session_id was captured"
      {event, factory} = EventFactory.completed_error(
        state.factory,
        message,
        answer: state.last_assistant_text || ""
      )
      state = %{state | factory: factory}
      {[event], state}
    else
      message = "claude finished without a result event"
      {event, factory} = EventFactory.completed_error(
        state.factory,
        message,
        answer: state.last_assistant_text || "",
        resume: state.found_session
      )
      state = %{state | factory: factory}
      {[event], state}
    end
  end

  # ============================================================================
  # Content Processing
  # ============================================================================

  defp process_assistant_content(content, state) when is_list(content) do
    Enum.reduce(content, {[], state}, fn block, {events_acc, state_acc} ->
      {new_events, new_state} = process_content_block(block, state_acc)
      {events_acc ++ new_events, new_state}
    end)
  end

  defp process_assistant_content(_, state), do: {[], state}

  defp process_content_block(%TextBlock{text: text}, state) do
    # Accumulate text for final result
    last_text = state.last_assistant_text || ""
    state = %{state | last_assistant_text: last_text <> text}
    {[], state}
  end

  defp process_content_block(%ThinkingBlock{thinking: thinking, signature: signature}, state) do
    action_id = "claude.thinking.#{state.thinking_seq}"
    state = %{state | thinking_seq: state.thinking_seq + 1}

    # Truncate long thinking text for title
    title = String.slice(thinking, 0, 100)
    detail = if signature, do: %{signature: signature}, else: %{}

    {event, factory} = EventFactory.action_completed(
      state.factory,
      action_id,
      :note,
      title,
      true,
      detail: detail
    )

    state = %{state | factory: factory}
    {[event], state}
  end

  defp process_content_block(%ToolUseBlock{id: id, name: name, input: input}, state) do
    {kind, title} = tool_kind_and_title(name, input)

    detail = %{
      name: name,
      input: input
    }

    {event, factory} = EventFactory.action_started(state.factory, id, kind, title, detail: detail)

    # Store pending action for later completion
    pending_action = %{
      id: id,
      kind: kind,
      title: title,
      detail: detail
    }

    pending_actions = Map.put(state.pending_actions, id, pending_action)
    state = %{state | factory: factory, pending_actions: pending_actions}

    {[event], state}
  end

  defp process_content_block(_, state), do: {[], state}

  defp process_user_content(content, state) when is_list(content) do
    Enum.reduce(content, {[], state}, fn block, {events_acc, state_acc} ->
      {new_events, new_state} = process_tool_result(block, state_acc)
      {events_acc ++ new_events, new_state}
    end)
  end

  defp process_user_content(_, state), do: {[], state}

  defp process_tool_result(%ToolResultBlock{tool_use_id: tool_use_id, content: content, is_error: is_error}, state) do
    case Map.pop(state.pending_actions, tool_use_id) do
      {nil, _} ->
        ok = not is_error
        result_preview = normalize_tool_result(content)

        detail = %{
          tool_use_id: tool_use_id,
          result_preview: result_preview,
          is_error: is_error
        }

        {event, factory} = EventFactory.action_completed(
          state.factory,
          tool_use_id,
          :tool,
          "tool result",
          ok,
          detail: detail
        )

        state = %{state | factory: factory}
        {[event], state}

      {action, pending_actions} ->
        ok = not is_error
        result_preview = normalize_tool_result(content)

        detail = Map.merge(action.detail, %{
          result_preview: result_preview,
          is_error: is_error
        })

        {event, factory} = EventFactory.action_completed(
          state.factory,
          action.id,
          action.kind,
          action.title,
          ok,
          detail: detail
        )

        state = %{state | factory: factory, pending_actions: pending_actions}
        {[event], state}
    end
  end

  defp process_tool_result(_, state), do: {[], state}

  # ============================================================================
  # Helpers
  # ============================================================================

  defp tool_kind_and_title(name, input) do
    case name do
      "Bash" ->
        command = Map.get(input, "command", "")
        title = String.slice(command, 0, 60)
        {:command, title}

      "Read" ->
        path = Map.get(input, "file_path", "")
        {:tool, "Read: #{Path.basename(path)}"}

      "Write" ->
        path = Map.get(input, "file_path", "")
        {:file_change, "Write: #{Path.basename(path)}"}

      "Edit" ->
        path = Map.get(input, "file_path", "")
        {:file_change, "Edit: #{Path.basename(path)}"}

      "Glob" ->
        pattern = Map.get(input, "pattern", "")
        {:tool, "Glob: #{pattern}"}

      "Grep" ->
        pattern = Map.get(input, "pattern", "")
        {:tool, "Grep: #{pattern}"}

      "WebSearch" ->
        query = Map.get(input, "query", "")
        {:web_search, query}

      "WebFetch" ->
        url = Map.get(input, "url", "")
        {:tool, "Fetch: #{url}"}

      "Task" ->
        prompt = Map.get(input, "prompt", "")
        title = String.slice(prompt, 0, 40)
        {:subagent, "Task: #{title}"}

      _ ->
        {:tool, name}
    end
  end

  defp normalize_tool_result(nil), do: ""
  defp normalize_tool_result(content) when is_binary(content), do: String.slice(content, 0, 200)

  defp normalize_tool_result(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      item when is_binary(item) -> item
      _ -> ""
    end)
    |> Enum.join("\n")
    |> String.slice(0, 200)
  end

  defp normalize_tool_result(content) when is_map(content) do
    Map.get(content, "text", inspect(content))
    |> String.slice(0, 200)
  end

  defp normalize_tool_result(content), do: inspect(content) |> String.slice(0, 200)

  defp extract_error(%StreamResultMessage{is_error: true, result: result}) when is_binary(result) do
    result
  end

  defp extract_error(%StreamResultMessage{is_error: true}) do
    "Claude session failed"
  end

  defp extract_error(_), do: nil
end
