defmodule AgentCore.CliRunners.PiRunner do
  @moduledoc """
  Pi Coding Agent CLI subprocess runner.

  Wraps the `pi` CLI and streams JSONL events from:

      pi [extra_args...] --print --mode json [--provider <provider>] [--model <model>] --session <token> <prompt>
  """

  use AgentCore.CliRunners.JsonlRunner

  alias AgentCore.CliRunners.PiSchema

  alias AgentCore.CliRunners.PiSchema.{
    AgentEnd,
    MessageEnd,
    SessionHeader,
    ToolExecutionEnd,
    ToolExecutionStart,
    Unknown
  }

  alias AgentCore.CliRunners.ToolActionHelpers
  alias AgentCore.CliRunners.Types.{EventFactory, ResumeToken}
  alias LemonCore.Config, as: LemonConfig

  @engine "pi"
  @session_id_prefix_len 8

  defmodule RunnerState do
    @moduledoc false
    defstruct [
      :factory,
      :cwd,
      :config,
      :resume_token,
      :allow_id_promotion,
      :found_session,
      :pending_actions,
      :last_assistant_text,
      :last_assistant_error,
      :last_usage,
      :started_emitted
    ]

    def new(resume, cwd \\ nil, config \\ nil) do
      {token, allow_promotion?} =
        case resume do
          %ResumeToken{} = r ->
            {r, false}

          nil ->
            # Pi requires a session token for new runs. Use a new session JSONL path.
            path = new_session_path(cwd)
            {ResumeToken.new("pi", path), true}
        end

      %__MODULE__{
        factory: EventFactory.new("pi"),
        cwd: cwd,
        config: config,
        resume_token: token,
        allow_id_promotion: allow_promotion?,
        found_session: token,
        pending_actions: %{},
        last_assistant_text: nil,
        last_assistant_error: nil,
        last_usage: nil,
        started_emitted: false
      }
    end

    defp new_session_path(cwd) do
      base_dir =
        case System.get_env("PI_CODING_AGENT_DIR") do
          nil -> Path.join([System.user_home!(), ".pi", "agent"])
          "" -> Path.join([System.user_home!(), ".pi", "agent"])
          dir -> Path.expand(dir)
        end

      cwd = if is_binary(cwd) and cwd != "", do: Path.expand(cwd), else: File.cwd!()
      cwd_str = cwd |> String.trim_leading("/") |> String.trim_leading("\\")

      safe_part =
        cwd_str
        |> String.replace(~r/[\/\\:]/, "-")

      session_dir = Path.join([base_dir, "sessions", "--#{safe_part}--"])
      _ = File.mkdir_p(session_dir)

      timestamp =
        DateTime.utc_now()
        |> DateTime.to_iso8601()
        |> String.replace(":", "-")
        |> String.replace(".", "-")

      rand = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      filename = "#{timestamp}_#{rand}.jsonl"
      Path.join(session_dir, filename)
    rescue
      _ ->
        # Fallback: keep session token simple if we can't create dirs.
        "pi_session_#{:erlang.unique_integer([:positive])}"
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
  def build_command(prompt, _resume, state) do
    args =
      []
      |> Kernel.++(pi_extra_args(state))
      |> Kernel.++(["--print", "--mode", "json"])

    args =
      case pi_provider(state) do
        provider when is_binary(provider) and provider != "" -> args ++ ["--provider", provider]
        _ -> args
      end

    args =
      case pi_model(state) do
        model when is_binary(model) and model != "" -> args ++ ["--model", model]
        _ -> args
      end

    args = args ++ ["--session", state.resume_token.value, sanitize_prompt(prompt)]
    {"pi", args}
  end

  @impl true
  def stdin_payload(_prompt, _resume, _state), do: nil

  @impl true
  def env(_state) do
    env = System.get_env()
    env = Map.put_new(env, "NO_COLOR", "1")
    env = Map.put_new(env, "CI", "1")
    Enum.to_list(env)
  end

  @impl true
  def decode_line(line), do: PiSchema.decode_event(line)

  @impl true
  def translate_event(%SessionHeader{id: session_id}, state) do
    state = maybe_promote_session_id(state, session_id)
    {start_events, state} = maybe_emit_started(state)
    {start_events, state, maybe_found_session_opt(state)}
  end

  def translate_event(%ToolExecutionStart{} = ev, state) do
    {start_events, state} = maybe_emit_started(state)
    {tool_events, state} = handle_tool_start(ev, state)
    {start_events ++ tool_events, state, maybe_found_session_opt(state)}
  end

  def translate_event(%ToolExecutionEnd{} = ev, state) do
    {start_events, state} = maybe_emit_started(state)
    {tool_events, state} = handle_tool_end(ev, state)
    {start_events ++ tool_events, state, maybe_found_session_opt(state)}
  end

  def translate_event(%MessageEnd{message: message}, state) do
    {start_events, state} = maybe_emit_started(state)
    state = capture_assistant_message(state, message)
    {start_events, state, maybe_found_session_opt(state)}
  end

  def translate_event(%AgentEnd{messages: messages}, state) do
    {start_events, state} = maybe_emit_started(state)

    state =
      case last_assistant_message(messages) do
        nil -> state
        msg -> capture_assistant_message(state, msg)
      end

    ok = state.last_assistant_error == nil
    answer = state.last_assistant_text || ""

    {event, factory} =
      if ok do
        EventFactory.completed_ok(state.factory, answer,
          resume: state.resume_token,
          usage: state.last_usage
        )
      else
        EventFactory.completed_error(state.factory, state.last_assistant_error,
          answer: answer,
          resume: state.resume_token,
          usage: state.last_usage
        )
      end

    state = %{state | factory: factory}

    {start_events ++ [event], state, [done: true] ++ maybe_found_session_opt(state)}
  end

  def translate_event(%Unknown{}, state) do
    {start_events, state} = maybe_emit_started(state)
    {start_events, state, maybe_found_session_opt(state)}
  end

  def translate_event(_data, state) do
    {start_events, state} = maybe_emit_started(state)
    {start_events, state, maybe_found_session_opt(state)}
  end

  @impl true
  def handle_exit_error(exit_code, state) do
    message = "pi failed (rc=#{exit_code})"
    {note_event, factory} = EventFactory.note(state.factory, message, ok: false)

    {completed_event, factory} =
      EventFactory.completed_error(factory, message,
        answer: state.last_assistant_text || "",
        resume: state.resume_token,
        usage: state.last_usage
      )

    state = %{state | factory: factory}
    {[note_event, completed_event], state}
  end

  @impl true
  def handle_stream_end(state) do
    message = "pi finished without an agent_end event"

    {event, factory} =
      EventFactory.completed_error(state.factory, message,
        answer: state.last_assistant_text || "",
        resume: state.resume_token,
        usage: state.last_usage
      )

    {[event], %{state | factory: factory}}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp maybe_emit_started(%RunnerState{started_emitted: true} = state), do: {[], state}

  defp maybe_emit_started(state) do
    title = pi_title(state)
    meta = pi_meta(state)

    {event, factory} =
      EventFactory.started(state.factory, state.resume_token, title: title, meta: meta)

    {[event], %{state | factory: factory, started_emitted: true}}
  end

  defp maybe_found_session_opt(%RunnerState{found_session: %ResumeToken{} = token}),
    do: [found_session: token]

  defp maybe_found_session_opt(_), do: []

  defp handle_tool_start(
         %ToolExecutionStart{toolCallId: tool_id, toolName: tool_name, args: args},
         state
       ) do
    tool_id =
      if is_binary(tool_id) and tool_id != "",
        do: tool_id,
        else: "pi.tool.#{:erlang.unique_integer([:positive])}"

    args = if is_map(args), do: stringify_keys(args), else: %{}
    name = if is_binary(tool_name) and tool_name != "", do: tool_name, else: "tool"

    {kind, title} = tool_kind_and_title(name, args, path_keys: ["path"], cwd: state.cwd)

    detail =
      %{
        "tool_name" => name,
        "args" => args
      }
      |> maybe_put_changes(kind, args, ["path"])

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

  defp handle_tool_end(
         %ToolExecutionEnd{
           toolCallId: tool_id,
           toolName: tool_name,
           result: result,
           isError: is_error
         },
         state
       ) do
    tool_id =
      if is_binary(tool_id) and tool_id != "",
        do: tool_id,
        else: "pi.tool.#{:erlang.unique_integer([:positive])}"

    name = if is_binary(tool_name) and tool_name != "", do: tool_name, else: "tool"

    detail = %{"tool_name" => name, "result" => result, "is_error" => is_error}

    {event, factory, pending_actions} =
      ToolActionHelpers.complete_action(
        state.factory,
        state.pending_actions,
        tool_id,
        not is_error,
        detail
      )

    state = %{state | factory: factory, pending_actions: pending_actions}
    {[event], state}
  end

  defp capture_assistant_message(state, message) when is_map(message) do
    role = Map.get(message, "role") || Map.get(message, :role)

    if role == "assistant" do
      text = extract_text_blocks(Map.get(message, "content") || Map.get(message, :content))
      usage = Map.get(message, "usage") || Map.get(message, :usage)
      error = assistant_error(message)

      state =
        if is_binary(text) and text != "" do
          %{state | last_assistant_text: text}
        else
          state
        end

      state =
        if is_map(usage) do
          %{state | last_usage: usage}
        else
          state
        end

      if is_binary(error) and error != "" do
        %{state | last_assistant_error: error}
      else
        state
      end
    else
      state
    end
  end

  defp capture_assistant_message(state, _), do: state

  defp extract_text_blocks(content) when is_list(content) do
    content
    |> Enum.reduce([], fn
      %{"type" => "text", "text" => text}, acc when is_binary(text) and text != "" -> [text | acc]
      %{type: "text", text: text}, acc when is_binary(text) and text != "" -> [text | acc]
      _, acc -> acc
    end)
    |> Enum.reverse()
    |> Enum.join("")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp extract_text_blocks(_), do: nil

  defp assistant_error(message) when is_map(message) do
    stop_reason = Map.get(message, "stopReason") || Map.get(message, :stopReason)

    if stop_reason in ["error", "aborted"] do
      error = Map.get(message, "errorMessage") || Map.get(message, :errorMessage)

      cond do
        is_binary(error) and error != "" -> error
        is_binary(stop_reason) -> "pi run #{stop_reason}"
        true -> "pi run error"
      end
    else
      nil
    end
  end

  defp assistant_error(_), do: nil

  defp last_assistant_message(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn
      %{"role" => "assistant"} -> true
      %{role: "assistant"} -> true
      _ -> false
    end)
  end

  defp last_assistant_message(_), do: nil

  defp maybe_promote_session_id(%RunnerState{} = state, session_id)
       when is_binary(session_id) and session_id != "" do
    cond do
      state.started_emitted ->
        state

      not state.allow_id_promotion ->
        state

      not looks_like_session_path?(state.resume_token.value) ->
        state

      true ->
        short =
          if String.contains?(session_id, "-") do
            session_id |> String.split("-", parts: 2) |> hd()
          else
            if byte_size(session_id) > @session_id_prefix_len do
              binary_part(session_id, 0, @session_id_prefix_len)
            else
              session_id
            end
          end

        token = ResumeToken.new(@engine, short)
        %{state | resume_token: token, found_session: token, allow_id_promotion: false}
    end
  end

  defp maybe_promote_session_id(state, _), do: state

  defp looks_like_session_path?(token) when is_binary(token) do
    cond do
      token == "" -> false
      String.ends_with?(token, ".jsonl") -> true
      String.contains?(token, "/") -> true
      String.contains?(token, "\\") -> true
      String.starts_with?(token, "~") -> true
      true -> false
    end
  end

  defp looks_like_session_path?(_), do: false

  defp sanitize_prompt(prompt) when is_binary(prompt) do
    if String.starts_with?(prompt, "-"), do: " " <> prompt, else: prompt
  end

  defp sanitize_prompt(prompt), do: to_string(prompt)

  defp pi_extra_args(%RunnerState{config: %LemonConfig{} = cfg}) do
    get_in(cfg.agent || %{}, [:cli, :pi, :extra_args]) || []
  end

  defp pi_extra_args(_), do: []

  defp pi_model(%RunnerState{config: %LemonConfig{} = cfg}) do
    get_in(cfg.agent || %{}, [:cli, :pi, :model])
  end

  defp pi_model(_), do: nil

  defp pi_provider(%RunnerState{config: %LemonConfig{} = cfg}) do
    get_in(cfg.agent || %{}, [:cli, :pi, :provider])
  end

  defp pi_provider(_), do: nil

  defp pi_title(state) do
    model = pi_model(state)
    provider = pi_provider(state)

    cond do
      is_binary(model) and model != "" and is_binary(provider) and provider != "" ->
        "#{provider}:#{model}"

      is_binary(model) and model != "" ->
        model

      true ->
        "Pi"
    end
  end

  defp pi_meta(state) do
    meta = %{"cwd" => state.cwd || File.cwd!()}

    meta =
      case pi_model(state) do
        m when is_binary(m) and m != "" -> Map.put(meta, "model", m)
        _ -> meta
      end

    case pi_provider(state) do
      p when is_binary(p) and p != "" -> Map.put(meta, "provider", p)
      _ -> meta
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp maybe_put_changes(detail, :file_change, args, keys) do
    case tool_input_path(args, keys) do
      path when is_binary(path) and path != "" ->
        Map.put(detail, "changes", [%{"path" => path, "kind" => "update"}])

      _ ->
        detail
    end
  end

  defp maybe_put_changes(detail, _kind, _args, _keys), do: detail

  defp tool_input_path(input, keys) when is_map(input) do
    Enum.find_value(keys, fn k ->
      v = Map.get(input, k)
      if is_binary(v) and v != "", do: v, else: nil
    end)
  end

  defp tool_input_path(_input, _keys), do: nil

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
