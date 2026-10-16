defmodule CodingAgent.Session.Presentation do
  @moduledoc false

  alias CodingAgent.SessionManager
  alias LemonAi.Types.StreamOptions
  alias LemonCore.ResumeToken

  require Logger

  @engine "lemon"
  @reasoning_update_threshold 700

  # Channel renderers (Telegram, Discord) show `detail.result`, a 500-char
  # preview. Operator clients (TUI, web over the control plane) additionally get
  # these bounded full-fidelity copies; see `put_operator_result/2`.
  @operator_result_max_bytes 32_768
  @operator_reasoning_max_bytes 16_384
  @operator_diff_max_bytes 32_768
  @operator_detail_string_max_bytes 2_048
  @operator_detail_list_max 200
  @operator_detail_max_depth 4
  # Internal bookkeeping or payloads another field already carries.
  @operator_detail_dropped_keys ["acp_client", "events", "current_action", "action_detail"]

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
          invocation_context_key: Keyword.get(opts, :invocation_context_key),
          channel_identity: Keyword.get(opts, :channel_identity),
          memory_context_key: Keyword.get(opts, :memory_context_key),
          memory_context_verified: Keyword.get(opts, :memory_context_verified) == true,
          shared_memory_grant: Keyword.get(opts, :shared_memory_grant) == true,
          invocation_mcp_servers: Keyword.get(opts, :invocation_mcp_servers),
          timeout_ms: approval_timeout_ms
        }
        |> Map.merge(
          Map.new(
            Keyword.take(opts, [
              :native_lineage_handle,
              :native_lineage_run_id,
              :native_source_profile_id,
              :native_source_session_key,
              :native_followup_submit,
              :native_source_floor_fun,
              :invocation_proof,
              :invocation_proof_verified,
              :native_managed_context
            ])
          )
        )
      else
        nil
      end

    [cwd: cwd, register: true]
    |> maybe_add_opt(:model, Keyword.get(opts, :model))
    |> maybe_add_opt(:model_explicit, boolean_or_nil(Keyword.get(opts, :model_explicit)))
    |> maybe_add_opt(:thinking_level, Keyword.get(opts, :thinking_level))
    |> maybe_add_opt(:system_prompt, Keyword.get(opts, :system_prompt))
    |> maybe_add_opt(:profile_instructions, Keyword.get(opts, :profile_instructions))
    |> maybe_add_opt(:stream_fn, Keyword.get(opts, :stream_fn))
    |> maybe_add_opt(:tool_policy, tool_policy)
    |> maybe_add_opt(:execution_context, Keyword.get(opts, :execution_context))
    |> maybe_add_opt(:approval_context, approval_context)
    |> maybe_add_opt(:invocation_context_key, Keyword.get(opts, :invocation_context_key))
    |> maybe_add_opt(:channel_identity, Keyword.get(opts, :channel_identity))
    |> maybe_add_opt(:memory_context_key, Keyword.get(opts, :memory_context_key))
    |> maybe_add_opt(
      :memory_context_verified,
      Keyword.get(opts, :memory_context_verified) == true
    )
    |> maybe_add_opt(:shared_memory_grant, Keyword.get(opts, :shared_memory_grant) == true)
    |> maybe_add_opt(:invocation_mcp_servers, Keyword.get(opts, :invocation_mcp_servers))
    |> Keyword.merge(
      Keyword.take(opts, [
        :native_lineage_handle,
        :native_lineage_run_id,
        :native_source_profile_id,
        :native_source_session_key,
        :native_followup_submit,
        :native_source_floor_fun,
        :invocation_proof,
        :invocation_proof_verified,
        :native_managed_context
      ])
    )
    |> maybe_add_opt(:run_id, run_id)
    |> maybe_add_opt(:session_key, session_key)
    |> maybe_add_opt(:agent_id, agent_id)
    |> maybe_add_opt(:acp_session_id, Keyword.get(opts, :acp_session_id))
    |> maybe_add_opt(:acp_mcp_session_id, Keyword.get(opts, :acp_mcp_session_id))
    |> maybe_add_opt(:mcp_session_id, Keyword.get(opts, :mcp_session_id))
    |> maybe_add_opt(
      :acp_client_elicitation_form,
      Keyword.get(opts, :acp_client_elicitation_form)
    )
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
    |> maybe_add_opt(:resume_source, Keyword.get(opts, :resume_source))
    |> maybe_add_opt(:workspace_dir, Keyword.get(opts, :workspace_dir))
    |> maybe_add_opt(:extra_tools, normalize_extra_tools_opt(Keyword.get(opts, :extra_tools)))
  end

  @doc """
  Validates an explicit resume before starting a linked session runner.

  Auto-resume (`resume_source: :auto`) may fall back to a fresh session only for
  an unbound native token. A token mapped to an existing logical session must
  remain loadable in the supplied cwd; never replace that session's history.
  """
  @spec validate_resume_for_start(ResumeToken.t() | nil, keyword(), binary()) ::
          :ok | {:error, term()}
  def validate_resume_for_start(nil, _session_opts, _cwd), do: :ok

  def validate_resume_for_start(
        %ResumeToken{engine: @engine, value: session_id},
        session_opts,
        cwd
      ) do
    case resume_session_file(session_id, cwd) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        if fresh_resume_fallback?(session_id, session_opts) do
          :ok
        else
          {:error, explicit_resume_error(session_id, reason)}
        end
    end
  end

  def validate_resume_for_start(%ResumeToken{engine: other}, _session_opts, _cwd) do
    {:error, {:wrong_engine, other, @engine}}
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
    case resume_session_file(session_id, state.cwd) do
      {:ok, session_file} ->
        start_existing_session(session_id, session_file, session_opts, state)

      {:error, reason} ->
        if fresh_resume_fallback?(session_id, session_opts) do
          Logger.warning(
            "LemonRunner auto-resume unavailable for session #{inspect(session_id)}: " <>
              "#{inspect(reason)}; starting a fresh session"
          )

          start_fresh_session(
            session_opts,
            state,
            %{resume: %{source: :auto, session_id: session_id, fallback: :fresh, reason: reason}}
          )
        else
          {:error, explicit_resume_error(session_id, reason)}
        end
    end
  end

  def start_or_resume_session(%ResumeToken{engine: other}, _session_opts, _state) do
    {:error, {:wrong_engine, other, @engine}}
  end

  defp resume_session_file(session_id, cwd) when is_binary(session_id) and session_id != "" do
    session_file = session_file_path(session_id, cwd)

    if File.regular?(session_file) do
      case SessionManager.load_from_file(session_file) do
        {:ok, _session} -> {:ok, session_file}
        {:error, reason} -> {:error, {:corrupt, reason}}
      end
    else
      {:error, :missing}
    end
  end

  defp resume_session_file(_session_id, _cwd), do: {:error, :invalid}

  defp start_existing_session(session_id, session_file, session_opts, state) do
    session_opts =
      session_opts |> Keyword.delete(:session_id) |> Keyword.put(:session_file, session_file)

    case CodingAgent.Session.start_link(session_opts) do
      {:ok, session} -> {:ok, session, session_id, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_fresh_session(session_opts, state, diagnostic) do
    session_opts = Keyword.drop(session_opts, [:session_file, :session_id])

    case CodingAgent.Session.start_link(session_opts) do
      {:ok, session} ->
        {:ok, session, get_session_id(session), Map.put(state, :resume_diagnostic, diagnostic)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fresh_resume_fallback?(session_id, session_opts) do
    resume_source(session_opts) == :auto and
      not mapped_resume?(Keyword.get(session_opts, :session_key), session_id)
  end

  defp mapped_resume?(key, session_id) when is_binary(key) do
    case LemonCore.ChatStateStore.get(key) do
      %{last_engine: @engine, last_resume_token: ^session_id} -> true
      _ -> false
    end
  end

  defp mapped_resume?(_key, _session_id), do: false

  defp resume_source(session_opts) do
    case Keyword.get(session_opts, :resume_source) do
      :auto -> :auto
      :explicit -> :explicit
      "auto" -> :auto
      "explicit" -> :explicit
      _ -> :explicit
    end
  end

  defp explicit_resume_error(session_id, :missing), do: {:resume_session_missing, session_id}
  defp explicit_resume_error(session_id, :invalid), do: {:resume_session_invalid, session_id}

  defp explicit_resume_error(session_id, {:corrupt, reason}),
    do: {:resume_session_corrupt, session_id, reason}

  def get_session_id(session) do
    state = CodingAgent.Session.get_state(session)
    state.session_manager.header.id
  end

  def session_file_path(session_id, cwd) do
    CodingAgent.SessionManager.session_file_path(cwd, session_id)
  end

  # Preserve resources only after both persistence and the complete handoff
  # succeed. Otherwise normal Session termination disposes them.
  def finalize_session(state, preserve_tool_resources \\ false) do
    session = state.session

    if is_pid(session) and Process.alive?(session) do
      case safe_save_session(session) do
        :ok ->
          if preserve_tool_resources, do: handoff_tool_resources(session, state.session_id)

        {:error, reason} ->
          Logger.warning("LemonRunner finalize_session save failed: #{inspect(reason)}")
      end

      :ok = safe_stop_session(session)
    end

    state
  end

  defp handoff_tool_resources(session, session_id) do
    case CodingAgent.Session.handoff_tool_resources(session) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("LemonRunner finalize_session handoff failed: #{inspect(reason)}")
    end
  catch
    :exit, reason ->
      # An uncertain handoff may have detached resources from a lost owner.
      Logger.warning("LemonRunner finalize_session handoff failed: #{inspect({:exit, reason})}")
      CodingAgent.ToolResources.stop(session_id)
  end

  @spec safe_save_session(pid()) :: :ok | {:error, term()}
  def safe_save_session(session) do
    CodingAgent.Session.save(session)
  rescue
    exception ->
      {:error, {:exception, exception}}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  @spec safe_stop_session(pid()) :: :ok
  def safe_stop_session(session) do
    GenServer.stop(session, :normal)
    :ok
  rescue
    _ ->
      :ok
  catch
    :exit, _reason ->
      :ok
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
    delta = block.text
    block = %{block | emitted_bytes: byte_size(block.text)}
    acc = put_reasoning_block(acc, idx, block)
    {:emit, reasoning_action(block, :started, nil, delta), acc}
  end

  def reasoning_action(
        {:thinking_delta, idx, text, _partial},
        %ReasoningAccumulator{} = acc
      )
      when is_binary(text) do
    {block, acc} = get_or_new_reasoning_block(idx, acc)
    block = %{block | text: block.text <> text}

    if byte_size(block.text) - block.emitted_bytes >= acc.threshold do
      delta = un_emitted_reasoning(block)
      block = %{block | emitted_bytes: byte_size(block.text)}
      acc = put_reasoning_block(acc, idx, block)
      {:emit, reasoning_action(block, :updated, nil, delta), acc}
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
    block = %{block | text: text}
    delta = un_emitted_reasoning(block)
    block = %{block | emitted_bytes: byte_size(text)}
    acc = delete_reasoning_block(acc, idx)
    {:emit, reasoning_action(block, :completed, true, delta), acc}
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
    text = safe_get_visible_text(msg)

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
    case LemonAi.get_text(msg) do
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
      "bash_output" -> :command
      "kill_process" -> :command
      "process_input" -> :command
      "eval" -> :command
      "debug" -> :command
      "read" -> :tool
      "write" -> :file_change
      "edit" -> :file_change
      "patch" -> :file_change
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

        if a["run_in_background"] == true,
          do: "`#{cmd_preview}` (background)",
          else: "`#{cmd_preview}`"

      "bash_output" ->
        "bash output: #{a["process_id"] || ""}"

      "kill_process" ->
        "kill: #{a["process_id"] || ""}"

      "eval" ->
        label = a["title"] || (a["code"] || "") |> String.split("\n") |> hd()
        "eval #{a["language"] || ""}: `#{String.slice(label, 0, 60)}`"

      "debug" ->
        target = a["program"] || a["expression"] || a["function"] || a["command"]
        target = target || if(a["file"], do: "#{path_label(a["file"])}:#{a["line"]}")
        String.trim("debug: #{a["action"] || ""} #{String.slice(target || "", 0, 60)}")

      "read" ->
        path = a["path"] || a["file_path"] || ""
        "read: `#{path_label(path)}`"

      "write" ->
        path = a["path"] || a["file_path"] || ""
        "write: `#{path_label(path)}`"

      "edit" ->
        path = a["path"] || a["file_path"] || ""
        "edit: `#{path_label(path)}`"

      "find" ->
        "find: `#{String.slice(a["pattern"] || "", 0, 40)}`"

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

      # Native app control (lemon_computer_use). `title` is the runtime's own
      # short user-facing description of the call.
      "cua_js" ->
        label = a["title"] || (a["code"] || "") |> String.split("\n") |> hd()
        "computer use: #{String.slice(label, 0, 60)}"

      "cua_js_reset" ->
        "computer use reset"

      # Its per-app and per-site approval requests.
      "computer_use" ->
        cond do
          is_binary(a["app"]) -> "computer use app: #{String.slice(a["app"], 0, 80)}"
          is_binary(a["origin"]) -> "computer use site: #{String.slice(a["origin"], 0, 80)}"
          true -> "computer use"
        end

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

  defp approval_decision_ok?(decision),
    do: decision not in [:deny, :timeout, :expired, "deny", "timeout", "expired"]

  defp approval_decision_message(:approve_once), do: "approved once"
  defp approval_decision_message(:approve_session), do: "approved for session"
  defp approval_decision_message(:approve_agent), do: "approved for agent"
  defp approval_decision_message(:approve_global), do: "approved globally"
  defp approval_decision_message(:deny), do: "denied"
  defp approval_decision_message(:timeout), do: "timed out"
  defp approval_decision_message(:expired), do: "expired because its run ended"
  defp approval_decision_message("approve_once"), do: "approved once"
  defp approval_decision_message("approve_session"), do: "approved for session"
  defp approval_decision_message("approve_agent"), do: "approved for agent"
  defp approval_decision_message("approve_global"), do: "approved globally"
  defp approval_decision_message("deny"), do: "denied"
  defp approval_decision_message("timeout"), do: "timed out"
  defp approval_decision_message("expired"), do: "expired because its run ended"
  defp approval_decision_message(other), do: to_string(other)

  def truncate_result(result) when is_binary(result) do
    cond do
      byte_size(result) <= 500 ->
        result

      String.length(result) > 500 ->
        LemonAi.Text.truncate_chars(result, 500)

      true ->
        result
    end
  end

  def truncate_result(%LemonAgent.Types.AgentToolResult{} = result) do
    result
    |> result_text()
    |> truncate_result()
  end

  def truncate_result(%LemonAi.Types.TextContent{text: text}) when is_binary(text),
    do: truncate_result(text)

  def truncate_result(content) when is_list(content) do
    content
    |> result_text()
    |> truncate_result()
  end

  def truncate_result(result), do: inspect(result, limit: 500)

  @doc """
  Adds the operator-client view of a tool result to an action `detail`.

  `detail.result` stays the 500-char preview channel renderers show. This adds
  `result_full` (the result text bounded to 32 KB, only when it is longer than
  the preview) and `details` (the tool's structured details — diff,
  first_changed_line, path, exit_code, ... — made JSON-safe and bounded).
  `LemonControlPlane.EventBridge` promotes both for operator clients.
  """
  @spec put_operator_result(map(), term()) :: map()
  def put_operator_result(detail, result) when is_map(detail) do
    detail
    |> maybe_put_result_full(result)
    |> maybe_put_operator_details(result)
  end

  defp maybe_put_result_full(detail, result) do
    full =
      result
      |> result_text()
      |> LemonAi.Text.truncate_middle_utf8(@operator_result_max_bytes,
        marker: fn removed -> "\n\n… [#{removed} bytes omitted] …\n\n" end
      )

    if full == Map.get(detail, :result), do: detail, else: Map.put(detail, :result_full, full)
  end

  defp maybe_put_operator_details(detail, %LemonAgent.Types.AgentToolResult{details: details})
       when is_map(details) do
    case operator_details(details) do
      empty when map_size(empty) == 0 -> detail
      sanitized -> Map.put(detail, :details, sanitized)
    end
  end

  defp maybe_put_operator_details(detail, _result), do: detail

  @doc """
  Projects a tool's structured `details` into a JSON-safe, bounded map.

  Structs, pids, functions and tuples are dropped, as are internal bookkeeping
  keys. `diff` keeps up to 32 KB; complete ACP file snapshots keep up to 16 KB
  per side and are omitted as a pair if either side is oversized. Other strings
  keep 2 KB. Lists keep their first 200 items and nesting stops at depth 4.
  """
  @spec operator_details(map()) :: map()
  def operator_details(details) when is_map(details) and not is_struct(details) do
    sanitize_detail_map(details, 1)
  end

  def operator_details(_details), do: %{}

  defp sanitize_detail_map(map, depth) do
    map = bounded_file_snapshots(map)

    Enum.reduce(map, %{}, fn {key, value}, acc ->
      with name when is_binary(name) <- detail_key_name(key),
           false <- name in @operator_detail_dropped_keys,
           {:ok, sanitized} <- sanitize_detail_value(name, value, depth) do
        Map.put(acc, key, sanitized)
      else
        _ -> acc
      end
    end)
  end

  defp bounded_file_snapshots(map) do
    snapshots = [:oldText, :newText, "oldText", "newText"]

    if Enum.any?(snapshots, fn key ->
         case Map.get(map, key) do
           nil -> false
           text when is_binary(text) -> byte_size(text) > 16_384 or not String.valid?(text)
           _ -> true
         end
       end) do
      Map.drop(map, snapshots)
    else
      map
    end
  end

  defp detail_key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp detail_key_name(key) when is_binary(key), do: key
  defp detail_key_name(_key), do: nil

  defp sanitize_detail_value(_name, value, _depth)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: {:ok, value}

  defp sanitize_detail_value(_name, value, _depth) when is_atom(value), do: {:ok, value}

  defp sanitize_detail_value(name, value, _depth)
       when name in ["oldText", "newText"] and is_binary(value),
       do: {:ok, value}

  defp sanitize_detail_value(name, value, _depth) when is_binary(value) do
    max_bytes =
      if name == "diff", do: @operator_diff_max_bytes, else: @operator_detail_string_max_bytes

    if String.valid?(value) do
      {:ok, LemonAi.Text.truncate_bytes_utf8(value, max_bytes, marker: "\n...")}
    else
      :drop
    end
  end

  defp sanitize_detail_value(_name, _value, depth) when depth >= @operator_detail_max_depth,
    do: :drop

  defp sanitize_detail_value(_name, value, depth) when is_map(value) and not is_struct(value) do
    {:ok, sanitize_detail_map(value, depth + 1)}
  end

  defp sanitize_detail_value(name, value, depth) when is_list(value) do
    items =
      value
      |> Enum.take(@operator_detail_list_max)
      |> Enum.flat_map(fn item ->
        case sanitize_detail_value(name, item, depth + 1) do
          {:ok, sanitized} -> [sanitized]
          :drop -> []
        end
      end)

    {:ok, items}
  end

  defp sanitize_detail_value(_name, _value, _depth), do: :drop

  @doc """
  The full text of a tool result: every text block joined, or an inspected
  fallback for results that carry no text.
  """
  @spec result_text(term()) :: String.t()
  def result_text(result) when is_binary(result), do: result

  def result_text(%LemonAgent.Types.AgentToolResult{} = result) do
    case LemonAgent.get_text(result) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  def result_text(%LemonAi.Types.TextContent{text: text}) when is_binary(text), do: text

  def result_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %LemonAi.Types.TextContent{text: text} when is_binary(text) -> text
      %{type: :text, text: text} when is_binary(text) -> text
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      item when is_binary(item) -> item
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def result_text(result), do: inspect(result, limit: 200, printable_limit: 4_096)

  def maybe_put_result_meta(detail, %LemonAgent.Types.AgentToolResult{} = result, name)
      when is_map(detail) do
    case extract_tool_result_meta(result.details, name) do
      nil -> detail
      meta -> Map.put(detail, :result_meta, meta)
    end
  end

  def maybe_put_result_meta(detail, _, _name), do: detail

  def action_ok?(_name, _result, true), do: false

  def action_ok?(name, %LemonAgent.Types.AgentToolResult{details: details}, false) do
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
      |> Enum.take_while(&(Map.get(&1, :role) != :user))
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
      usage -> Map.put(usage, :context_tokens, latest_context_tokens(messages))
    end
  end

  defp latest_context_tokens(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(0, fn message ->
      case Map.get(message, :usage) do
        %{input: input, output: output, cache_read: cache_read, cache_write: cache_write}
        when is_number(input) and is_number(output) and is_number(cache_read) and
               is_number(cache_write) ->
          input + output + cache_read + cache_write

        _ ->
          nil
      end
    end)
  end

  def merge_usage(acc, usage) do
    merged =
      Map.merge(acc, usage, fn _k, v1, v2 ->
        if is_number(v1) and is_number(v2), do: v1 + v2, else: v2
      end)

    previous_cost = Map.get(acc, :cost) || Map.get(acc, "cost")
    current_cost = Map.get(usage, :cost) || Map.get(usage, "cost")

    if is_map(previous_cost) or is_map(current_cost) do
      merged |> Map.delete("cost") |> Map.put(:cost, merge_cost(previous_cost, current_cost))
    else
      merged
    end
  end

  defp merge_cost(previous, current) do
    Enum.reduce(
      [:input, :output, :cache_read, :cache_write, :cache_write_long, :total],
      %{},
      fn key, cost ->
        first = cost_component(previous, key)
        second = cost_component(current, key)

        if is_nil(first) and is_nil(second),
          do: cost,
          else: Map.put(cost, key, (first || 0) + (second || 0))
      end
    )
  end

  defp cost_component(cost, key) when is_map(cost) do
    case Map.get(cost, key, Map.get(cost, Atom.to_string(key))) do
      value when is_number(value) -> value
      _ -> nil
    end
  end

  defp cost_component(_cost, _key), do: nil

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

  defp un_emitted_reasoning(block) do
    offset = min(block.emitted_bytes, byte_size(block.text))
    binary_part(block.text, offset, byte_size(block.text) - offset)
  end

  defp reasoning_action(block, phase, ok, delta) do
    text = block.text || ""

    %{
      id: block.id,
      kind: :reasoning,
      title: reasoning_title(text),
      phase: phase,
      ok: ok,
      detail: %{reasoning: reasoning_payload(text, phase, delta)}
    }
  end

  # Cumulative previews are bounded, while each incremental delta remains available
  # after that preview fills. This lets ACP append long thought streams faithfully.
  defp reasoning_payload(text, phase, delta) do
    preview = reasoning_payload_text(text, phase)

    full =
      LemonAi.Text.truncate_bytes_utf8(text, @operator_reasoning_max_bytes,
        marker: fn removed -> "\n… [#{removed} bytes of reasoning omitted]" end
      )

    %{text: preview, full_text: full, delta: delta, source: "lemon_reasoning"}
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

  def format_error(:model_routing_cost_cap, _state) do
    "Automatic model routing blocked this request: its projected cost exceeds " <>
      "model_routing.max_cost_usd, or its pricing/output limit is unknown. " <>
      "Configure complete model prices, increase the cap, or explicitly select a model."
  end

  def format_error(:circuit_open, state), do: format_circuit_open_error(state)

  def format_error(reason, _state) when is_binary(reason), do: reason

  def format_error(reason, state)
      when reason in [
             :rate_limited,
             :max_concurrency,
             :timeout,
             :closed,
             :econnrefused,
             :econnreset,
             :nxdomain
           ] do
    LemonAi.Error.format_error(reason, current_provider(state))
  end

  def format_error({:http_error, _status, _body} = reason, state),
    do: LemonAi.Error.format_error(reason, current_provider(state))

  def format_error({:error, reason}, state), do: format_error(reason, state)
  def format_error(reason, _state) when is_atom(reason), do: Atom.to_string(reason)

  def format_error(reason, _state) do
    Logger.warning("Session request failed: #{inspect(reason)}")

    "Something went wrong while running the request. Try again; if it keeps happening, run `lemon doctor`."
  end

  def cancel_error_message(:user_requested), do: "Cancelled by user"
  def cancel_error_message(reason), do: "Cancelled: #{format_error(reason, %{})}"

  def normalize_extra_tools_opt(tools) when is_list(tools) and tools != [], do: tools
  def normalize_extra_tools_opt(_), do: nil

  def maybe_add_opt(opts, _key, nil), do: opts
  def maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp boolean_or_nil(value) when is_boolean(value), do: value
  defp boolean_or_nil(_), do: nil

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

  defp task_result_events(details) when is_map(details) do
    events = Map.get(details, :events) || Map.get(details, "events")
    if is_list(events), do: events, else: []
  end

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
    base = LemonAi.Error.format_error(:circuit_open)

    with provider when is_atom(provider) <- current_provider(state),
         {:ok, breaker_state} <- LemonAi.CircuitBreaker.get_state(provider) do
      detail =
        breaker_state
        |> Map.get(:last_failure_reason)
        |> format_circuit_failure_reason()

      retry_after_ms = LemonAi.CircuitBreaker.time_until_recovery(provider)
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
    "Stream tracking could not start. #{format_circuit_failure_reason(reason) || "Run `lemon doctor`."}"
  end

  defp format_circuit_failure_reason({:stream_tracking_exception, message})
       when is_binary(message),
       do: message

  defp format_circuit_failure_reason({:stream_tracking_exit, reason}) do
    Logger.warning("Stream tracking exited: #{inspect(reason)}")
    "Stream tracking stopped unexpectedly. Run `lemon doctor`."
  end

  defp format_circuit_failure_reason({:unexpected_stream_result, result}) do
    Logger.warning("Unexpected stream result: #{inspect(result)}")
    "The provider returned an unexpected response. Run `lemon doctor`."
  end

  defp format_circuit_failure_reason({:exception, message}) when is_binary(message), do: message

  defp format_circuit_failure_reason(reason) when is_binary(reason), do: reason

  defp format_circuit_failure_reason(reason)
       when reason in [:timeout, :closed, :econnrefused, :econnreset, :nxdomain] do
    LemonAi.Error.format_error(reason)
  end

  defp format_circuit_failure_reason({:http_error, _status, _body} = reason),
    do: LemonAi.Error.format_error(reason)

  defp format_circuit_failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp format_circuit_failure_reason(reason) do
    Logger.warning("Circuit failure: #{inspect(reason)}")
    "The provider request failed. Run `lemon doctor`."
  end

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
