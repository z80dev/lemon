defmodule AgentCore.CliRunners.OpencodeRunner do
  @moduledoc """
  OpenCode CLI subprocess runner.

  Wraps the `opencode` CLI and streams JSONL events from:

      opencode run --format json [--session <ses_...>] [--model <model>] -- <prompt>
  """

  use AgentCore.CliRunners.JsonlRunner

  alias AgentCore.CliRunners.OpencodeSchema
  alias AgentCore.CliRunners.OpencodeSchema.{Error, StepFinish, StepStart, Text, ToolUse, Unknown}
  alias AgentCore.CliRunners.ToolActionHelpers
  alias AgentCore.CliRunners.Types.{EventFactory, ResumeToken}
  alias LemonCore.Config, as: LemonConfig

  @engine "opencode"

  defmodule RunnerState do
    @moduledoc false
    defstruct [
      :factory,
      :found_session,
      :pending_actions,
      :last_text,
      :started_emitted,
      :saw_step_finish,
      :cwd,
      :config
    ]

    def new(resume, cwd \\ nil, config \\ nil) do
      %__MODULE__{
        factory: EventFactory.new("opencode"),
        found_session: resume,
        pending_actions: %{},
        last_text: nil,
        started_emitted: false,
        saw_step_finish: false,
        cwd: cwd,
        config: config
      }
    end
  end

  @impl true
  def engine, do: @engine

  @impl true
  def init_state(_prompt, resume) do
    RunnerState.new(resume)
  end

  @impl true
  def init_state(_prompt, resume, cwd) do
    RunnerState.new(resume, cwd, LemonConfig.load(cwd))
  end

  @impl true
  def build_command(prompt, resume, state) do
    args = ["run", "--format", "json"]

    args =
      case resume do
        %ResumeToken{value: session_id} -> args ++ ["--session", session_id]
        nil -> args
      end

    args =
      case opencode_model(state) do
        model when is_binary(model) and model != "" -> args ++ ["--model", model]
        _ -> args
      end

    # OpenCode takes prompt as CLI arg after `--`.
    {"opencode", args ++ ["--", prompt]}
  end

  @impl true
  def stdin_payload(_prompt, _resume, _state), do: nil

  @impl true
  def decode_line(line), do: OpencodeSchema.decode_event(line)

  @impl true
  def translate_event(%StepStart{sessionID: session_id}, state) do
    state = maybe_capture_session(state, session_id)
    {start_events, state} = maybe_emit_started(state)
    {start_events, state, maybe_found_session_opt(state)}
  end

  def translate_event(%ToolUse{sessionID: session_id, part: part}, state) do
    state = maybe_capture_session(state, session_id)
    {start_events, state} = maybe_emit_started(state)

    {tool_events, state} = translate_tool_use(part, state)
    {start_events ++ tool_events, state, maybe_found_session_opt(state)}
  end

  def translate_event(%Text{sessionID: session_id, part: part}, state) do
    state = maybe_capture_session(state, session_id)
    {start_events, state} = maybe_emit_started(state)

    text =
      case part do
        %{"text" => t} when is_binary(t) -> t
        %{text: t} when is_binary(t) -> t
        _ -> nil
      end

    state =
      if is_binary(text) and text != "" do
        %{state | last_text: (state.last_text || "") <> text}
      else
        state
      end

    {start_events, state, maybe_found_session_opt(state)}
  end

  def translate_event(%StepFinish{sessionID: session_id, part: part}, state) do
    state = maybe_capture_session(state, session_id)
    {start_events, state} = maybe_emit_started(state)

    reason =
      case part do
        %{"reason" => r} when is_binary(r) -> r
        %{reason: r} when is_binary(r) -> r
        _ -> nil
      end

    state = %{state | saw_step_finish: true}

    if reason == "stop" do
      answer = state.last_text || ""

      {event, factory} =
        EventFactory.completed_ok(state.factory, answer, resume: state.found_session)

      state = %{state | factory: factory}
      {start_events ++ [event], state, [done: true] ++ maybe_found_session_opt(state)}
    else
      {start_events, state, maybe_found_session_opt(state)}
    end
  end

  def translate_event(%Error{sessionID: session_id, error: err, message: message}, state) do
    state = maybe_capture_session(state, session_id)
    {start_events, state} = maybe_emit_started(state)

    error_text = opencode_error_message(message, err)

    {event, factory} =
      EventFactory.completed_error(state.factory, error_text,
        answer: state.last_text || "",
        resume: state.found_session
      )

    state = %{state | factory: factory}
    {start_events ++ [event], state, [done: true] ++ maybe_found_session_opt(state)}
  end

  def translate_event(%Unknown{}, state) do
    {[], state, []}
  end

  def translate_event(_data, state), do: {[], state, []}

  @impl true
  def handle_exit_error(exit_code, state) do
    message = "opencode failed (rc=#{exit_code})"
    {note_event, factory} = EventFactory.note(state.factory, message, ok: false)

    {completed_event, factory} =
      EventFactory.completed_error(factory, message,
        answer: state.last_text || "",
        resume: state.found_session
      )

    state = %{state | factory: factory}
    {[note_event, completed_event], state}
  end

  @impl true
  def handle_stream_end(state) do
    # OpenCode should end with a step_finish(reason=stop). If not, be conservative.
    answer = state.last_text || ""

    cond do
      state.found_session == nil ->
        message = "opencode finished but no sessionID was captured"
        {event, factory} = EventFactory.completed_error(state.factory, message, answer: answer)
        {[event], %{state | factory: factory}}

      state.saw_step_finish ->
        {event, factory} =
          EventFactory.completed_ok(state.factory, answer, resume: state.found_session)

        {[event], %{state | factory: factory}}

      true ->
        message = "opencode finished without a result event"

        {event, factory} =
          EventFactory.completed_error(state.factory, message,
            answer: answer,
            resume: state.found_session
          )

        {[event], %{state | factory: factory}}
    end
  end

  # ============================================================================
  # Translation helpers
  # ============================================================================

  defp translate_tool_use(part, state) when not is_map(part), do: {[], state}

  defp translate_tool_use(part, state) do
    part = stringify_keys(part)
    tool_state = Map.get(part, "state") |> ensure_map()
    status = Map.get(tool_state, "status")

    call_id =
      cond do
        is_binary(part["callID"]) and part["callID"] != "" -> part["callID"]
        is_binary(part["id"]) and part["id"] != "" -> part["id"]
        true -> "opencode.tool.#{:erlang.unique_integer([:positive])}"
      end

    tool_name = Map.get(part, "tool") || "tool"
    tool_input = Map.get(tool_state, "input") |> ensure_map()

    {kind, title} =
      tool_kind_and_title(to_string(tool_name), tool_input,
        path_keys: ["file_path", "filePath"],
        cwd: state.cwd
      )

    title =
      case tool_state["title"] do
        t when is_binary(t) and t != "" -> normalize_tool_title(t, tool_input, state.cwd)
        _ -> title
      end

    detail =
      %{
        "name" => tool_name,
        "input" => tool_input,
        "callID" => call_id
      }
      |> maybe_put_changes(kind, tool_input, ["file_path", "filePath"])

    case status do
      "completed" ->
        output = Map.get(tool_state, "output")
        metadata = Map.get(tool_state, "metadata") |> ensure_map()
        exit_code = Map.get(metadata, "exit")
        ok = not (is_integer(exit_code) and exit_code != 0)

        detail =
          detail
          |> maybe_put("output_preview", preview(output))
          |> maybe_put("exit_code", exit_code)

        {event, factory, pending_actions} =
          ToolActionHelpers.complete_action(
            state.factory,
            state.pending_actions,
            call_id,
            ok,
            detail,
            kind,
            title
          )

        state = %{state | factory: factory, pending_actions: pending_actions}
        {[event], state}

      "error" ->
        error_value = Map.get(tool_state, "error")
        metadata = Map.get(tool_state, "metadata") |> ensure_map()
        exit_code = Map.get(metadata, "exit")

        detail =
          detail
          |> maybe_put("error", error_value)
          |> maybe_put("exit_code", exit_code)

        {event, factory, pending_actions} =
          ToolActionHelpers.complete_action(
            state.factory,
            state.pending_actions,
            call_id,
            false,
            detail,
            kind,
            title
          )

        state = %{state | factory: factory, pending_actions: pending_actions}
        {[event], state}

      _ ->
        {event, factory, pending_actions} =
          ToolActionHelpers.start_action(
            state.factory,
            state.pending_actions,
            call_id,
            kind,
            title,
            detail
          )

        state = %{state | factory: factory, pending_actions: pending_actions}
        {[event], state}
    end
  end

  defp maybe_capture_session(state, session_id)
       when is_binary(session_id) and session_id != "" and state.found_session == nil do
    %{state | found_session: ResumeToken.new(@engine, session_id)}
  end

  defp maybe_capture_session(state, _), do: state

  defp maybe_emit_started(%RunnerState{started_emitted: true} = state), do: {[], state}

  defp maybe_emit_started(%RunnerState{found_session: %ResumeToken{} = token} = state) do
    title = opencode_title(state)
    {event, factory} = EventFactory.started(state.factory, token, title: title)
    {[event], %{state | factory: factory, started_emitted: true}}
  end

  defp maybe_emit_started(state), do: {[], state}

  defp maybe_found_session_opt(%RunnerState{found_session: %ResumeToken{} = token}),
    do: [found_session: token]

  defp maybe_found_session_opt(_), do: []

  defp opencode_model(%RunnerState{config: %LemonConfig{} = cfg}) do
    get_in(cfg.agent || %{}, [:cli, :opencode, :model])
  end

  defp opencode_model(_), do: nil

  defp opencode_title(state) do
    model = opencode_model(state)
    if is_binary(model) and model != "", do: model, else: "OpenCode"
  end

  defp opencode_error_message(message, err) do
    raw = if message != nil, do: message, else: err

    cond do
      is_binary(raw) and raw != "" ->
        raw

      is_map(raw) ->
        data = Map.get(raw, "data")

        cond do
          is_map(data) and is_binary(Map.get(data, "message")) ->
            Map.get(data, "message")

          is_binary(Map.get(raw, "message")) ->
            Map.get(raw, "message")

          is_binary(Map.get(raw, "name")) ->
            Map.get(raw, "name")

          true ->
            "opencode error"
        end

      true ->
        "opencode error"
    end
  end

  defp ensure_map(v) when is_map(v), do: stringify_keys(v)
  defp ensure_map(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp maybe_put_changes(detail, :file_change, input, path_keys) do
    case tool_input_path(input, path_keys) do
      path when is_binary(path) and path != "" ->
        Map.put(detail, "changes", [%{"path" => path, "kind" => "update"}])

      _ ->
        detail
    end
  end

  defp maybe_put_changes(detail, _kind, _input, _path_keys), do: detail

  defp preview(nil), do: nil

  defp preview(v) do
    s =
      cond do
        is_binary(v) -> v
        true -> inspect(v)
      end

    if byte_size(s) > 500, do: binary_part(s, 0, 500), else: s
  end

  defp tool_input_path(input, keys) when is_map(input) do
    Enum.find_value(keys, fn k ->
      v = Map.get(input, k)
      if is_binary(v) and v != "", do: v, else: nil
    end)
  end

  defp tool_input_path(_input, _keys), do: nil

  defp normalize_tool_title(title, tool_input, cwd) do
    if String.contains?(title, "`") do
      title
    else
      case tool_input_path(tool_input, ["file_path", "filePath"]) do
        path when is_binary(path) and path != "" ->
          rel = maybe_relativize_path(path, cwd)

          if title in [path, rel] do
            "`#{rel}`"
          else
            title
          end

        _ ->
          title
      end
    end
  end

  defp tool_kind_and_title(name, input, opts) do
    name_lower = name |> to_string() |> String.downcase()
    cwd = Keyword.get(opts, :cwd)
    path_keys = Keyword.fetch!(opts, :path_keys)

    cond do
      name_lower in ["bash", "shell", "killshell"] ->
        command = Map.get(input, "command") || Map.get(input, "cmd") || name
        {:command, String.slice(to_string(command), 0, 80)}

      name_lower in ["edit", "write", "multiedit", "notebookedit"] ->
        path = tool_input_path(input, path_keys)
        title = if path, do: maybe_relativize_path(path, cwd), else: name
        {:file_change, title}

      name_lower == "read" ->
        path = tool_input_path(input, path_keys)
        if path, do: {:tool, "read: `#{maybe_relativize_path(path, cwd)}`"}, else: {:tool, "read"}

      name_lower == "glob" ->
        pattern = Map.get(input, "pattern")
        if pattern, do: {:tool, "glob: `#{pattern}`"}, else: {:tool, "glob"}

      name_lower == "grep" ->
        pattern = Map.get(input, "pattern")
        if pattern, do: {:tool, "grep: #{pattern}"}, else: {:tool, "grep"}

      name_lower == "find" ->
        pattern = Map.get(input, "pattern")
        if pattern, do: {:tool, "find: #{pattern}"}, else: {:tool, "find"}

      name_lower == "ls" ->
        path = tool_input_path(input, path_keys)
        if path, do: {:tool, "ls: `#{maybe_relativize_path(path, cwd)}`"}, else: {:tool, "ls"}

      name_lower in ["websearch", "web_search"] ->
        query = Map.get(input, "query")
        {:web_search, to_string(query || "search")}

      name_lower in ["webfetch", "web_fetch"] ->
        url = Map.get(input, "url")
        {:web_search, to_string(url || "fetch")}

      name_lower in ["task", "agent"] ->
        desc = Map.get(input, "description") || Map.get(input, "prompt")
        {:subagent, to_string(desc || name)}

      true ->
        {:tool, name}
    end
  end

  defp maybe_relativize_path(path, nil), do: path

  defp maybe_relativize_path(path, cwd) when is_binary(path) and is_binary(cwd) do
    expanded_path = Path.expand(path)
    expanded_cwd = Path.expand(cwd)

    try do
      rel = Path.relative_to(expanded_path, expanded_cwd)
      if String.starts_with?(rel, ".."), do: path, else: rel
    rescue
      _ -> path
    end
  end

  defp maybe_relativize_path(path, _cwd), do: path
end
