defmodule AgentCore.CliRunners.DroidRunner do
  @moduledoc """
  Factory Droid CLI subprocess runner.
  """

  use AgentCore.CliRunners.JsonlRunner

  alias AgentCore.CliRunners.DroidSchema

  alias AgentCore.CliRunners.DroidSchema.{
    DroidCompletionEvent,
    DroidMessageEvent,
    DroidReasoningEvent,
    DroidSystemEvent,
    DroidToolCallEvent,
    DroidToolResultEvent
  }

  alias AgentCore.CliRunners.ToolActionHelpers
  alias AgentCore.CliRunners.Types.EventFactory
  alias LemonCore.Config, as: LemonConfig
  alias LemonCore.Introspection
  alias LemonCore.ResumeToken

  @engine "droid"
  @default_model "glm-5.1"

  defmodule RunnerState do
    @moduledoc false
    defstruct [
      :factory,
      :found_session,
      :last_assistant_text,
      :pending_actions,
      :pending_reasoning,
      :cwd,
      :config,
      :model_override,
      :reasoning_effort_override,
      :enabled_tools_override,
      :disabled_tools_override,
      :use_spec_override,
      :spec_model_override
    ]

    def new(cwd \\ nil, config \\ nil, opts \\ []) do
      %__MODULE__{
        factory: EventFactory.new("droid"),
        found_session: nil,
        last_assistant_text: nil,
        pending_actions: %{},
        pending_reasoning: %{},
        cwd: cwd || File.cwd!(),
        config: config,
        model_override: normalize_model(Keyword.get(opts, :model)),
        reasoning_effort_override:
          normalize_reasoning_effort(
            Keyword.get(opts, :reasoning_effort) || Keyword.get(opts, :thinking_level)
          ),
        enabled_tools_override: normalize_tools(Keyword.get(opts, :enabled_tools)),
        disabled_tools_override: normalize_tools(Keyword.get(opts, :disabled_tools)),
        use_spec_override: normalize_optional_boolean(Keyword.get(opts, :use_spec)),
        spec_model_override: normalize_model(Keyword.get(opts, :spec_model))
      }
    end

    defp normalize_tools(nil), do: nil
    defp normalize_tools(value) when is_list(value), do: Enum.map(value, &to_string/1)

    defp normalize_tools(value) when is_binary(value) do
      case String.split(value, ~r/[\s,]+/, trim: true) do
        [] -> nil
        tools -> tools
      end
    end

    defp normalize_tools(_), do: nil

    defp normalize_optional_boolean(nil), do: nil
    defp normalize_optional_boolean(value) when is_boolean(value), do: value
    defp normalize_optional_boolean("true"), do: true
    defp normalize_optional_boolean("false"), do: false
    defp normalize_optional_boolean(_), do: nil

    defp normalize_reasoning_effort(nil), do: nil

    defp normalize_reasoning_effort(value) when is_binary(value) do
      case String.trim(value) |> String.downcase() do
        "" -> nil
        effort when effort in ["off", "none", "low", "medium", "high"] -> effort
        _ -> nil
      end
    end

    defp normalize_reasoning_effort(_), do: nil

    defp normalize_model(nil), do: nil

    defp normalize_model(model) when is_binary(model) do
      trimmed = String.trim(model)

      cond do
        trimmed == "" ->
          nil

        true ->
          case String.split(trimmed, ~r/[:\/]/, parts: 2) do
            [prefix, id] when prefix in ["droid", "factory", "factory-droid"] ->
              normalized = String.trim(id)
              if normalized == "", do: nil, else: normalized

            _ ->
              trimmed
          end
      end
    end

    defp normalize_model(_), do: nil
  end

  @impl true
  def engine, do: @engine

  @impl true
  def init_state(_prompt, _resume), do: RunnerState.new()

  @impl true
  def init_state(_prompt, _resume, cwd), do: RunnerState.new(cwd, LemonConfig.load(cwd))

  @impl true
  def init_state(_prompt, _resume, cwd, opts),
    do: RunnerState.new(cwd, LemonConfig.load(cwd), opts)

  @impl true
  def build_command(prompt, resume, state) do
    args =
      ["exec", "-o", "stream-json", "--skip-permissions-unsafe"]
      |> maybe_add_resume(resume)
      |> maybe_add_model(state)
      |> maybe_add_reasoning_effort(state)
      |> maybe_add_enabled_tools(state)
      |> maybe_add_disabled_tools(state)
      |> maybe_add_spec_flags(state)
      |> Kernel.++(droid_extra_args(state))
      |> Kernel.++(["--cwd", state.cwd, sanitize_prompt(prompt)])

    {"droid", args}
  end

  @impl true
  def stdin_payload(_prompt, _resume, _state), do: nil

  @impl true
  def env(_state) do
    case System.get_env("FACTORY_API_KEY") do
      value when is_binary(value) and value != "" -> [{"FACTORY_API_KEY", value}]
      _ -> nil
    end
  end

  @impl true
  def decode_line(line), do: DroidSchema.decode_line(line)

  @impl true
  def translate_event(%DroidSystemEvent{subtype: "init", session_id: session_id} = event, state) do
    token = capture_session(state.found_session, session_id)

    if token do
      meta = %{cwd: event.cwd, tools: event.tools, model: event.model}

      {started_event, factory} =
        EventFactory.started(state.factory, token, title: "Droid", meta: meta)

      Introspection.record(
        :engine_subprocess_started,
        %{engine: @engine, session_id: token.value, model: event.model},
        engine: @engine,
        provenance: :inferred
      )

      state = %{state | factory: factory, found_session: token}
      {[started_event], state, [found_session: token]}
    else
      {[], state, []}
    end
  end

  def translate_event(
        %DroidMessageEvent{role: "assistant", text: text, session_id: session_id},
        state
      ) do
    {reasoning_events, state} =
      state
      |> maybe_capture_session(session_id)
      |> maybe_capture_assistant_text(text)
      |> flush_reasoning_notes()

    {reasoning_events, state, []}
  end

  def translate_event(
        %DroidReasoningEvent{id: id, text: text, session_id: session_id},
        state
      ) do
    state = maybe_capture_session(state, session_id)
    action_id = normalize_reasoning_id(id)
    title = normalize_reasoning_title(text)
    detail = %{text: normalize_reasoning_text(text)}

    {phase, pending_reasoning} =
      if Map.has_key?(state.pending_reasoning, action_id) do
        {:updated, Map.put(state.pending_reasoning, action_id, title)}
      else
        {:started, Map.put(state.pending_reasoning, action_id, title)}
      end

    {event, factory} =
      EventFactory.action(state.factory,
        phase: phase,
        action_id: action_id,
        kind: :note,
        title: title,
        detail: detail
      )

    state = %{state | factory: factory, pending_reasoning: pending_reasoning}
    {[event], state, []}
  end

  def translate_event(
        %DroidToolCallEvent{
          id: id,
          toolName: tool_name,
          parameters: parameters,
          session_id: session_id
        },
        state
      ) do
    state = maybe_capture_session(state, session_id)
    tool_name = normalize_tool_name(tool_name)
    tool_input = parameters |> ensure_map() |> ToolActionHelpers.stringify_keys()

    {kind, title} =
      ToolActionHelpers.tool_kind_and_title(tool_name, tool_input,
        path_keys: ["path", "file_path", "filePath"],
        cwd: state.cwd
      )

    detail = %{tool_name: tool_name, input: tool_input}

    {event, factory, pending_actions} =
      ToolActionHelpers.start_action(
        state.factory,
        state.pending_actions,
        normalize_action_id(id),
        kind,
        title,
        detail
      )

    state = %{state | factory: factory, pending_actions: pending_actions}
    {[event], state, []}
  end

  def translate_event(
        %DroidToolResultEvent{id: id, isError: is_error, value: value, session_id: session_id},
        state
      ) do
    state = maybe_capture_session(state, session_id)
    preview = ToolActionHelpers.normalize_tool_result(value)

    detail = %{
      result: value,
      result_preview: preview,
      result_summary: preview,
      is_error: is_error == true
    }

    {event, factory, pending_actions} =
      ToolActionHelpers.complete_action(
        state.factory,
        state.pending_actions,
        normalize_action_id(id),
        is_error != true,
        detail
      )

    state = %{state | factory: factory, pending_actions: pending_actions}
    {[event], state, []}
  end

  def translate_event(
        %DroidCompletionEvent{
          finalText: final_text,
          numTurns: num_turns,
          durationMs: duration_ms,
          session_id: session_id
        },
        state
      ) do
    token = capture_session(state.found_session, session_id)
    answer = normalize_answer(final_text || state.last_assistant_text)
    {reasoning_events, state} = flush_reasoning_notes(%{state | found_session: token})

    Introspection.record(
      :engine_output_observed,
      %{
        engine: @engine,
        ok: true,
        has_answer: answer != "",
        num_turns: num_turns,
        duration_ms: duration_ms
      },
      engine: @engine,
      provenance: :inferred
    )

    usage =
      %{}
      |> maybe_put_map(:num_turns, num_turns)
      |> maybe_put_map(:duration_ms, duration_ms)
      |> case do
        usage when map_size(usage) == 0 -> nil
        usage -> usage
      end

    {event, factory} =
      EventFactory.completed_ok(state.factory, answer, resume: token, usage: usage)

    state = %{state | factory: factory, found_session: token}
    {reasoning_events ++ [event], state, [done: true] ++ maybe_found_session_opt(token)}
  end

  def translate_event(_data, state), do: {[], state, []}

  @impl true
  def handle_exit_error(exit_code, state) do
    {reasoning_events, state} = flush_reasoning_notes(state)

    Introspection.record(
      :engine_subprocess_exited,
      %{engine: @engine, exit_code: exit_code, ok: false},
      engine: @engine,
      provenance: :inferred
    )

    message = "droid exec failed (rc=#{exit_code})"
    {note_event, factory} = EventFactory.note(state.factory, message, ok: false)

    {completed_event, factory} =
      EventFactory.completed_error(factory, message,
        answer: normalize_answer(state.last_assistant_text),
        resume: state.found_session
      )

    state = %{state | factory: factory}
    {reasoning_events ++ [note_event, completed_event], state}
  end

  @impl true
  def handle_stream_end(state) do
    {reasoning_events, state} = flush_reasoning_notes(state)
    answer = normalize_answer(state.last_assistant_text)

    cond do
      state.found_session == nil ->
        message = "droid exec finished but no session_id was captured"
        {event, factory} = EventFactory.completed_error(state.factory, message, answer: answer)
        {reasoning_events ++ [event], %{state | factory: factory}}

      true ->
        message = "droid exec ended without a completion event"

        {event, factory} =
          EventFactory.completed_error(state.factory, message,
            answer: answer,
            resume: state.found_session
          )

        {reasoning_events ++ [event], %{state | factory: factory}}
    end
  end

  defp maybe_add_resume(args, %ResumeToken{value: session_id}), do: args ++ ["-s", session_id]
  defp maybe_add_resume(args, _), do: args

  defp maybe_add_model(args, state) do
    case droid_model(state) do
      model when is_binary(model) and model != "" -> args ++ ["-m", model]
      _ -> args
    end
  end

  defp maybe_add_reasoning_effort(args, state) do
    case droid_reasoning_effort(state) do
      effort when is_binary(effort) and effort != "" -> args ++ ["--reasoning-effort", effort]
      _ -> args
    end
  end

  defp maybe_add_enabled_tools(args, state) do
    case droid_enabled_tools(state) do
      [] -> args
      tools -> args ++ ["--enabled-tools", Enum.join(tools, ",")]
    end
  end

  defp maybe_add_disabled_tools(args, state) do
    case droid_disabled_tools(state) do
      [] -> args
      tools -> args ++ ["--disabled-tools", Enum.join(tools, ",")]
    end
  end

  defp maybe_add_spec_flags(args, state) do
    if droid_use_spec?(state) do
      case droid_spec_model(state) do
        model when is_binary(model) and model != "" ->
          args ++ ["--use-spec", "--spec-model", model]

        _ ->
          args ++ ["--use-spec"]
      end
    else
      args
    end
  end

  defp droid_model(%RunnerState{model_override: model}) when is_binary(model), do: model

  defp droid_model(%RunnerState{config: %LemonConfig{} = cfg}) do
    case get_in(cfg.agent || %{}, [:cli, :droid, :model]) do
      model when is_binary(model) ->
        case String.trim(model) do
          "" -> @default_model
          trimmed -> trimmed
        end

      _ ->
        @default_model
    end
  end

  defp droid_model(_), do: @default_model

  defp droid_reasoning_effort(%RunnerState{reasoning_effort_override: effort})
       when is_binary(effort), do: effort

  defp droid_reasoning_effort(%RunnerState{config: %LemonConfig{} = cfg}),
    do: get_in(cfg.agent || %{}, [:cli, :droid, :reasoning_effort])

  defp droid_reasoning_effort(_), do: nil

  defp droid_enabled_tools(%RunnerState{enabled_tools_override: tools}) when is_list(tools),
    do: tools

  defp droid_enabled_tools(%RunnerState{config: %LemonConfig{} = cfg}),
    do: get_in(cfg.agent || %{}, [:cli, :droid, :enabled_tools]) || []

  defp droid_enabled_tools(_), do: []

  defp droid_disabled_tools(%RunnerState{disabled_tools_override: tools}) when is_list(tools),
    do: tools

  defp droid_disabled_tools(%RunnerState{config: %LemonConfig{} = cfg}),
    do: get_in(cfg.agent || %{}, [:cli, :droid, :disabled_tools]) || []

  defp droid_disabled_tools(_), do: []

  defp droid_use_spec?(%RunnerState{use_spec_override: value}) when is_boolean(value), do: value

  defp droid_use_spec?(%RunnerState{config: %LemonConfig{} = cfg}),
    do: get_in(cfg.agent || %{}, [:cli, :droid, :use_spec]) == true

  defp droid_use_spec?(_), do: false

  defp droid_spec_model(%RunnerState{spec_model_override: model}) when is_binary(model), do: model

  defp droid_spec_model(%RunnerState{config: %LemonConfig{} = cfg}),
    do: get_in(cfg.agent || %{}, [:cli, :droid, :spec_model])

  defp droid_spec_model(_), do: nil

  defp droid_extra_args(%RunnerState{config: %LemonConfig{} = cfg}),
    do: get_in(cfg.agent || %{}, [:cli, :droid, :extra_args]) || []

  defp droid_extra_args(_), do: []

  defp maybe_capture_session(state, session_id) do
    %{state | found_session: capture_session(state.found_session, session_id)}
  end

  defp capture_session(%ResumeToken{} = token, nil), do: token
  defp capture_session(%ResumeToken{} = token, ""), do: token

  defp capture_session(_current, session_id) when is_binary(session_id) and session_id != "",
    do: ResumeToken.new(@engine, session_id)

  defp capture_session(current, _), do: current

  defp maybe_capture_assistant_text(state, text) when is_binary(text) and text != "" do
    %{state | last_assistant_text: text}
  end

  defp maybe_capture_assistant_text(state, _), do: state

  defp flush_reasoning_notes(%RunnerState{pending_reasoning: pending_reasoning} = state)
       when map_size(pending_reasoning) == 0 do
    {[], state}
  end

  defp flush_reasoning_notes(%RunnerState{pending_reasoning: pending_reasoning} = state) do
    {events, factory} =
      Enum.reduce(pending_reasoning, {[], state.factory}, fn {action_id, title},
                                                             {events, factory} ->
        {event, factory} =
          EventFactory.action_completed(factory, action_id, :note, title, true,
            detail: %{text: title}
          )

        {events ++ [event], factory}
      end)

    {events, %{state | factory: factory, pending_reasoning: %{}}}
  end

  defp normalize_action_id(id) when is_binary(id) and id != "", do: id
  defp normalize_action_id(_), do: "droid.tool.#{:erlang.unique_integer([:positive])}"

  defp normalize_reasoning_id(id) when is_binary(id) and id != "", do: id
  defp normalize_reasoning_id(_), do: "droid.reasoning.#{:erlang.unique_integer([:positive])}"

  defp normalize_reasoning_text(text) when is_binary(text), do: String.trim(text)
  defp normalize_reasoning_text(_), do: ""

  defp normalize_reasoning_title(text) do
    text
    |> normalize_reasoning_text()
    |> case do
      "" -> "Reasoning"
      normalized -> String.slice(normalized, 0, 100)
    end
  end

  defp normalize_tool_name(name) when is_binary(name) and name != "", do: name
  defp normalize_tool_name(_), do: "tool"

  defp normalize_answer(answer) when is_binary(answer), do: String.trim(answer)
  defp normalize_answer(_), do: ""

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  defp sanitize_prompt(prompt) when is_binary(prompt) do
    if String.starts_with?(prompt, "-"), do: " " <> prompt, else: prompt
  end

  defp sanitize_prompt(prompt), do: to_string(prompt)

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp maybe_found_session_opt(%ResumeToken{} = token), do: [found_session: token]
  defp maybe_found_session_opt(_), do: []
end
