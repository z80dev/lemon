defmodule CodingAgent.Session.Presentation do
  @moduledoc false

  alias Ai.Types.StreamOptions
  alias LemonCore.ResumeToken

  require Logger

  @engine "lemon"
  @reasoning_update_threshold 700

  defmodule ReasoningAccumulator do
    @moduledoc false

    defstruct blocks: %{}, seq: 0, threshold: 700
  end

  def build_session_opts(opts, cwd, run_id, session_key, agent_id) do
    tool_policy = Keyword.get(opts, :tool_policy)
    approval_timeout_ms = Keyword.get(opts, :approval_timeout_ms, :infinity)

    approval_context =
      if tool_policy do
        %{
          session_key: session_key || run_id,
          session_id: nil,
          agent_id: agent_id || "default",
          run_id: run_id,
          timeout_ms: approval_timeout_ms
        }
      else
        nil
      end

    [cwd: cwd]
    |> maybe_add_opt(:model, Keyword.get(opts, :model))
    |> maybe_add_opt(:thinking_level, Keyword.get(opts, :thinking_level))
    |> maybe_add_opt(:system_prompt, Keyword.get(opts, :system_prompt))
    |> maybe_add_opt(:stream_fn, Keyword.get(opts, :stream_fn))
    |> maybe_add_opt(:tool_policy, tool_policy)
    |> maybe_add_opt(:approval_context, approval_context)
    |> maybe_add_opt(:run_id, run_id)
    |> maybe_add_opt(:session_key, session_key)
    |> maybe_add_opt(:agent_id, agent_id)
    |> maybe_add_opt(:acp_session_id, Keyword.get(opts, :acp_session_id))
    |> maybe_add_opt(
      :acp_client_fs_read_text_file,
      Keyword.get(opts, :acp_client_fs_read_text_file)
    )
    |> maybe_add_opt(
      :acp_client_fs_write_text_file,
      Keyword.get(opts, :acp_client_fs_write_text_file)
    )
    |> maybe_add_opt(
      :stream_options,
      build_trace_stream_options(
        Keyword.get(opts, :stream_options),
        run_id,
        session_key,
        agent_id
      )
    )
    |> maybe_add_opt(:extra_tools, normalize_extra_tools_opt(Keyword.get(opts, :extra_tools)))
  end

  def start_or_resume_session(nil, session_opts, state) do
    case CodingAgent.Session.start_link(session_opts) do
      {:ok, session} ->
        session_id = get_session_id(session)
        {:ok, session, session_id, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def start_or_resume_session(
        %ResumeToken{engine: @engine, value: session_id},
        session_opts,
        state
      ) do
    session_file = session_file_path(session_id, state.cwd)

    session_opts =
      if File.exists?(session_file) do
        Keyword.put(session_opts, :session_file, session_file)
      else
        Keyword.put(session_opts, :session_id, session_id)
      end

    case CodingAgent.Session.start_link(session_opts) do
      {:ok, session} ->
        {:ok, session, session_id, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def start_or_resume_session(%ResumeToken{engine: other}, _session_opts, _state) do
    {:error, {:wrong_engine, other, @engine}}
  end

  def get_session_id(session) do
    state = CodingAgent.Session.get_state(session)
    state.session_manager.header.id
  end

  def session_file_path(session_id, cwd) do
    dir = CodingAgent.Config.sessions_dir(cwd)
    Path.join(dir, "#{session_id}.jsonl")
  end

  def finalize_session(state) do
    session = state.session

    if is_pid(session) and Process.alive?(session) do
      case safe_save_session(session) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("LemonRunner finalize_session save failed: #{inspect(reason)}")
      end

      :ok = safe_stop_session(session)
    end

    state
  end

  @spec safe_save_session(pid()) :: :ok | {:error, term()}
  def safe_save_session(session) do
    try do
      _ = CodingAgent.Session.save(session)
      :ok
    rescue
      exception ->
        {:error, {:exception, exception}}
    catch
      :exit, reason ->
        {:error, {:exit, reason}}
    end
  end

  @spec safe_stop_session(pid()) :: :ok
  def safe_stop_session(session) do
    try do
      GenServer.stop(session, :normal)
      :ok
    rescue
      _ ->
        :ok
    catch
      :exit, _reason ->
        :ok
    end
  end

  @doc false
  def text_delta_from_message_update(msg, event, accumulated_text \\ "") do
    case extract_delta_text(event) do
      text when is_binary(text) and text != "" ->
        text

      _ ->
        visible_text_delta(msg, accumulated_text)
    end
  end

  def extract_delta_text({:text_delta, _idx, text, _partial}) when is_binary(text), do: text
  def extract_delta_text({:text_delta, _idx, text}) when is_binary(text), do: text
  def extract_delta_text(_), do: nil

  def new_reasoning_accumulator do
    %ReasoningAccumulator{threshold: @reasoning_update_threshold}
  end

  def reasoning_action({:thinking_start, idx, partial}, %ReasoningAccumulator{} = acc) do
    {block, acc} = new_reasoning_block(idx, partial, acc)
    {:emit, reasoning_action(block, :started, nil), acc}
  end

  def reasoning_action(
        {:thinking_delta, idx, text, _partial},
        %ReasoningAccumulator{} = acc
      )
      when is_binary(text) do
    {block, acc} = get_or_new_reasoning_block(idx, acc)
    block = %{block | text: block.text <> text}

    if byte_size(block.text) - block.emitted_bytes >= acc.threshold do
      block = %{block | emitted_bytes: byte_size(block.text)}
      acc = put_reasoning_block(acc, idx, block)
      {:emit, reasoning_action(block, :updated, nil), acc}
    else
      {:skip, put_reasoning_block(acc, idx, block)}
    end
  end

  def reasoning_action(
        {:thinking_end, idx, text, partial},
        %ReasoningAccumulator{} = acc
      ) do
    {block, acc} = get_or_new_reasoning_block(idx, acc)
    text = reasoning_end_text(text, partial, idx, block.text)
    block = %{block | text: text, emitted_bytes: byte_size(text)}
    acc = delete_reasoning_block(acc, idx)
    {:emit, reasoning_action(block, :completed, true), acc}
  end

  def reasoning_action({:thinking_end, idx, partial}, %ReasoningAccumulator{} = acc) do
    reasoning_action({:thinking_end, idx, nil, partial}, acc)
  end

  def reasoning_action(_event, %ReasoningAccumulator{} = acc), do: {:ignore, acc}

  def approval_action({:approval_request, approval_id, pending}) do
    tool = approval_pending_value(pending, :tool)
    action = approval_pending_value(pending, :action) || %{}
    title = approval_title(tool, action)

    %{
      id: approval_action_id(approval_id),
      kind: :approval,
      title: title,
      phase: :started,
      ok: nil,
      message: "awaiting approval",
      detail: approval_detail(approval_id, pending)
    }
  end

  def approval_action({:approval_resolved, approval_id, decision, pending}) do
    tool = approval_pending_value(pending, :tool)
    action = approval_pending_value(pending, :action) || %{}
    title = approval_title(tool, action)

    %{
      id: approval_action_id(approval_id),
      kind: :approval,
      title: title,
      phase: :completed,
      ok: approval_decision_ok?(decision),
      message: approval_decision_message(decision),
      detail:
        approval_detail(approval_id, pending)
        |> Map.put(:decision, decision)
    }
  end

  def approval_action(_event), do: nil

  def build_failure_usage(state, partial_state \\ nil) do
    [
      messages_from_partial_state(partial_state),
      messages_from_session(Map.get(state, :session))
    ]
    |> Enum.find_value(&build_usage/1)
  end

  def visible_text_delta(msg, accumulated_text) do
    text =
      case safe_get_visible_text(msg) do
        visible when is_binary(visible) -> visible
        _ -> ""
      end

    cond do
      text == "" ->
        nil

      accumulated_text == "" ->
        text

      String.starts_with?(text, accumulated_text) ->
        case binary_part(
               text,
               byte_size(accumulated_text),
               byte_size(text) - byte_size(accumulated_text)
             ) do
          "" -> nil
          suffix -> suffix
        end

      true ->
        nil
    end
  end

  def safe_get_visible_text(msg) do
    case Ai.get_text(msg) do
      text when is_binary(text) and text != "" ->
        text

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  def tool_kind(name) do
    case String.downcase(name || "") do
      "bash" -> :command
      "read" -> :tool
      "write" -> :file_change
      "edit" -> :file_change
      "glob" -> :tool
      "grep" -> :tool
      "websearch" -> :web_search
      "webfetch" -> :web_search
      "browser_" <> _ -> :browser
      "task" -> :subagent
      "agent" -> :subagent
      _ -> :tool
    end
  end

  def tool_title(name, args) do
    a = stringify_keys(args)

    case String.downcase(name || "") do
      "bash" ->
        cmd = a["command"] || ""
        cmd_preview = cmd |> String.split("\n") |> hd() |> String.slice(0, 60)
        "`#{cmd_preview}`"

      "read" ->
        path = a["path"] || a["file_path"] || ""
        "read: `#{path_label(path)}`"

      "write" ->
        path = a["path"] || a["file_path"] || ""
        "write: `#{path_label(path)}`"

      "edit" ->
        path = a["path"] || a["file_path"] || ""
        "edit: `#{path_label(path)}`"

      "glob" ->
        "glob: `#{a["pattern"] || ""}`"

      "grep" ->
        pattern = String.slice(a["pattern"] || "", 0, 30)
        path = a["path"]

        if is_binary(path) and path != "" do
          "grep: `#{pattern}` in #{path_label(path)}"
        else
          "grep: `#{pattern}`"
        end

      "websearch" ->
        "search: #{String.slice(a["query"] || "", 0, 50)}"

      "webfetch" ->
        "fetch: #{String.slice(a["url"] || "", 0, 50)}"

      "browser_navigate" ->
        "browser: #{String.slice(a["url"] || "", 0, 50)}"

      "browser_click" ->
        "browser click: #{String.slice(a["selector"] || "", 0, 50)}"

      "browser_type" ->
        "browser type: #{String.slice(a["selector"] || "", 0, 50)}"

      "browser_hover" ->
        "browser hover: #{String.slice(a["selector"] || "", 0, 50)}"

      "browser_select_option" ->
        "browser select option: #{String.slice(a["selector"] || "", 0, 50)}"

      "browser_upload_file" ->
        "browser upload file"

      "browser_download" ->
        "browser download"

      "browser_press" ->
        "browser key: #{String.slice(a["key"] || "", 0, 30)}"

      "browser_scroll" ->
        "browser scroll"

      "browser_back" ->
        "browser back"

      "browser_events" ->
        "browser events"

      "browser_get_cookies" ->
        "browser cookies"

      "browser_set_cookies" ->
        "browser set cookies"

      "browser_clear_state" ->
        "browser clear state"

      "browser_snapshot" ->
        "browser snapshot"

      "browser_get_content" ->
        "browser content"

      "browser_wait_for_selector" ->
        "browser wait"

      "browser_evaluate" ->
        "browser evaluate"

      "browser_screenshot" ->
        "browser screenshot"

      "task" ->
        engine_suffix =
          case a["engine"] do
            engine when is_binary(engine) and engine not in ["", "internal"] -> "(#{engine})"
            _ -> ""
          end

        model_suffix =
          case a["model"] do
            model when is_binary(model) and model != "" -> " [#{model}]"
            _ -> ""
          end

        "task#{engine_suffix}: #{String.slice(a["description"] || a["prompt"] || "", 0, 50)}#{model_suffix}"

      "agent" ->
        "agent: #{String.slice(a["prompt"] || a["description"] || "", 0, 50)}"

      "cron" ->
        "cron: #{String.slice(a["prompt"] || "", 0, 50)}"

      "skill" ->
        "skill: #{a["skill"] || a["name"] || ""}"

      n ->
        n
    end
  end

  def path_label(path) when is_binary(path) do
    parts = Path.split(path)

    case length(parts) do
      n when n > 2 -> Path.join(Enum.take(parts, -2))
      _ -> path
    end
  end

  def path_label(other), do: inspect(other)

  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  def stringify_keys(_), do: %{}

  defp approval_pending_value(pending, key) when is_map(pending) and is_atom(key) do
    Map.get(pending, key) || Map.get(pending, Atom.to_string(key))
  end

  defp approval_pending_value(_pending, _key), do: nil

  defp approval_action_id(approval_id), do: "approval:" <> to_string(approval_id)

  defp approval_title(tool, action) do
    tool
    |> to_string()
    |> tool_title(action)
  end

  defp approval_detail(approval_id, pending) do
    %{
      approval_id: to_string(approval_id),
      tool: approval_pending_value(pending, :tool),
      action: approval_pending_value(pending, :action),
      session_id: approval_pending_value(pending, :session_id),
      session_key: approval_pending_value(pending, :session_key),
      run_id: approval_pending_value(pending, :run_id)
    }
    |> maybe_put_meta(:rationale, approval_pending_value(pending, :rationale))
  end

  defp approval_decision_ok?(decision), do: decision not in [:deny, :timeout, "deny", "timeout"]

  defp approval_decision_message(:approve_once), do: "approved once"
  defp approval_decision_message(:approve_session), do: "approved for session"
  defp approval_decision_message(:approve_agent), do: "approved for agent"
  defp approval_decision_message(:approve_global), do: "approved globally"
  defp approval_decision_message(:deny), do: "denied"
  defp approval_decision_message(:timeout), do: "timed out"
  defp approval_decision_message("approve_once"), do: "approved once"
  defp approval_decision_message("approve_session"), do: "approved for session"
  defp approval_decision_message("approve_agent"), do: "approved for agent"
  defp approval_decision_message("approve_global"), do: "approved globally"
  defp approval_decision_message("deny"), do: "denied"
  defp approval_decision_message("timeout"), do: "timed out"
  defp approval_decision_message(other), do: to_string(other)

  def truncate_result(result) when is_binary(result) do
    cond do
      byte_size(result) <= 500 ->
        result

      String.length(result) > 500 ->
        String.slice(result, 0, 500) <> "..."

      true ->
        result
    end
  end

  def truncate_result(%AgentCore.Types.AgentToolResult{} = result) do
    result
    |> AgentCore.get_text()
    |> truncate_result()
  end

  def truncate_result(%Ai.Types.TextContent{text: text}) when is_binary(text),
    do: truncate_result(text)

  def truncate_result(content) when is_list(content) do
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

  def truncate_result(result), do: inspect(result, limit: 500)

  def maybe_put_result_meta(detail, %AgentCore.Types.AgentToolResult{} = result, name)
      when is_map(detail) do
    case extract_tool_result_meta(result.details, name) do
      nil -> detail
      meta -> Map.put(detail, :result_meta, meta)
    end
  end

  def maybe_put_result_meta(detail, _, _name), do: detail

  def action_ok?(_name, _result, true), do: false

  def action_ok?(name, %AgentCore.Types.AgentToolResult{details: details}, false) do
    not command_exit_failed?(name, details)
  end

  def action_ok?(_name, _result, false), do: true

  def command_exit_failed?(name, details) when is_map(details) do
    String.downcase(to_string(name || "")) == "bash" and
      case Map.get(details, :exit_code) || Map.get(details, "exit_code") do
        exit_code when is_integer(exit_code) -> exit_code != 0
        _ -> false
      end
  end

  def command_exit_failed?(_name, _details), do: false

  def extract_tool_result_meta(details, name) when is_map(details) do
    auto_send_files = Map.get(details, :auto_send_files) || Map.get(details, "auto_send_files")
    task_meta = extract_task_tool_result_meta(details)
    command_meta = extract_command_tool_result_meta(details, name)
    error_meta = extract_error_tool_result_meta(details)

    meta =
      case normalize_auto_send_files(auto_send_files) do
        [] ->
          (task_meta || %{})
          |> Map.merge(command_meta || %{})
          |> Map.merge(error_meta || %{})

        files ->
          (task_meta || %{})
          |> Map.merge(command_meta || %{})
          |> Map.merge(error_meta || %{})
          |> Map.put(:auto_send_files, files)
      end

    if map_size(meta) == 0, do: nil, else: meta
  end

  def extract_tool_result_meta(_, _name), do: nil

  def extract_command_tool_result_meta(details, name) when is_map(details) do
    exit_code = Map.get(details, :exit_code) || Map.get(details, "exit_code")

    if String.downcase(to_string(name || "")) == "bash" and is_integer(exit_code) and
         exit_code != 0 do
      %{}
      |> maybe_put_meta(:error_type, :command_exit)
      |> maybe_put_meta(:tool_name, to_string(name))
      |> maybe_put_meta(:exit_code, exit_code)
      |> maybe_put_meta(:message, "Command exited with code #{exit_code}")
    else
      nil
    end
  end

  def extract_command_tool_result_meta(_details, _name), do: nil

  def extract_error_tool_result_meta(details) when is_map(details) do
    error_type = Map.get(details, :error_type) || Map.get(details, "error_type")

    if is_nil(error_type) do
      nil
    else
      %{}
      |> maybe_put_meta(:error_type, error_type)
      |> maybe_put_meta(:reason, Map.get(details, :reason) || Map.get(details, "reason"))
      |> maybe_put_meta(:errors, Map.get(details, :errors) || Map.get(details, "errors"))
      |> maybe_put_meta(:tool_name, Map.get(details, :tool_name) || Map.get(details, "tool_name"))
      |> maybe_put_meta(
        :timeout_ms,
        Map.get(details, :timeout_ms) || Map.get(details, "timeout_ms")
      )
      |> maybe_put_meta(:exit_code, Map.get(details, :exit_code) || Map.get(details, "exit_code"))
      |> maybe_put_meta(:exception, Map.get(details, :exception) || Map.get(details, "exception"))
      |> maybe_put_meta(:message, Map.get(details, :message) || Map.get(details, "message"))
      |> maybe_put_meta(:status, Map.get(details, :status) || Map.get(details, "status"))
    end
  end

  def extract_error_tool_result_meta(_), do: nil

  def extract_task_tool_result_meta(details) when is_map(details) do
    meta =
      %{}
      |> maybe_put_meta(:task_id, Map.get(details, :task_id) || Map.get(details, "task_id"))
      |> maybe_put_meta(:task_ids, Map.get(details, :task_ids) || Map.get(details, "task_ids"))
      |> maybe_put_meta(:status, Map.get(details, :status) || Map.get(details, "status"))
      |> maybe_put_meta(:engine, Map.get(details, :engine) || Map.get(details, "engine"))
      |> maybe_put_meta(:run_id, Map.get(details, :run_id) || Map.get(details, "run_id"))
      |> maybe_put_meta(:current_action, latest_task_current_action(details))
      |> maybe_put_meta(:action_detail, latest_task_action_detail(details))

    if map_size(meta) == 0, do: nil, else: meta
  end

  def extract_task_tool_result_meta(_), do: nil

  def normalize_auto_send_files(files) when is_list(files) do
    files
    |> Enum.map(&normalize_auto_send_file/1)
    |> Enum.reject(&is_nil/1)
  end

  def normalize_auto_send_files(_), do: []

  def extract_answer(messages, accumulated_text) do
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

  def extract_text_content(content) do
    content
    |> Enum.filter(fn
      %{type: :text} -> true
      _ -> false
    end)
    |> Enum.map(fn %{text: text} -> text end)
    |> Enum.join("\n")
  end

  def build_usage(messages) do
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

  def merge_usage(acc, usage) do
    Map.merge(acc, usage, fn _k, v1, v2 ->
      if is_number(v1) and is_number(v2), do: v1 + v2, else: v2
    end)
  end

  defp new_reasoning_block(idx, partial, %ReasoningAccumulator{} = acc) do
    seq = acc.seq + 1

    block = %{
      id: "lemon.reasoning.#{idx}.#{seq}",
      text: thinking_text_from_partial(partial, idx),
      emitted_bytes: 0
    }

    {block, put_reasoning_block(%{acc | seq: seq}, idx, block)}
  end

  defp get_or_new_reasoning_block(idx, %ReasoningAccumulator{} = acc) do
    case Map.get(acc.blocks, idx) do
      nil -> new_reasoning_block(idx, nil, acc)
      block -> {block, acc}
    end
  end

  defp put_reasoning_block(%ReasoningAccumulator{} = acc, idx, block) do
    %{acc | blocks: Map.put(acc.blocks, idx, block)}
  end

  defp delete_reasoning_block(%ReasoningAccumulator{} = acc, idx) do
    %{acc | blocks: Map.delete(acc.blocks, idx)}
  end

  defp reasoning_action(block, phase, ok) do
    text = block.text || ""

    %{
      id: block.id,
      kind: :reasoning,
      title: reasoning_title(text),
      phase: phase,
      ok: ok,
      detail: %{
        reasoning: %{text: reasoning_payload_text(text, phase), source: "lemon_reasoning"}
      }
    }
  end

  defp reasoning_payload_text(text, :updated) when byte_size(text) <= 500, do: text
  defp reasoning_payload_text(text, :updated), do: "..." <> String.slice(text, -500, 500)
  defp reasoning_payload_text(text, _phase), do: truncate_result(text)

  defp reasoning_title(text) when is_binary(text) do
    case String.slice(text, 0, 100) do
      "" -> "reasoning"
      title -> title
    end
  end

  defp reasoning_title(_), do: "reasoning"

  defp reasoning_end_text(text, _partial, _idx, _fallback) when is_binary(text), do: text

  defp reasoning_end_text(_text, partial, idx, fallback) do
    case thinking_text_from_partial(partial, idx) do
      "" -> fallback || ""
      text -> text
    end
  end

  defp thinking_text_from_partial(%{content: content}, idx) when is_list(content) do
    case Enum.at(content, idx) do
      %{thinking: thinking} when is_binary(thinking) -> thinking
      _ -> ""
    end
  end

  defp thinking_text_from_partial(_partial, _idx), do: ""

  defp messages_from_partial_state(%{agent_state: agent_state}) do
    messages_from_partial_state(agent_state)
  end

  defp messages_from_partial_state(%{messages: messages} = state) when is_list(messages) do
    case Map.get(state, :stream_message) do
      nil -> messages
      stream_message -> messages ++ [stream_message]
    end
  end

  defp messages_from_partial_state(messages) when is_list(messages), do: messages
  defp messages_from_partial_state(_), do: []

  defp messages_from_session(session) when is_pid(session) do
    if Process.alive?(session) do
      CodingAgent.Session.get_messages(session)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp messages_from_session(_), do: []

  def format_error({:assistant_error, msg}, _state) when is_binary(msg), do: msg

  def format_error({:assistant_error, reason}, state),
    do: "assistant error: #{format_error(reason, state)}"

  def format_error(:circuit_open, state), do: format_circuit_open_error(state)

  def format_error(reason, _state) when is_binary(reason), do: reason

  def format_error(reason, _state)
      when reason in [
             :rate_limited,
             :max_concurrency,
             :timeout,
             :closed,
             :econnrefused,
             :econnreset,
             :nxdomain
           ] do
    Ai.Error.format_error(reason)
  end

  def format_error({:http_error, _status, _body} = reason, _state),
    do: Ai.Error.format_error(reason)

  def format_error({:error, reason}, state), do: format_error(reason, state)
  def format_error(reason, _state) when is_atom(reason), do: Atom.to_string(reason)
  def format_error(reason, _state), do: inspect(reason)

  def cancel_error_message(:user_requested), do: "Cancelled by user"
  def cancel_error_message(reason), do: "Cancelled: #{format_error(reason, %{})}"

  def normalize_extra_tools_opt(tools) when is_list(tools) and tools != [], do: tools
  def normalize_extra_tools_opt(_), do: nil

  def maybe_add_opt(opts, _key, nil), do: opts
  def maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp latest_task_current_action(details) when is_map(details) do
    direct = Map.get(details, :current_action) || Map.get(details, "current_action")

    cond do
      is_map(direct) ->
        direct

      true ->
        details
        |> task_result_events()
        |> Enum.reverse()
        |> Enum.find_value(fn event ->
          event_details =
            cond do
              is_struct(event) -> Map.get(Map.from_struct(event), :details)
              is_map(event) -> Map.get(event, :details) || Map.get(event, "details")
              true -> nil
            end

          if is_map(event_details) do
            Map.get(event_details, :current_action) || Map.get(event_details, "current_action")
          end
        end)
    end
  end

  defp latest_task_current_action(_), do: nil

  defp latest_task_action_detail(details) when is_map(details) do
    details
    |> task_result_events()
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      event_details =
        cond do
          is_struct(event) -> Map.get(Map.from_struct(event), :details)
          is_map(event) -> Map.get(event, :details) || Map.get(event, "details")
          true -> nil
        end

      if is_map(event_details) do
        Map.get(event_details, :action_detail) || Map.get(event_details, "action_detail")
      end
    end)
  end

  defp latest_task_action_detail(_), do: nil

  defp task_result_events(details) when is_map(details) do
    events = Map.get(details, :events) || Map.get(details, "events")
    if is_list(events), do: events, else: []
  end

  defp task_result_events(_), do: []

  defp maybe_put_meta(meta, _key, nil), do: meta

  defp maybe_put_meta(meta, key, value) when is_map(meta) do
    Map.put(meta, key, value)
  end

  defp normalize_auto_send_file(file) when is_map(file) do
    path = Map.get(file, :path) || Map.get(file, "path")

    if is_binary(path) and path != "" do
      %{
        path: path,
        filename: Map.get(file, :filename) || Map.get(file, "filename"),
        caption: Map.get(file, :caption) || Map.get(file, "caption")
      }
      |> maybe_put_auto_send_source(Map.get(file, :source) || Map.get(file, "source"))
    else
      nil
    end
  end

  defp normalize_auto_send_file(_), do: nil

  defp maybe_put_auto_send_source(file, source) when source in [:explicit, "explicit"] do
    Map.put(file, :source, :explicit)
  end

  defp maybe_put_auto_send_source(file, source) when source in [:generated, "generated"] do
    Map.put(file, :source, :generated)
  end

  defp maybe_put_auto_send_source(file, _source), do: file

  defp format_circuit_open_error(state) do
    base = Ai.Error.format_error(:circuit_open)

    with provider when is_atom(provider) <- current_provider(state),
         {:ok, breaker_state} <- Ai.CircuitBreaker.get_state(provider) do
      detail =
        breaker_state
        |> Map.get(:last_failure_reason)
        |> format_circuit_failure_reason()

      retry_after_ms = Ai.CircuitBreaker.time_until_recovery(provider)
      parts = ["Provider: #{provider}"]

      parts =
        if is_binary(detail) and detail != "",
          do: parts ++ ["Last failure: #{detail}"],
          else: parts

      parts =
        if retry_after_ms > 0,
          do: parts ++ ["Retry in ~#{div(retry_after_ms + 999, 1000)}s"],
          else: parts

      if Enum.empty?(parts) do
        base
      else
        base <> " " <> Enum.join(parts, ". ") <> "."
      end
    else
      _ -> base
    end
  end

  defp format_circuit_failure_reason(nil), do: nil

  defp format_circuit_failure_reason({:stream_tracking_start_failed, reason}) do
    "stream tracking start failed: #{format_circuit_failure_reason(reason) || inspect(reason)}"
  end

  defp format_circuit_failure_reason({:stream_tracking_exception, message})
       when is_binary(message),
       do: message

  defp format_circuit_failure_reason({:stream_tracking_exit, reason}),
    do: "stream tracking exited: #{inspect(reason)}"

  defp format_circuit_failure_reason({:unexpected_stream_result, result}),
    do: "unexpected stream result: #{inspect(result)}"

  defp format_circuit_failure_reason({:exception, message}) when is_binary(message), do: message

  defp format_circuit_failure_reason(reason) when is_binary(reason), do: reason

  defp format_circuit_failure_reason(reason)
       when reason in [:timeout, :closed, :econnrefused, :econnreset, :nxdomain] do
    Ai.Error.format_error(reason)
  end

  defp format_circuit_failure_reason({:http_error, _status, _body} = reason),
    do: Ai.Error.format_error(reason)

  defp format_circuit_failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_circuit_failure_reason(reason), do: inspect(reason)

  defp current_provider(%{session: session}) when is_pid(session) do
    case Process.alive?(session) do
      true ->
        try do
          case CodingAgent.Session.get_state(session) do
            %{model: %{provider: provider}} when is_atom(provider) -> provider
            _ -> nil
          end
        catch
          :exit, _reason -> nil
        end

      false ->
        nil
    end
  end

  defp current_provider(_state), do: nil

  defp build_trace_stream_options(base, run_id, session_key, agent_id) do
    base =
      case base do
        %StreamOptions{} = opts -> opts
        _ -> %StreamOptions{}
      end

    trace_headers =
      %{}
      |> maybe_put_trace_header("x-lemon-run-id", run_id)
      |> maybe_put_trace_header("x-lemon-session-key", session_key)
      |> maybe_put_trace_header("x-lemon-agent-id", agent_id)

    merged_headers = Map.merge(base.headers || %{}, trace_headers)

    if map_size(merged_headers) == 0 do
      nil
    else
      %StreamOptions{base | headers: merged_headers}
    end
  end

  defp maybe_put_trace_header(headers, _key, nil), do: headers
  defp maybe_put_trace_header(headers, _key, ""), do: headers

  defp maybe_put_trace_header(headers, key, value) when is_binary(value) do
    Map.put(headers, key, value)
  end

  defp maybe_put_trace_header(headers, _key, _value), do: headers
end
