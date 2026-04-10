defmodule CodingAgent.Tools.Task.Runner do
  @moduledoc false

  require Logger

  alias AgentCore.AbortSignal
  alias Ai.Types.Context

  alias AgentCore.CliRunners.{
    ClaudeSubagent,
    CodexSubagent,
    KimiSubagent,
    OpencodeSubagent,
    PiSubagent
  }

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.BashExecutor
  alias CodingAgent.Coordinator
  alias CodingAgent.Session.ModelResolver
  alias CodingAgent.Session
  alias CodingAgent.SessionManager
  alias CodingAgent.SettingsManager
  alias CodingAgent.Subagents
  alias CodingAgent.Tools.Task.FastPath
  alias CodingAgent.Tools.Task.Result

  @await_poll_ms 200
  @default_task_session_timeout_ms nil

  @spec execute_via_coordinator(term(), String.t(), String.t(), String.t() | nil) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute_via_coordinator(coordinator, prompt, description, role_id) do
    task_run_id = generate_task_run_id()

    case Coordinator.run_subagent(coordinator,
           prompt: prompt,
           subagent: role_id,
           description: description
         ) do
      {:ok, result_text} ->
        %AgentToolResult{
          content: [%TextContent{text: result_text}],
          details: %{
            task_run_id: task_run_id,
            description: description,
            status: "completed",
            role: role_id,
            via_coordinator: true
          }
        }

      {:error, {status, error}} ->
        {:error, "Task #{status}: #{inspect(error)}"}

      {:error, reason} ->
        {:error, "Coordinator error: #{inspect(reason)}"}
    end
  end

  @spec execute_via_cli_engine(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          reference() | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute_via_cli_engine(engine, prompt, cwd, description, role_id, model, on_update, signal) do
    {module, engine_label} =
      case engine do
        "codex" -> {CodexSubagent, "codex"}
        "claude" -> {ClaudeSubagent, "claude"}
        "kimi" -> {KimiSubagent, "kimi"}
        "opencode" -> {OpencodeSubagent, "opencode"}
        "pi" -> {PiSubagent, "pi"}
      end

    role_prompt = if role_id, do: get_role_prompt(cwd, role_id), else: nil

    Logger.info(
      "Task tool cli engine start engine=#{engine_label} description=#{inspect(description)} role=#{inspect(role_id)} model=#{inspect(model)} cwd=#{inspect(cwd)}"
    )

    with {:ok, session} <-
           module.start(prompt: prompt, cwd: cwd, role_prompt: role_prompt, model: model) do
      abort_monitor = maybe_start_abort_monitor(signal, session.pid)

      result =
        reduce_cli_events(module.events(session), description, engine_label, on_update, signal)

      maybe_stop_abort_monitor(abort_monitor)

      details = %{
        description: description,
        status: if(result.error, do: "error", else: "completed"),
        engine: engine_label,
        role: role_id,
        model: model,
        resume_token: result.resume_token,
        error: result.error,
        stderr: result[:stderr]
      }

      tool_result = %AgentToolResult{
        content: [%TextContent{text: result.answer || ""}],
        details: details
      }

      if result.error do
        Logger.warning(
          "Task tool cli engine error engine=#{engine_label} description=#{inspect(description)} error=#{inspect(result.error)}"
        )

        error_msg =
          if result[:stderr] && result[:stderr] != "" && result[:stderr] != result.error do
            "#{format_cli_error(result.error)}\nstderr: #{result[:stderr]}"
          else
            format_cli_error(result.error)
          end

        {:error, %{message: error_msg, details: details, answer: result.answer || ""}}
      else
        Logger.info(
          "Task tool cli engine completed engine=#{engine_label} description=#{inspect(description)} answer_bytes=#{byte_size(result.answer || "")}"
        )

        tool_result
      end
    end
  end

  @spec execute_via_direct_provider(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          reference() | nil,
          keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute_via_direct_provider(
        engine,
        prompt,
        cwd,
        description,
        role_id,
        model,
        on_update,
        signal,
        opts \\ []
      ) do
    role_prompt = if role_id, do: get_role_prompt(cwd, role_id), else: nil
    provider_model = FastPath.direct_model_spec(%{engine: engine, model: model})
    system_prompt = role_prompt || FastPath.default_system_prompt(engine)
    override = Keyword.get(opts, :direct_provider_override)

    Logger.info(
      "Task tool direct provider start engine=#{engine} description=#{inspect(description)} model=#{inspect(provider_model)} cwd=#{inspect(cwd)}"
    )

    maybe_emit_cli_update(
      on_update,
      description,
      engine,
      "started",
      "Calling direct #{engine} provider"
    )

    result =
      cond do
        AbortSignal.aborted?(signal) ->
          {:error, "Task aborted"}

        is_function(override, 1) ->
          override.(%{
            engine: engine,
            prompt: prompt,
            cwd: cwd,
            description: description,
            role_id: role_id,
            role_prompt: role_prompt,
            system_prompt: system_prompt,
            model: provider_model
          })

        true ->
          run_direct_provider(engine, prompt, cwd, description, system_prompt, provider_model)
      end

    case result do
      %AgentToolResult{} = tool_result ->
        Logger.info(
          "Task tool direct provider completed engine=#{engine} description=#{inspect(description)} answer_bytes=#{byte_size(Result.extract_text(tool_result.content) || "")}"
        )

        maybe_emit_cli_update(
          on_update,
          description,
          engine,
          "completed",
          "Completed: direct #{engine} provider",
          %{execution_path: "direct_provider"}
        )

        tool_result

      {:error, reason} ->
        Logger.warning(
          "Task tool direct provider error engine=#{engine} description=#{inspect(description)} error=#{inspect(reason)}"
        )

        maybe_emit_cli_update(on_update, description, engine, "error", format_cli_error(reason))
        {:error, %{message: format_cli_error(reason), execution_path: "direct_provider"}}
    end
    |> then(&maybe_apply_abort_result(&1, signal))
  end

  @spec execute_via_internal_bash_fast_path(
          String.t() | nil,
          String.t(),
          String.t(),
          String.t(),
          (AgentToolResult.t() -> :ok) | nil,
          reference() | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute_via_internal_bash_fast_path(command, prompt, cwd, description, on_update, signal) do
    if is_binary(command) and command != "" do
      maybe_emit_action_update(
        on_update,
        description,
        "internal",
        command,
        :command,
        "started",
        %{command: command, execution_path: "internal_bash_fast_path"}
      )

      case BashExecutor.execute(command, cwd, signal: signal, timeout: :timer.minutes(30)) do
        {:ok, result} ->
          maybe_emit_action_update(
            on_update,
            description,
            "internal",
            "Completed: ``",
            :command,
            "completed",
            %{command: command, result: result, execution_path: "internal_bash_fast_path"}
          )

          output =
            result.output
            |> to_string()
            |> String.trim()

          with :ok <- verify_internal_bash_fast_path_output(prompt, output, result.exit_code) do
            %AgentToolResult{
              content: [%TextContent{text: output}],
              details: %{
                description: description,
                status: "completed",
                engine: "internal",
                execution_path: "internal_bash_fast_path",
                exit_code: result.exit_code
              }
            }
          else
            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "No bash command found for internal bash fast path"}
    end
  end

  @doc false
  def reduce_cli_events(events, description, engine_label, on_update) do
    reduce_cli_events(events, description, engine_label, on_update, nil)
  end

  @doc false
  def reduce_cli_events(events, description, engine_label, on_update, signal) do
    Enum.reduce_while(events, %{answer: nil, resume_token: nil, error: nil, stderr: nil}, fn
      {:started, token}, acc ->
        maybe_emit_cli_update(on_update, description, engine_label, "started", token.value)
        {:cont, %{acc | resume_token: token}}

      {:action, %{title: title, kind: kind}, :started, _opts}, acc ->
        maybe_emit_cli_update(
          on_update,
          description,
          engine_label,
          "running",
          title,
          %{current_action: %{title: title, kind: to_string(kind), phase: "started"}}
        )

        {:cont, acc}

      {:action, %{title: title, detail: detail, kind: kind}, :updated, _opts}, acc ->
        text = extract_action_detail_text(detail) || title

        extra_details =
          %{current_action: %{title: title, kind: to_string(kind), phase: "updated"}}
          |> maybe_add_action_detail(detail)

        maybe_emit_cli_update(
          on_update,
          description,
          engine_label,
          "running",
          text,
          extra_details
        )

        {:cont, acc}

      {:action, %{title: title, detail: detail, kind: kind}, :completed, _opts}, acc ->
        maybe_emit_cli_update(
          on_update,
          description,
          engine_label,
          "running",
          "Completed: #{title}",
          %{current_action: %{title: title, kind: to_string(kind), phase: "completed"}}
        )

        acc =
          if kind == :warning and is_map(detail) do
            cond do
              Map.has_key?(detail, :stderr) ->
                stderr = detail[:stderr] || detail.stderr
                updated = %{acc | stderr: stderr}
                if updated.error == nil, do: %{updated | error: stderr}, else: updated

              Map.has_key?(detail, :decode_error) ->
                if acc.error == nil, do: %{acc | error: detail.decode_error}, else: acc

              true ->
                acc
            end
          else
            acc
          end

        {:cont, acc}

      {:completed, answer, opts}, acc ->
        resume = opts[:resume] || acc.resume_token
        error = acc.error || opts[:error]
        {:cont, %{acc | answer: answer, resume_token: resume, error: error}}

      {:error, reason}, acc ->
        maybe_emit_cli_update(
          on_update,
          description,
          engine_label,
          "error",
          format_cli_error(reason)
        )

        {:cont, %{acc | error: acc.error || reason}}

      _, acc ->
        {:cont, acc}
    end)
    |> maybe_apply_abort(signal)
  end

  @spec start_session_with_prompt(
          keyword(),
          String.t(),
          String.t(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          String.t() | nil,
          String.t() | nil,
          keyword()
        ) :: AgentToolResult.t() | {:error, String.t()}
  def start_session_with_prompt(
        start_opts,
        prompt,
        description,
        signal,
        on_update,
        role_id,
        engine \\ "internal",
        opts \\ []
      ) do
    with {:ok, session} <- CodingAgent.start_session(start_opts) do
      session_id = Session.get_stats(session).session_id
      unsubscribe = Session.subscribe(session)
      session_ref = Process.monitor(session)
      timeout_ms = task_session_timeout_ms(opts)
      deadline_ms = if timeout_ms, do: System.monotonic_time(:millisecond) + timeout_ms, else: nil

      try do
        case Session.prompt(session, prompt) do
          :ok ->
            case await_result(
                   session,
                   session_ref,
                   session_id,
                   signal,
                   on_update,
                   description,
                   "",
                   "",
                   nil,
                   role_id,
                   engine,
                   timeout_ms,
                   deadline_ms,
                   task_session_poll_ms(opts)
                 ) do
              {:ok, %{text: text, thinking: thinking}} ->
                %AgentToolResult{
                  content: Result.build_update_content(text, thinking),
                  details: %{
                    session_id: session_id,
                    description: description,
                    status: "completed",
                    role: role_id,
                    engine: engine
                  }
                }

              {:error, reason} ->
                {:error, reason}
            end

          {:error, :already_streaming} ->
            {:error, "Task session is already running"}
        end
      after
        Process.demonitor(session_ref, [:flush])

        if is_function(unsubscribe, 0) do
          unsubscribe.()
        end

        stop_session(session)
      end
    else
      {:error, reason} ->
        {:error, "Failed to start task session: #{inspect(reason)}"}
    end
  end

  @spec maybe_apply_role_prompt(String.t(), String.t() | nil, String.t()) ::
          String.t() | {:error, String.t()}
  def maybe_apply_role_prompt(prompt, nil, _cwd), do: prompt
  def maybe_apply_role_prompt(prompt, "", _cwd), do: prompt

  def maybe_apply_role_prompt(prompt, role_id, cwd) do
    case Subagents.get(cwd, role_id) do
      nil -> {:error, "Unknown role: #{role_id}"}
      role -> role.prompt <> "\n\n" <> prompt
    end
  end

  defp get_role_prompt(cwd, role_id) do
    case Subagents.get(cwd, role_id) do
      nil -> nil
      role -> role.prompt
    end
  end

  defp maybe_start_abort_monitor(nil, _pid), do: nil

  defp maybe_start_abort_monitor(signal, pid) when is_reference(signal) and is_pid(pid) do
    spawn(fn -> abort_monitor_loop(signal, pid) end)
  end

  defp maybe_start_abort_monitor(_signal, _pid), do: nil

  defp maybe_stop_abort_monitor(nil), do: :ok

  defp maybe_stop_abort_monitor(pid) when is_pid(pid) do
    send(pid, :stop)
    :ok
  end

  defp maybe_emit_cli_update(on_update, description, engine, status, text, extra_details \\ %{})
  defp maybe_emit_cli_update(nil, _description, _engine, _status, _text, _extra_details), do: :ok

  defp maybe_emit_cli_update(on_update, description, engine, status, text, extra_details) do
    on_update.(%AgentToolResult{
      content: [%TextContent{text: text}],
      details:
        %{
          description: description,
          status: status,
          engine: engine
        }
        |> Map.merge(extra_details)
    })
  end

  defp maybe_apply_abort(result, signal) do
    if AbortSignal.aborted?(signal) do
      %{result | error: result.error || "Task aborted"}
    else
      result
    end
  end

  defp maybe_apply_abort_result({:error, _} = error, _signal), do: error

  defp maybe_apply_abort_result(%AgentToolResult{} = result, signal) do
    if AbortSignal.aborted?(signal) do
      {:error, %{message: "Task aborted", answer: Result.extract_text(result.content) || ""}}
    else
      result
    end
  end

  defp extract_action_detail_text(detail) when is_map(detail) do
    cond do
      is_binary(Map.get(detail, :message)) -> Map.get(detail, :message)
      is_binary(Map.get(detail, "message")) -> Map.get(detail, "message")
      is_binary(Map.get(detail, :output)) -> Map.get(detail, :output)
      is_binary(Map.get(detail, "output")) -> Map.get(detail, "output")
      is_binary(Map.get(detail, :stdout)) -> Map.get(detail, :stdout)
      is_binary(Map.get(detail, "stdout")) -> Map.get(detail, "stdout")
      is_binary(Map.get(detail, :stderr)) -> Map.get(detail, :stderr)
      is_binary(Map.get(detail, "stderr")) -> Map.get(detail, "stderr")
      is_binary(Map.get(detail, :result)) -> Map.get(detail, :result)
      is_binary(Map.get(detail, "result")) -> Map.get(detail, "result")
      true -> nil
    end
  end

  defp extract_action_detail_text(_detail), do: nil

  defp maybe_add_action_detail(details, detail) when is_map(detail) and map_size(detail) > 0 do
    Map.put(details, :action_detail, detail)
  end

  defp maybe_add_action_detail(details, _detail), do: details

  defp abort_monitor_loop(signal, pid) do
    receive do
      :stop -> :ok
    after
      200 ->
        if AbortSignal.aborted?(signal) do
          Process.exit(pid, :kill)
          :ok
        else
          abort_monitor_loop(signal, pid)
        end
    end
  end

  defp run_direct_provider(_engine, _prompt, _cwd, _description, _system_prompt, nil) do
    {:error, "No direct-provider model configured"}
  end

  defp run_direct_provider(engine, prompt, cwd, description, system_prompt, model_spec) do
    settings = SettingsManager.load(cwd)
    model = ModelResolver.resolve_session_model(model_spec, settings)
    resolved_api_key = ModelResolver.build_get_api_key(settings).(model.provider)

    stream_opts =
      model
      |> ModelResolver.build_stream_options(settings, nil, cwd)
      |> maybe_put_api_key(resolved_api_key)

    context =
      Ai.new_context(system_prompt: system_prompt)
      |> Context.add_user_message(prompt)

    case Ai.complete(model, context, stream_opts) do
      {:ok, message} ->
        %AgentToolResult{
          content: [%TextContent{text: Ai.get_text(message)}],
          details: %{
            description: description,
            status: "completed",
            engine: engine,
            model: model.id,
            provider: model.provider,
            execution_path: "direct_provider"
          }
        }

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_api_key(stream_opts, api_key) when is_binary(api_key) and api_key != "" do
    %{stream_opts | api_key: api_key}
  end

  defp maybe_put_api_key(stream_opts, _api_key), do: stream_opts

  defp await_result(
         session,
         session_ref,
         session_id,
         signal,
         on_update,
         description,
         last_text,
         last_thinking,
         last_tool_text,
         role_id,
         engine,
         timeout_ms,
         deadline_ms,
         poll_ms
       ) do
    receive do
      {:DOWN, ^session_ref, :process, _pid, reason} ->
        maybe_finalize_from_fallback(
          nil,
          format_session_exit(reason),
          last_text,
          last_thinking,
          last_tool_text
        )

      {:session_event, ^session_id, {:tool_execution_start, _id, name, args}} ->
        kind = internal_tool_kind(name)
        title = internal_tool_title(name, args)

        maybe_emit_action_update(
          on_update,
          description,
          engine,
          title,
          kind,
          "started",
          args
        )

        await_result(
          session,
          session_ref,
          session_id,
          signal,
          on_update,
          description,
          last_text,
          last_thinking,
          last_tool_text,
          role_id,
          engine,
          timeout_ms,
          deadline_ms,
          poll_ms
        )

      {:session_event, ^session_id, {:tool_execution_update, _id, name, args, _partial_result}} ->
        kind = internal_tool_kind(name)
        title = internal_tool_title(name, args)

        maybe_emit_action_update(
          on_update,
          description,
          engine,
          title,
          kind,
          "updated",
          args
        )

        await_result(
          session,
          session_ref,
          session_id,
          signal,
          on_update,
          description,
          last_text,
          last_thinking,
          last_tool_text,
          role_id,
          engine,
          timeout_ms,
          deadline_ms,
          poll_ms
        )

      {:session_event, ^session_id, {:tool_execution_end, _id, name, result, _is_error}} ->
        kind = internal_tool_kind(name)
        title = internal_tool_title(name, %{})
        last_tool_text = extract_tool_result_text(result) || last_tool_text

        maybe_emit_action_update(
          on_update,
          description,
          engine,
          "Completed: #{title}",
          kind,
          "completed",
          %{name: name, result: result}
        )

        await_result(
          session,
          session_ref,
          session_id,
          signal,
          on_update,
          description,
          last_text,
          last_thinking,
          last_tool_text,
          role_id,
          engine,
          timeout_ms,
          deadline_ms,
          poll_ms
        )

      {:session_event, ^session_id, {:message_update, %Ai.Types.AssistantMessage{} = msg, _event}} ->
        text = Ai.get_text(msg)
        thinking = Ai.get_thinking(msg)

        {last_text, last_thinking} =
          maybe_emit_update(
            on_update,
            text,
            thinking,
            last_text,
            last_thinking,
            description,
            session_id,
            role_id
          )

        await_result(
          session,
          session_ref,
          session_id,
          signal,
          on_update,
          description,
          last_text,
          last_thinking,
          last_tool_text,
          role_id,
          engine,
          timeout_ms,
          deadline_ms,
          poll_ms
        )

      {:session_event, ^session_id, {:message_end, %Ai.Types.AssistantMessage{} = msg}} ->
        text = Ai.get_text(msg)
        thinking = Ai.get_thinking(msg)

        {last_text, last_thinking} =
          maybe_emit_update(
            on_update,
            text,
            thinking,
            last_text,
            last_thinking,
            description,
            session_id,
            role_id
          )

        await_result(
          session,
          session_ref,
          session_id,
          signal,
          on_update,
          description,
          last_text,
          last_thinking,
          last_tool_text,
          role_id,
          engine,
          timeout_ms,
          deadline_ms,
          poll_ms
        )

      {:session_event, ^session_id, {:agent_end, messages}} ->
        {:ok, Result.extract_final_payload(messages, last_text, last_thinking)}

      {:session_event, ^session_id, {:error, reason, _partial_state}} ->
        maybe_finalize_from_fallback(
          session,
          reason,
          last_text,
          last_thinking,
          last_tool_text
        )

      {:session_event, ^session_id, _event} ->
        await_result(
          session,
          session_ref,
          session_id,
          signal,
          on_update,
          description,
          last_text,
          last_thinking,
          last_tool_text,
          role_id,
          engine,
          timeout_ms,
          deadline_ms,
          poll_ms
        )
    after
      await_timeout(deadline_ms, poll_ms) ->
        if AbortSignal.aborted?(signal) do
          Session.abort(session)
          {:error, "Task aborted"}
        else
          case remaining_task_session_ms(deadline_ms) do
            remaining when remaining <= 0 ->
              case maybe_timeout_fallback_payload(
                     session,
                     last_text,
                     last_thinking,
                     last_tool_text
                   ) do
                {:ok, payload} ->
                  {:ok, payload}

                :error ->
                  Session.abort(session)
                  {:error, task_session_timeout_error(timeout_ms)}
              end

            _remaining ->
              await_result(
                session,
                session_ref,
                session_id,
                signal,
                on_update,
                description,
                last_text,
                last_thinking,
                last_tool_text,
                role_id,
                engine,
                timeout_ms,
                deadline_ms,
                poll_ms
              )
          end
        end
    end
  end

  defp task_session_timeout_ms(opts) do
    case Keyword.get(opts, :task_session_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_task_session_timeout_ms
    end
  end

  defp task_session_poll_ms(opts) do
    case Keyword.get(opts, :task_session_poll_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @await_poll_ms
    end
  end

  defp remaining_task_session_ms(nil), do: :infinity

  defp remaining_task_session_ms(deadline_ms) do
    deadline_ms - System.monotonic_time(:millisecond)
  end

  defp await_timeout(nil, poll_ms), do: poll_ms

  defp await_timeout(deadline_ms, poll_ms) do
    remaining_task_session_ms(deadline_ms)
    |> min(poll_ms)
    |> max(0)
  end

  defp task_session_timeout_error(nil), do: "Task session timed out waiting for completion"

  defp task_session_timeout_error(timeout_ms) do
    "Task session timed out after #{timeout_ms}ms waiting for completion"
  end

  defp verify_internal_bash_fast_path_output(_prompt, _output, exit_code) when exit_code != 0 do
    {:error, "Bash fast-path command exited with code #{exit_code}"}
  end

  defp verify_internal_bash_fast_path_output(prompt, output, 0) do
    cond do
      String.contains?(prompt, "return the absolute path only") and
          not String.starts_with?(output, "/") ->
        {:error, "Bash fast-path output was not an absolute path"}

      String.contains?(prompt, "return the number only") and not Regex.match?(~r/^\d+$/, output) ->
        {:error, "Bash fast-path output was not a number"}

      String.contains?(prompt, "return exactly `yes` or `no`") and output not in ["yes", "no"] ->
        {:error, "Bash fast-path output was not yes/no"}

      true ->
        case Regex.run(~r/return exactly `([^`]+)`/i, prompt, capture: :all_but_first) do
          [expected] when output != expected ->
            {:error, "Bash fast-path output did not match the expected value"}

          _ ->
            :ok
        end
    end
  end

  defp maybe_timeout_fallback_payload(session, last_text, last_thinking, last_tool_text) do
    case recover_fallback_payload(session, last_text, last_thinking, last_tool_text) do
      nil ->
        :error

      payload ->
        Session.abort(session)
        {:ok, payload}
    end
  end

  defp maybe_finalize_from_fallback(session, reason, last_text, last_thinking, last_tool_text) do
    case recover_fallback_payload(session, last_text, last_thinking, last_tool_text) do
      nil -> {:error, reason}
      payload -> {:ok, payload}
    end
  end

  defp recover_fallback_payload(session, last_text, last_thinking, last_tool_text) do
    session_payload = session && extract_session_payload(session)

    cond do
      is_map(session_payload) and payload_present?(session_payload) ->
        session_payload

      payload_present?(%{text: last_text, thinking: last_thinking}) ->
        %{text: last_text || "", thinking: last_thinking || ""}

      is_binary(last_tool_text) and last_tool_text != "" ->
        %{text: last_tool_text, thinking: ""}

      true ->
        nil
    end
  end

  defp extract_session_payload(session) do
    with true <- is_pid(session) and Process.alive?(session),
         state when is_map(state) <- Session.get_state(session),
         session_manager when not is_nil(session_manager) <- Map.get(state, :session_manager),
         %{messages: messages} <- SessionManager.build_session_context(session_manager),
         %{text: text, thinking: thinking} = payload <- extract_assistant_payload(messages),
         true <- payload_present?(%{text: text, thinking: thinking}) do
      payload
    else
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp extract_assistant_payload(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => "assistant", "content" => content} ->
        %{text: extract_serialized_text(content), thinking: extract_serialized_thinking(content)}

      _ ->
        nil
    end)
  end

  defp extract_assistant_payload(_), do: nil

  defp extract_serialized_text(content) when is_binary(content), do: content

  defp extract_serialized_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_serialized_text(_), do: ""

  defp extract_serialized_thinking(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "thinking", "thinking" => text} when is_binary(text) -> text
      %{"type" => "thinking", "text" => text} when is_binary(text) -> text
      %{type: "thinking", thinking: text} when is_binary(text) -> text
      %{type: "thinking", text: text} when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_serialized_thinking(_), do: ""

  defp extract_tool_result_text(%AgentToolResult{content: content}),
    do: Result.extract_text(content)

  defp extract_tool_result_text(%{content: content}), do: Result.extract_text(content)
  defp extract_tool_result_text(text) when is_binary(text), do: text
  defp extract_tool_result_text(_), do: nil

  defp payload_present?(%{text: text, thinking: thinking}) do
    (is_binary(text) and text != "") or (is_binary(thinking) and thinking != "")
  end

  defp format_session_exit(:normal), do: "Task session exited before completion"
  defp format_session_exit(:shutdown), do: "Task session exited before completion"
  defp format_session_exit({:shutdown, _}), do: "Task session exited before completion"

  defp format_session_exit(reason) do
    "Task session crashed before completion: #{inspect(reason)}"
  end

  defp maybe_emit_action_update(nil, _description, _engine, _text, _kind, _phase, _detail) do
    :ok
  end

  defp maybe_emit_action_update(on_update, description, engine, text, kind, phase, detail) do
    extra_details = %{
      current_action: %{title: text, kind: to_string(kind), phase: phase}
    }

    extra_details =
      if is_map(detail) and map_size(detail) > 0 do
        Map.put(extra_details, :action_detail, detail)
      else
        extra_details
      end

    result = %AgentToolResult{
      content: [%TextContent{text: text}],
      details:
        %{
          description: description,
          status: "running",
          engine: engine
        }
        |> Map.merge(extra_details)
    }

    on_update.(result)
  end

  defp maybe_emit_update(
         nil,
         _text,
         _thinking,
         last_text,
         last_thinking,
         _description,
         _session_id,
         _role_id
       ) do
    {last_text, last_thinking}
  end

  defp maybe_emit_update(
         on_update,
         text,
         thinking,
         last_text,
         last_thinking,
         description,
         session_id,
         role_id
       ) do
    if (text != "" or thinking != "") and (text != last_text or thinking != last_thinking) do
      on_update.(%AgentToolResult{
        content: Result.build_update_content(text, thinking),
        details: %{
          session_id: session_id,
          description: description,
          status: "running",
          role: role_id
        }
      })
    end

    {text, thinking}
  end

  defp stop_session(session) when is_pid(session) do
    try do
      if Process.whereis(CodingAgent.SessionSupervisor) do
        _ = CodingAgent.SessionSupervisor.stop_session(session)
      else
        GenServer.stop(session, :normal, 5_000)
      end
    rescue
      _ -> :ok
    end

    :ok
  end

  defp internal_tool_kind(name) do
    case String.downcase(name || "") do
      "bash" -> :command
      "read" -> :tool
      "write" -> :file_change
      "edit" -> :file_change
      "hashline_edit" -> :file_change
      "glob" -> :tool
      "grep" -> :tool
      "websearch" -> :web_search
      "webfetch" -> :web_search
      "task" -> :subagent
      "agent" -> :subagent
      "cron" -> :subagent
      _ -> :tool
    end
  end

  defp internal_tool_title(name, args) do
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

      "hashline_edit" ->
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

      "task" ->
        engine_suffix =
          case a["engine"] do
            engine when is_binary(engine) and engine not in ["", "internal"] -> "(#{engine})"
            _ -> ""
          end

        "task#{engine_suffix}: #{String.slice(a["description"] || a["prompt"] || "", 0, 50)}"

      "agent" ->
        "agent: #{String.slice(a["prompt"] || a["description"] || "", 0, 50)}"

      "cron" ->
        "cron: #{String.slice(a["prompt"] || "", 0, 50)}"

      n ->
        n
    end
  end

  defp path_label(path) when is_binary(path) do
    parts = Path.split(path)

    case length(parts) do
      n when n > 2 -> Path.join(Enum.take(parts, -2))
      _ -> path
    end
  end

  defp path_label(other), do: inspect(other)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_keys(_), do: %{}

  defp format_cli_error(reason) when is_binary(reason), do: reason
  defp format_cli_error(reason), do: inspect(reason)

  defp generate_task_run_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
