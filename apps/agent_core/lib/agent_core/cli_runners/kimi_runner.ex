defmodule AgentCore.CliRunners.KimiRunner do
  @moduledoc """
  Kimi CLI subprocess runner.

  This module wraps the `kimi` CLI tool, spawning it as a subprocess and
  streaming its JSONL events. It enables using Kimi as a subagent with
  tool action tracking.

  ## Usage

      {:ok, pid} = KimiRunner.start_link(
        prompt: "Create a new Elixir module that...",
        cwd: "/path/to/project"
      )

      stream = KimiRunner.stream(pid)
      for event <- AgentCore.EventStream.events(stream) do
        ...
      end

  ## Configuration

  The runner uses the following command:

      kimi --print --output-format stream-json [-p PROMPT] [--session SESSION_ID]
  """

  use AgentCore.CliRunners.JsonlRunner

  alias AgentCore.CliRunners.KimiSchema
  alias AgentCore.CliRunners.KimiSchema.{ErrorMessage, Message, StreamMessage, ToolCall}
  alias AgentCore.CliRunners.ToolActionHelpers
  alias AgentCore.CliRunners.Types.{EventFactory, ResumeToken}
  alias LemonCore.Introspection

  @engine "kimi"

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
      :started_emitted,
      :resume_token,
      :cwd,
      :config
    ]

    def new(resume_token), do: new(resume_token, nil, nil)

    def new(resume_token, cwd, config) do
      %__MODULE__{
        factory: EventFactory.new("kimi"),
        found_session: resume_token,
        last_assistant_text: nil,
        pending_actions: %{},
        started_emitted: false,
        resume_token: resume_token,
        cwd: cwd,
        config: config
      }
    end
  end

  # ============================================================================
  # Callbacks
  # ============================================================================

  @impl true
  def engine, do: @engine

  @impl true
  def init_state(_prompt, resume) do
    RunnerState.new(resume, nil, nil)
  end

  @impl true
  def init_state(_prompt, resume, cwd) do
    RunnerState.new(resume, cwd, LemonCore.Config.load(cwd))
  end

  @impl true
  def build_command(prompt, resume, state) do
    base_args =
      ["--print", "--output-format", "stream-json"]
      |> maybe_add_extra_args(state)
      |> maybe_add_config_file()

    args =
      case resume do
        %ResumeToken{value: session_id} ->
          base_args ++ ["--session", session_id]

        nil ->
          base_args
      end

    {"kimi", args ++ ["-p", prompt]}
  end

  @impl true
  def stdin_payload(_prompt, _resume, _state) do
    # Kimi takes prompt as CLI argument in print mode
    nil
  end

  @impl true
  def env(_state) do
    # Ensure HOME is set so the CLI can locate ~/.kimi/config.toml
    env = System.get_env()
    home = Map.get(env, "HOME") || System.user_home!()

    env
    |> Map.put_new("HOME", home)
    |> Enum.to_list()
  end

  @impl true
  def decode_line(line) do
    KimiSchema.decode_event(line)
  end

  @impl true
  def translate_event(%StreamMessage{message: message}, state) do
    {start_events, state} = maybe_emit_started(state)
    {events, state} = handle_message(message, state)
    {start_events ++ events, state, []}
  end

  def translate_event(%ErrorMessage{error: error}, state) do
    state = maybe_refresh_session(state)

    error_text =
      case error do
        text when is_binary(text) -> text
        other -> inspect(other)
      end

    {event, factory} =
      EventFactory.completed_error(state.factory, error_text,
        answer: state.last_assistant_text || "",
        resume: state.found_session
      )

    state = %{state | factory: factory}
    {[event], state, [done: true]}
  end

  def translate_event(_data, state), do: {[], state, []}

  @impl true
  def handle_exit_error(exit_code, state) do
    Introspection.record(:engine_subprocess_exited, %{
      engine: @engine,
      exit_code: exit_code,
      ok: false
    },
      engine: @engine,
      provenance: :inferred
    )

    state = maybe_refresh_session(state)
    message = "kimi failed (rc=#{exit_code})"
    {note_event, factory} = EventFactory.note(state.factory, message, ok: false)

    {completed_event, factory} =
      EventFactory.completed_error(
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
    state = maybe_refresh_session(state)
    answer = state.last_assistant_text || ""

    if answer == "" do
      message = "kimi finished with no output"
      {event, factory} = EventFactory.completed_error(state.factory, message, answer: "")
      {[event], %{state | factory: factory}}
    else
      Introspection.record(:engine_output_observed, %{
        engine: @engine,
        ok: true,
        has_answer: true
      },
        engine: @engine,
        provenance: :inferred
      )

      {event, factory} =
        EventFactory.completed_ok(state.factory, answer, resume: state.found_session)

      {[event], %{state | factory: factory}}
    end
  end

  # ============================================================================
  # Message Handling
  # ============================================================================

  defp handle_message(%Message{role: "assistant"} = message, state) do
    {events, state} = append_assistant_content(message.content, state)
    {tool_events, state} = start_tool_calls(message.tool_calls, state)
    {events ++ tool_events, state}
  end

  defp handle_message(%Message{role: "tool"} = message, state) do
    {events, state} = complete_tool_result(message, state)
    {events, state}
  end

  defp handle_message(_message, state), do: {[], state}

  defp append_assistant_content(content, state) do
    text = normalize_content_text(content)

    if text == "" do
      {[], state}
    else
      last_text = state.last_assistant_text || ""
      state = %{state | last_assistant_text: last_text <> text}
      {[], state}
    end
  end

  defp start_tool_calls(nil, state), do: {[], state}

  defp start_tool_calls(calls, state) when is_list(calls) do
    Enum.reduce(calls, {[], state}, fn call, {events_acc, state_acc} ->
      {new_events, new_state} = start_tool_call(call, state_acc)
      {events_acc ++ new_events, new_state}
    end)
  end

  defp start_tool_calls(_, state), do: {[], state}

  defp start_tool_call(%ToolCall{id: id, function: func} = call, state) do
    tool_id = id || "kimi.tool.#{:erlang.unique_integer([:positive])}"
    name = func && func.name
    input = parse_tool_arguments(func && func.arguments)
    {kind, title} = tool_kind_and_title(name, input)

    detail = %{
      id: tool_id,
      name: name,
      type: call.type,
      input: input
    }

    {event, factory, pending_actions} =
      ToolActionHelpers.start_action(
        state.factory,
        state.pending_actions,
        tool_id,
        kind,
        title,
        detail
      )

    state = %{state | factory: factory, pending_actions: pending_actions}
    {[event], state}
  end

  defp start_tool_call(_, state), do: {[], state}

  defp complete_tool_result(
         %Message{tool_call_id: tool_call_id, content: content, is_error: is_error},
         state
       )
       when is_binary(tool_call_id) do
    ok = not (is_error == true)
    result_preview = ToolActionHelpers.normalize_tool_result(content)

    detail = %{
      tool_call_id: tool_call_id,
      result_preview: result_preview,
      is_error: is_error == true
    }

    {event, factory, pending_actions} =
      ToolActionHelpers.complete_action(
        state.factory,
        state.pending_actions,
        tool_call_id,
        ok,
        detail
      )

    state = %{state | factory: factory, pending_actions: pending_actions}
    {[event], state}
  end

  defp complete_tool_result(_message, state), do: {[], state}

  # ============================================================================
  # Helpers
  # ============================================================================

  defp maybe_emit_started(%RunnerState{started_emitted: true} = state), do: {[], state}

  defp maybe_emit_started(%RunnerState{resume_token: %ResumeToken{} = token} = state) do
    {event, factory} = EventFactory.started(state.factory, token, title: "Kimi")

    Introspection.record(:engine_subprocess_started, %{
      engine: @engine
    },
      engine: @engine,
      provenance: :inferred
    )

    {[event], %{state | factory: factory, started_emitted: true, found_session: token}}
  end

  defp maybe_emit_started(state), do: {[], %{state | started_emitted: true}}

  defp normalize_content_text(nil), do: ""
  defp normalize_content_text(text) when is_binary(text), do: text

  defp normalize_content_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      item when is_binary(item) -> item
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp normalize_content_text(_), do: ""

  defp parse_tool_arguments(nil), do: %{}
  defp parse_tool_arguments(args) when is_map(args), do: args

  defp parse_tool_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{"raw" => args}
    end
  end

  defp parse_tool_arguments(_), do: %{}

  defp tool_kind_and_title(nil, _input), do: {:tool, "tool"}

  defp tool_kind_and_title(name, input) do
    name_down = String.downcase(to_string(name))

    cond do
      name_down in ["bash", "shell", "command"] ->
        command = Map.get(input, "command") || Map.get(input, "cmd") || ""
        {:command, String.slice(to_string(command), 0, 60)}

      name_down in ["read", "read_file", "file_read"] ->
        path = Map.get(input, "file_path") || Map.get(input, "path") || ""
        {:tool, "Read: #{Path.basename(to_string(path))}"}

      name_down in ["write", "write_file", "file_write"] ->
        path = Map.get(input, "file_path") || Map.get(input, "path") || ""
        {:file_change, "Write: #{Path.basename(to_string(path))}"}

      name_down in ["edit", "patch", "update_file"] ->
        path = Map.get(input, "file_path") || Map.get(input, "path") || ""
        {:file_change, "Edit: #{Path.basename(to_string(path))}"}

      name_down in ["web_search", "search"] ->
        query = Map.get(input, "query") || Map.get(input, "q") || ""
        {:web_search, to_string(query)}

      true ->
        {:tool, to_string(name)}
    end
  end

  defp maybe_add_extra_args(args, %RunnerState{config: %LemonCore.Config{agent: agent}}) do
    extra =
      case get_in(agent, [:cli, :kimi, :extra_args]) do
        nil -> []
        value -> value
      end

    args ++ normalize_extra_args(extra)
  end

  defp maybe_add_extra_args(args, _state), do: args

  defp maybe_add_config_file(args) do
    if has_config_flag?(args) do
      args
    else
      config = Path.expand("~/.kimi/config.toml")

      if File.exists?(config) do
        args ++ ["--config-file", config]
      else
        args
      end
    end
  end

  defp has_config_flag?(args) do
    Enum.any?(args, &(&1 in ["--config-file", "--config"]))
  end

  defp maybe_refresh_session(%RunnerState{found_session: %ResumeToken{}} = state), do: state
  defp maybe_refresh_session(%RunnerState{cwd: nil} = state), do: state

  defp maybe_refresh_session(%RunnerState{cwd: cwd} = state) do
    case fetch_last_session_id_with_retry(cwd, 5) do
      nil ->
        state

      session_id ->
        %{state | found_session: ResumeToken.new(@engine, session_id)}
    end
  end

  defp fetch_last_session_id_with_retry(cwd, attempts) when attempts > 0 do
    case fetch_last_session_id(cwd) do
      nil ->
        Process.sleep(100)
        fetch_last_session_id_with_retry(cwd, attempts - 1)

      session_id ->
        session_id
    end
  end

  defp fetch_last_session_id_with_retry(_cwd, _attempts), do: nil

  defp fetch_last_session_id(cwd) when is_binary(cwd) do
    path = Path.expand("~/.kimi/kimi.json")

    with {:ok, content} <- File.read(path),
         {:ok, %{"work_dirs" => dirs}} <- Jason.decode(content) do
      cwd = normalize_path(cwd)

      dirs
      |> Enum.reduce([], fn
        %{"path" => path, "last_session_id" => session_id}, acc
        when is_binary(path) and is_binary(session_id) ->
          path = normalize_path(path)

          cond do
            path == cwd ->
              [{path, session_id} | acc]

            String.starts_with?(cwd, path <> "/") ->
              [{path, session_id} | acc]

            true ->
              acc
          end

        _, acc ->
          acc
      end)
      |> Enum.sort_by(fn {path, _session_id} -> String.length(path) end, :desc)
      |> List.first()
      |> case do
        {_, session_id} -> session_id
        nil -> nil
      end
    else
      _ -> nil
    end
  end

  defp normalize_path(path) do
    path = Path.expand(path)

    cond do
      String.starts_with?(path, "/private/") ->
        path

      String.starts_with?(path, "/var/") ->
        "/private" <> path

      String.starts_with?(path, "/tmp/") ->
        "/private" <> path

      true ->
        path
    end
  end

  defp normalize_extra_args(nil), do: []
  defp normalize_extra_args(list) when is_list(list), do: Enum.map(list, &to_string/1)

  defp normalize_extra_args(value) when is_binary(value),
    do: String.split(value, ~r/\s+/, trim: true)

  defp normalize_extra_args(_), do: []
end
