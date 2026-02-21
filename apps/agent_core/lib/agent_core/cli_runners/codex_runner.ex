defmodule AgentCore.CliRunners.CodexRunner do
  @moduledoc """
  Codex CLI subprocess runner.

  This module wraps the `codex` CLI tool, spawning it as a subprocess
  and streaming its JSONL events. It enables using Codex as a subagent
  with full session persistence and resumption support.

  ## Usage

      # Start a new Codex session
      {:ok, pid} = CodexRunner.start_link(
        prompt: "Create a new Elixir module that...",
        cwd: "/path/to/project"
      )

      # Get the event stream
      stream = CodexRunner.stream(pid)

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
      token = %ResumeToken{engine: "codex", value: "thread_abc123"}

      {:ok, pid} = CodexRunner.start_link(
        prompt: "Continue with the implementation",
        resume: token,
        cwd: "/path/to/project"
      )

  ## Configuration

  The runner uses the following command by default:

      codex exec --json --skip-git-repo-check --color=never

  For resuming:

      codex exec --json --skip-git-repo-check --color=never resume <session_id> -

  The prompt is sent via stdin.

  """

  use AgentCore.CliRunners.JsonlRunner

  alias AgentCore.CliRunners.CodexSchema

  alias AgentCore.CliRunners.CodexSchema.{
    AgentMessageItem,
    CommandExecutionItem,
    ErrorItem,
    FileChangeItem,
    ItemCompleted,
    ItemStarted,
    ItemUpdated,
    McpToolCallItem,
    ReasoningItem,
    StreamError,
    ThreadStarted,
    TodoListItem,
    TurnCompleted,
    TurnFailed,
    TurnStarted,
    WebSearchItem
  }

  alias AgentCore.CliRunners.Types.{EventFactory, ResumeToken}
  alias LemonCore.Config, as: LemonConfig

  require Logger

  @engine "codex"

  # ============================================================================
  # Runner State
  # ============================================================================

  defmodule RunnerState do
    @moduledoc false
    defstruct [
      :factory,
      :final_answer,
      :turn_index,
      :found_session,
      :config,
      :model_override
    ]

    def new(config \\ nil, model_override \\ nil) do
      %__MODULE__{
        factory: EventFactory.new("codex"),
        final_answer: nil,
        turn_index: 0,
        found_session: nil,
        config: config,
        model_override: model_override
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
  def init_state(_prompt, _resume, cwd) do
    maybe_ensure_codexignore(cwd)
    RunnerState.new(LemonConfig.load(cwd))
  end

  @impl true
  def init_state(_prompt, _resume, cwd, opts) do
    maybe_ensure_codexignore(cwd)
    model_override = normalize_codex_model(Keyword.get(opts, :model))
    RunnerState.new(LemonConfig.load(cwd), model_override)
  end

  @impl true
  def build_command(_prompt, resume, state) do
    base_args =
      [
        "exec",
        "--model",
        codex_model(state),
        "--json",
        "--skip-git-repo-check",
        "--color=never"
      ]
      |> maybe_drop_model_flag()
      |> maybe_add_auto_approve(state)
      |> maybe_add_auto_compact()

    extra_args = codex_extra_args(state)

    args =
      case resume do
        %ResumeToken{value: session_id} ->
          # Resume with stdin prompt
          extra_args ++ base_args ++ ["resume", session_id, "-"]

        nil ->
          # New session with stdin prompt
          extra_args ++ base_args ++ ["-"]
      end

    {"codex", args}
  end

  @impl true
  def stdin_payload(prompt, _resume, _state) do
    # Send prompt followed by newline
    prompt <> "\n"
  end

  @impl true
  def decode_line(line) do
    CodexSchema.decode_event(line)
  end

  @impl true
  def translate_event(data, state) do
    case data do
      # Session started - extract thread_id
      %ThreadStarted{thread_id: thread_id} ->
        token = ResumeToken.new(@engine, thread_id)
        {event, factory} = EventFactory.started(state.factory, token, title: "Codex")
        state = %{state | factory: factory, found_session: token}
        {[event], state, [found_session: token]}

      # Turn lifecycle
      %TurnStarted{} ->
        action_id = "turn_#{state.turn_index}"

        {event, factory} =
          EventFactory.action_started(state.factory, action_id, :turn, "turn started")

        state = %{state | factory: factory, turn_index: state.turn_index + 1}
        {[event], state, []}

      %TurnCompleted{usage: usage} ->
        usage_map = %{
          input_tokens: usage.input_tokens,
          cached_input_tokens: usage.cached_input_tokens,
          output_tokens: usage.output_tokens
        }

        {event, factory} =
          EventFactory.completed_ok(
            state.factory,
            state.final_answer || "",
            resume: state.found_session,
            usage: usage_map
          )

        state = %{state | factory: factory}
        {[event], state, [done: true]}

      %TurnFailed{error: error} ->
        {event, factory} =
          EventFactory.completed_error(
            state.factory,
            error.message,
            answer: state.final_answer || "",
            resume: state.found_session
          )

        state = %{state | factory: factory}
        {[event], state, [done: true]}

      # Stream errors
      %StreamError{message: message} ->
        # Check for reconnection pattern
        case parse_reconnect_message(message) do
          {:ok, attempt, max_attempts} ->
            phase = if attempt <= 1, do: :started, else: :updated

            {event, factory} =
              EventFactory.action(state.factory,
                phase: phase,
                action_id: "codex.reconnect",
                kind: :note,
                title: message,
                detail: %{attempt: attempt, max: max_attempts},
                level: :info
              )

            state = %{state | factory: factory}
            {[event], state, []}

          :error ->
            {event, factory} = EventFactory.note(state.factory, message, ok: false)
            state = %{state | factory: factory}
            {[event], state, []}
        end

      # Item events
      %ItemStarted{item: item} ->
        translate_item_event(:started, item, state)

      %ItemUpdated{item: item} ->
        translate_item_event(:updated, item, state)

      %ItemCompleted{item: item} ->
        # Capture agent message as final answer
        state =
          case item do
            %AgentMessageItem{text: text} ->
              %{state | final_answer: text}

            _ ->
              state
          end

        translate_item_event(:completed, item, state)

      _ ->
        {[], state, []}
    end
  end

  @impl true
  def handle_exit_error(exit_code, state) do
    message = "codex exec failed (rc=#{exit_code})"
    {note_event, factory} = EventFactory.note(state.factory, message, ok: false)

    {completed_event, factory} =
      EventFactory.completed_error(
        factory,
        message,
        answer: state.final_answer || "",
        resume: state.found_session
      )

    state = %{state | factory: factory}
    {[note_event, completed_event], state}
  end

  @impl true
  def handle_stream_end(state) do
    message =
      if state.found_session == nil do
        "codex exec finished but no session_id/thread_id was captured"
      else
        "codex exec ended without turn completion"
      end

    {event, factory} =
      EventFactory.completed_error(
        state.factory,
        message,
        answer: state.final_answer || "",
        resume: state.found_session
      )

    state = %{state | factory: factory}
    {[event], state}
  end

  # ============================================================================
  # Item Translation
  # ============================================================================

  defp translate_item_event(phase, item, state) do
    case item do
      # Agent message - handled at parent level for answer capture
      %AgentMessageItem{} ->
        {[], state, []}

      # Error items
      %ErrorItem{id: action_id, message: message} ->
        if phase != :completed do
          {[], state, []}
        else
          {event, factory} =
            EventFactory.action_completed(
              state.factory,
              action_id,
              :warning,
              message,
              false,
              detail: %{message: message},
              message: message,
              level: :warning
            )

          state = %{state | factory: factory}
          {[event], state, []}
        end

      # Command execution
      %CommandExecutionItem{id: action_id, command: command, exit_code: exit_code, status: status} ->
        title = relativize_command(command)

        case phase do
          p when p in [:started, :updated] ->
            {event, factory} =
              EventFactory.action(state.factory,
                phase: phase,
                action_id: action_id,
                kind: :command,
                title: title
              )

            state = %{state | factory: factory}
            {[event], state, []}

          :completed ->
            ok = status == :completed and (exit_code == nil or exit_code == 0)
            detail = %{exit_code: exit_code, status: status}

            {event, factory} =
              EventFactory.action_completed(state.factory, action_id, :command, title, ok,
                detail: detail
              )

            state = %{state | factory: factory}
            {[event], state, []}
        end

      # MCP tool calls
      %McpToolCallItem{
        id: action_id,
        server: server,
        tool: tool,
        arguments: arguments,
        status: status,
        result: result,
        error: error
      } ->
        title = short_tool_name(server, tool)

        detail = %{
          server: server,
          tool: tool,
          status: status,
          arguments: arguments
        }

        case phase do
          p when p in [:started, :updated] ->
            {event, factory} =
              EventFactory.action(state.factory,
                phase: phase,
                action_id: action_id,
                kind: :tool,
                title: title,
                detail: detail
              )

            state = %{state | factory: factory}
            {[event], state, []}

          :completed ->
            ok = status == :completed and error == nil

            detail =
              detail
              |> maybe_add_error(error)
              |> maybe_add_result_preview(result)

            {event, factory} =
              EventFactory.action_completed(state.factory, action_id, :tool, title, ok,
                detail: detail
              )

            state = %{state | factory: factory}
            {[event], state, []}
        end

      # Web search
      %WebSearchItem{id: action_id, query: query} ->
        detail = %{query: query}

        case phase do
          p when p in [:started, :updated] ->
            {event, factory} =
              EventFactory.action(state.factory,
                phase: phase,
                action_id: action_id,
                kind: :web_search,
                title: query,
                detail: detail
              )

            state = %{state | factory: factory}
            {[event], state, []}

          :completed ->
            {event, factory} =
              EventFactory.action_completed(state.factory, action_id, :web_search, query, true,
                detail: detail
              )

            state = %{state | factory: factory}
            {[event], state, []}
        end

      # File changes
      %FileChangeItem{id: action_id, changes: changes, status: status} ->
        if phase != :completed do
          {[], state, []}
        else
          title = format_change_summary(changes)
          normalized_changes = normalize_change_list(changes)

          detail = %{
            changes: normalized_changes,
            status: status,
            error: nil
          }

          ok = status == :completed

          {event, factory} =
            EventFactory.action_completed(state.factory, action_id, :file_change, title, ok,
              detail: detail
            )

          state = %{state | factory: factory}
          {[event], state, []}
        end

      # Todo lists
      %TodoListItem{id: action_id, items: items} ->
        {done, total} = summarize_todo_list(items)
        title = "#{done}/#{total} tasks"
        detail = %{done: done, total: total}

        case phase do
          p when p in [:started, :updated] ->
            {event, factory} =
              EventFactory.action(state.factory,
                phase: phase,
                action_id: action_id,
                kind: :note,
                title: title,
                detail: detail
              )

            state = %{state | factory: factory}
            {[event], state, []}

          :completed ->
            {event, factory} =
              EventFactory.action_completed(state.factory, action_id, :note, title, true,
                detail: detail
              )

            state = %{state | factory: factory}
            {[event], state, []}
        end

      # Reasoning (extended thinking)
      %ReasoningItem{id: action_id, text: text} ->
        # Truncate long reasoning text for title
        title = String.slice(text, 0, 100)

        case phase do
          p when p in [:started, :updated] ->
            {event, factory} =
              EventFactory.action(state.factory,
                phase: phase,
                action_id: action_id,
                kind: :note,
                title: title
              )

            state = %{state | factory: factory}
            {[event], state, []}

          :completed ->
            {event, factory} =
              EventFactory.action_completed(state.factory, action_id, :note, title, true)

            state = %{state | factory: factory}
            {[event], state, []}
        end

      _ ->
        {[], state, []}
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp parse_reconnect_message(message) do
    # Pattern: "Reconnecting...1/3" or similar
    case Regex.run(~r/Reconnecting.*?(\d+)\/(\d+)/, message) do
      [_, attempt, max] ->
        {:ok, String.to_integer(attempt), String.to_integer(max)}

      _ ->
        :error
    end
  end

  defp relativize_command(command) do
    # Shorten long paths for display
    home = System.user_home() || ""

    command
    |> String.replace(home, "~")
    |> String.slice(0, 80)
  end

  defp short_tool_name(server, tool) do
    if server == "" or server == nil do
      tool
    else
      "#{server}.#{tool}"
    end
  end

  defp maybe_add_error(detail, nil), do: detail

  defp maybe_add_error(detail, error) do
    Map.put(detail, :error_message, error.message)
  end

  defp maybe_add_result_preview(detail, nil), do: detail

  defp maybe_add_result_preview(detail, result) do
    summary =
      case result.content do
        [%{"type" => "text", "text" => text} | _] ->
          String.slice(text, 0, 200)

        _ ->
          nil
      end

    if summary do
      # Keep both keys for compatibility with older callers/tests.
      detail
      |> Map.put(:result_preview, summary)
      |> Map.put(:result_summary, summary)
    else
      detail
    end
  end

  defp format_change_summary(changes) when is_list(changes) do
    count = length(changes)

    case count do
      0 -> "no changes"
      1 -> "1 file changed"
      n -> "#{n} files changed"
    end
  end

  defp normalize_change_list(changes) do
    Enum.map(changes, fn change ->
      %{
        path: change.path,
        kind: change.kind
      }
    end)
  end

  defp summarize_todo_list(items) do
    total = length(items)
    done = Enum.count(items, & &1.completed)
    {done, total}
  end

  defp maybe_add_auto_approve(args, state) do
    if codex_auto_approve?(state) do
      args ++ ["--dangerously-bypass-approvals-and-sandbox"]
    else
      args
    end
  end

  defp maybe_add_auto_compact(args) do
    args ++ ["-c", "model_auto_compact_token_limit=0.85"]
  end

  defp codex_auto_approve?(state) do
    case get_codex_config(state, :auto_approve, nil) do
      nil ->
        false

      value ->
        value == true
    end
  end

  # Get codex config value, handling both keyword lists and maps
  defp get_codex_config(%RunnerState{config: %LemonConfig{agent: agent}}, key, default) do
    case get_in(agent, [:cli, :codex, key]) do
      nil -> default
      value -> value
    end
  end

  defp get_codex_config(_state, _key, default), do: default

  defp codex_extra_args(state) do
    case get_codex_config(state, :extra_args, ["-c", "notify=[]"]) do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      value when is_binary(value) -> String.split(value, ~r/\s+/, trim: true)
      _ -> ["-c", "notify=[]"]
    end
  end

  defp codex_model(state) do
    state_model =
      case state do
        %RunnerState{model_override: model} -> normalize_codex_model(model)
        _ -> nil
      end

    state_model ||
      normalize_codex_model(get_codex_config(state, :model, nil))
  end

  defp maybe_drop_model_flag(args) do
    case Enum.find_index(args, &(&1 == "--model")) do
      nil ->
        args

      model_idx ->
        model_value_idx = model_idx + 1
        model_value = Enum.at(args, model_value_idx)

        if is_binary(model_value) and String.trim(model_value) != "" do
          args
        else
          args
          |> List.delete_at(model_value_idx)
          |> List.delete_at(model_idx)
        end
    end
  end

  defp normalize_codex_model(model) when is_binary(model) do
    trimmed = String.trim(model)

    cond do
      trimmed == "" ->
        nil

      true ->
        case String.split(trimmed, ":", parts: 2) do
          [prefix, id]
          when prefix in ["codex", "openai-codex", "openai", "chatgpt"] and is_binary(id) ->
            normalized = String.trim(id)
            if normalized == "", do: nil, else: normalized

          _ ->
            trimmed
        end
    end
  end

  defp normalize_codex_model(_), do: nil

  defp maybe_ensure_codexignore(cwd) when is_binary(cwd) do
    if Code.ensure_loaded?(CodingAgent.Project.Codexignore) do
      CodingAgent.Project.Codexignore.ensure_codexignore(cwd)
    end
  rescue
    _ -> :ok
  end

  defp maybe_ensure_codexignore(_), do: :ok
end
