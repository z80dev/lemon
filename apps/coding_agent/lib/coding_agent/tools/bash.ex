defmodule CodingAgent.Tools.Bash do
  @moduledoc """
  Bash command execution tool for the coding agent.

  Ordinary foreground commands run under `CodingAgent.ProcessManager`. After
  `timeout` milliseconds (default 120 s, max 10 min), the caller detaches and
  receives the same process ID; the command continues without re-execution.
  Output capture remains subject to the manager's explicit memory/artifact
  quotas. PTY and ACP-client terminals still use their terminal executor and
  are killed on timeout; those terminal handles cannot be adopted by the local
  process manager. Abort signals still stop foreground work.

  `run_in_background: true` starts the command under
  `CodingAgent.ProcessManager` and returns a `process_id` immediately; read
  its output with `bash_output` and stop it with `kill_process`. Background
  processes are owned by the calling session and are killed when that
  session's process exits.

  `cwd` runs the command in another existing directory (relative paths
  resolve against the session cwd) and `env` layers extra string variables
  over the inherited environment; both apply to foreground, PTY, background
  and ACP-terminal runs. Bare or whole-word quoted `skill://` and
  `artifact://` references in `command` are replaced by their shell-quoted
  absolute paths before the command starts; an unresolvable reference fails
  the call without running anything.
  """

  alias CodingAgent.BashExecutor
  alias CodingAgent.ProcessManager

  alias CodingAgent.Tools.Bash.{
    GitGuard,
    Interceptor,
    InternalUrlExpansion,
    Service,
    StreamingPreview
  }

  alias CodingAgent.Tools.PathHelpers
  alias LemonAgent.AbortSignal
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @default_timeout_ms 120_000
  @max_timeout_ms 600_000
  @env_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @doc """
  Returns the bash tool definition.

  ## Parameters

    * `cwd` - The working directory for command execution
    * `opts` - `:timeout_ms` / `:bash_timeout_ms` override the default
      foreground timeout; `:session_id` / `:session_pid` own background
      processes

  ## Returns

  An `AgentTool` struct configured for bash command execution.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "bash",
      timeout_ms: :infinity,
      description:
        "Execute a bash command in the project root (or `cwd`). Foreground commands time out after " <>
          "`timeout` ms (default #{@default_timeout_ms}, max #{@max_timeout_ms}), then continue " <>
          "in the background with a process_id (PTY/ACP terminals are killed instead). Use " <>
          "bash_output to read output and kill_process to stop. Set `cwd` instead of `cd`; " <>
          "quote-heavy values through `env`. skill:// and artifact:// references in the command " <>
          "are replaced with their absolute file paths.",
      label: "Run Command",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "The bash command to execute"},
          "cwd" => %{
            "type" => "string",
            "description" =>
              "Working directory for this command (absolute, or relative to the project root); must exist"
          },
          "env" => %{
            "type" => "object",
            "additionalProperties" => %{"type" => "string"},
            "description" =>
              "Extra environment variables for this command, e.g. {\"NAME\": \"value\"}"
          },
          "timeout" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => @max_timeout_ms,
            "description" =>
              "Foreground timeout in milliseconds (default #{@default_timeout_ms}, " <>
                "max #{@max_timeout_ms}). Detaches ordinary commands; kills PTY/ACP terminals."
          },
          "run_in_background" => %{
            "type" => "boolean",
            "description" =>
              "Start the command in the background and return a process_id immediately " <>
                "(default: false). Read output with bash_output; stop it with kill_process."
          },
          "name" => %{
            "type" => "string",
            "description" =>
              "Session/project-scoped service name; starting the same name restarts it"
          },
          "ready" => %{
            "type" => "object",
            "properties" => %{
              "log" => %{"type" => "string", "description" => "Readiness log regex"},
              "port" => %{"type" => "integer", "minimum" => 1, "maximum" => 65_535},
              "host" => %{"type" => "string", "default" => "127.0.0.1"},
              "timeout_s" => %{"type" => "number", "default" => 30}
            },
            "description" => "Return when the log regex matches OR the TCP port accepts"
          },
          "pty" => %{
            "type" => "boolean",
            "description" =>
              "Run in PTY mode when the command needs a real terminal (e.g. sudo, ssh, top, less); default: false"
          }
        },
        "required" => ["command"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Execute a bash command.

  ## Parameters

    * `params` - "command" (required), "timeout", "run_in_background", "pty",
      "cwd", "env"
    * `signal` - Abort signal reference for cancellation (can be nil)
    * `on_update` - Callback function for streaming partial results (can be nil)
    * `cwd` - Working directory for command execution
    * `opts` - See `tool/2`

  ## Returns

    * `AgentToolResult.t()` (with `is_error: true` for timeouts and execution failures)
    * `{:error, term()}` for invalid parameters
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, on_update, cwd, opts) do
    # Check abort signal before starting
    if signal && AbortSignal.aborted?(signal) do
      %AgentToolResult{content: [%TextContent{text: "Command cancelled."}], is_error: true}
    else
      params
      |> do_execute(signal, on_update, cwd, opts)
      |> ToolResultTrust.untrusted(:shell)
    end
  end

  defp do_execute(params, signal, on_update, cwd, opts) do
    command = Map.get(params, "command")
    use_pty = Map.get(params, "pty", false)
    background = Map.get(params, "run_in_background", false)

    cond do
      not is_binary(command) or String.trim(command) == "" ->
        {:error, "command must be a non-empty string"}

      not is_boolean(use_pty) ->
        {:error, "pty must be a boolean"}

      not is_boolean(background) ->
        {:error, "run_in_background must be a boolean"}

      Map.has_key?(params, "ready") and not Map.has_key?(params, "name") ->
        {:error, "ready requires a service name"}

      Map.has_key?(params, "name") and
          (background or use_pty or Map.has_key?(params, "timeout")) ->
        {:error, "name is incompatible with run_in_background, pty and timeout"}

      background and use_pty ->
        {:error, "pty is not supported with run_in_background"}

      true ->
        with {:ok, run_cwd} <- resolve_cwd(Map.get(params, "cwd"), cwd),
             {:ok, env} <- validate_env(Map.get(params, "env")),
             {:ok, command} <- InternalUrlExpansion.expand(command, Keyword.put(opts, :cwd, cwd)),
             :ok <- Interceptor.check(command, opts),
             :ok <- GitGuard.check(command, run_cwd, Keyword.put(opts, :command_env, env)) do
          cond do
            Map.has_key?(params, "name") ->
              Service.execute(
                params,
                command,
                run_cwd,
                env,
                signal,
                Keyword.put(opts, :project_cwd, cwd)
              )

            background ->
              run_in_background(command, run_cwd, env, opts)

            true ->
              with {:ok, timeout_ms} <- resolve_timeout(params, opts) do
                run_foreground(
                  command,
                  use_pty,
                  timeout_ms,
                  signal,
                  on_update,
                  run_cwd,
                  env,
                  opts
                )
              end
          end
        else
          {:blocked, message} ->
            %AgentToolResult{content: [%TextContent{text: message}], is_error: true}

          error ->
            error
        end
    end
  end

  defp resolve_cwd(nil, cwd), do: {:ok, cwd}

  defp resolve_cwd(path, cwd) when is_binary(path) do
    resolved =
      if String.contains?(path, <<0>>), do: nil, else: PathHelpers.resolve_path(path, cwd)

    cond do
      String.trim(path) == "" -> {:error, "cwd must be a non-empty string"}
      resolved && File.dir?(resolved) -> {:ok, resolved}
      true -> {:error, "cwd is not an existing directory: #{inspect(path)}"}
    end
  end

  defp resolve_cwd(_path, _cwd), do: {:error, "cwd must be a string"}

  defp validate_env(nil), do: {:ok, %{}}

  defp validate_env(env) when is_map(env) do
    Enum.reduce_while(env, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      cond do
        not (is_binary(name) and Regex.match?(@env_name, name)) ->
          {:halt,
           {:error,
            "env name #{inspect(name)} is invalid; names must match ^[A-Za-z_][A-Za-z0-9_]*$"}}

        not is_binary(value) ->
          {:halt, {:error, "env value for #{name} must be a string"}}

        String.contains?(value, <<0>>) ->
          {:halt, {:error, "env value for #{name} must not contain NUL bytes"}}

        true ->
          {:cont, {:ok, Map.put(acc, name, value)}}
      end
    end)
  end

  defp validate_env(_env),
    do: {:error, "env must be an object mapping variable names to string values"}

  defp resolve_timeout(params, opts) do
    default =
      Keyword.get(opts, :timeout_ms, Keyword.get(opts, :bash_timeout_ms, @default_timeout_ms))

    case Map.get(params, "timeout") do
      nil -> {:ok, default}
      ms when is_integer(ms) and ms > 0 -> {:ok, min(ms, @max_timeout_ms)}
      ms when is_float(ms) and ms >= 1 -> {:ok, min(trunc(ms), @max_timeout_ms)}
      _ -> {:error, "timeout must be a positive number of milliseconds (max #{@max_timeout_ms})"}
    end
  end

  defp run_foreground(command, use_pty, timeout_ms, signal, on_update, cwd, env, opts) do
    # Set up streaming callback if on_update is provided
    {accumulator_pid, streaming_callback} = build_streaming_callback(on_update)

    executor_opts =
      [
        on_chunk: streaming_callback,
        signal: signal,
        timeout: timeout_ms,
        pty: use_pty,
        env: env
      ]

    executor =
      cond do
        use_pty -> BashExecutor
        Keyword.get(opts, :acp_client_terminal) == true -> CodingAgent.ACPTerminalExecutor
        true -> CodingAgent.Tools.Bash.Managed
      end

    executor_opts =
      executor_opts
      |> Keyword.put(:run_id, Keyword.get(opts, :run_id))
      |> Keyword.put(:on_terminal, fn id ->
        if is_function(on_update, 1) do
          on_update.(%AgentToolResult{content: [], details: %{terminalId: id}})
        end
      end)

    executor_opts =
      Keyword.merge(executor_opts, Keyword.take(opts, [:session_id, :session_pid]))

    try do
      case executor.execute(command, cwd, executor_opts) do
        {:ok, result} ->
          format_result(result, timeout_ms, cwd, opts)

        {:detached, id, snapshot, output} ->
          %AgentToolResult{
            content: [
              %TextContent{
                text:
                  output <>
                    "\n\nForeground wait timed out after #{timeout_ms} ms; " <>
                    "command continues as #{id}. Read with bash_output; stop with kill_process. " <>
                    "Do not rerun the command."
              }
            ],
            details: %{
              process_id: id,
              status: snapshot.status,
              exit_code: nil,
              background: true,
              timed_out: true
            }
          }

        {:error, reason} ->
          %AgentToolResult{
            content: [%TextContent{text: "Error executing command: #{inspect(reason)}"}],
            is_error: true
          }
      end
    after
      # Stop the accumulator Agent to prevent memory leaks
      if accumulator_pid, do: Agent.stop(accumulator_pid)
    end
  end

  defp run_in_background(command, cwd, env, opts) do
    exec_opts = [
      command: command,
      cwd: cwd,
      env: env,
      owner: Keyword.get(opts, :session_id),
      owner_pid: Keyword.get(opts, :session_pid)
    ]

    case ProcessManager.exec(exec_opts) do
      {classification, process_id} when classification in [:ok, :queued] ->
        status = if classification == :queued, do: :queued, else: :running

        receipt =
          if classification == :queued,
            do: "Queued background launch",
            else: "Started background process"

        %AgentToolResult{
          content: [
            %TextContent{
              text:
                "#{receipt} #{process_id}. Read its output with " <>
                  "bash_output (process_id: \"#{process_id}\"); stop it with kill_process."
            }
          ],
          details: %{process_id: process_id, status: status, exit_code: nil, background: true}
        }

      {:error, {:outcome_unknown, process_id}} ->
        %AgentToolResult{
          content: [
            %TextContent{
              text:
                "Launch outcome unknown for #{process_id}. Reconcile with bash_output; " <>
                  "do not automatically rerun the command."
            }
          ],
          details: %{
            process_id: process_id,
            status: :unknown,
            classification: :outcome_unknown,
            exit_code: nil,
            background: true
          },
          is_error: true
        }

      {:error, reason} ->
        {:error, "Failed to start background process: #{inspect(reason)}"}
    end
  end

  defp build_streaming_callback(nil), do: {nil, nil}

  defp build_streaming_callback(on_update) do
    {:ok, accumulator} = Agent.start_link(fn -> StreamingPreview.new() end)

    callback = fn chunk ->
      preview =
        Agent.get_and_update(accumulator, fn state ->
          next = StreamingPreview.append(state, chunk)
          {StreamingPreview.render(next), next}
        end)

      on_update.(
        ToolResultTrust.untrusted(
          %AgentToolResult{content: [%TextContent{text: preview}]},
          :shell
        )
      )
    end

    {accumulator, callback}
  end

  defp format_result(%BashExecutor.Result{} = result, timeout_ms, cwd, opts) do
    {reference, artifact_uri} =
      if result.full_output_path do
        case CodingAgent.Artifacts.register(result.full_output_path, cwd, opts) do
          {:ok, uri} -> {uri, uri}
          {:error, _} -> {result.full_output_path, nil}
        end
      else
        {nil, nil}
      end

    output = output_with_spill(result, reference)

    {text, is_error} =
      cond do
        result.timed_out ->
          notice =
            "Command timed out after #{timeout_ms} ms and was killed. Pass a larger timeout " <>
              "(max #{@max_timeout_ms} ms) or use run_in_background: true."

          {if(output != "", do: "#{output}\n\n#{notice}", else: notice), true}

        result.cancelled ->
          {if(output != "", do: "Command cancelled.\n\n#{output}", else: "Command cancelled."),
           true}

        result.exit_code == 0 ->
          {output, false}

        true ->
          notice = "Command exited with code #{result.exit_code}"
          {if(output != "", do: "#{output}\n\n#{notice}", else: notice), true}
      end

    text =
      if result.pty_fallback,
        do: "pty requested but unavailable; ran without a terminal\n\n" <> text,
        else: text

    details = build_details(result)
    details = if artifact_uri, do: Map.put(details, :artifact_uri, artifact_uri), else: details
    details = if result.timed_out, do: Map.put(details, :timed_out, true), else: details

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: details,
      is_error: is_error
    }
  end

  defp output_with_spill(result, reference) do
    output = result.output || ""

    cond do
      result.truncated && reference ->
        "#{output}\n\n[Full output saved to: #{reference}. Use read with offset/limit to retrieve it.]"

      result.client_output_truncated ->
        "#{output}\n\n[The ACP client discarded earlier terminal output; only its retained output tail is available.]"

      true ->
        output
    end
  end

  defp build_details(%BashExecutor.Result{} = result) do
    details = %{
      exit_code: result.exit_code,
      truncated: result.truncated,
      pty_fallback: result.pty_fallback
    }

    details =
      if result.terminal_id,
        do: Map.put(details, :terminalId, result.terminal_id),
        else: details

    if result.full_output_path do
      Map.put(details, :full_output_path, result.full_output_path)
    else
      details
    end
  end
end
