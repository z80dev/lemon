defmodule CodingAgent.Tools.Bash do
  @moduledoc """
  Bash command execution tool for the coding agent.

  Foreground commands stream output, honour abort signals, and are killed
  (with their whole process tree) after `timeout` milliseconds (default
  120 s, max 10 min). A timeout or an execution failure is returned as an
  error tool result. Streaming replacement snapshots retain at most 50,000
  output bytes plus a fixed omission marker; the executor's final result and
  full-output spill file remain authoritative, including timeout/cancellation results.

  `run_in_background: true` starts the command under
  `CodingAgent.ProcessManager` and returns a `process_id` immediately; read
  its output with `bash_output` and stop it with `kill_process`. Background
  processes are owned by the calling session and are killed when that
  session's process exits.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAi.Types.TextContent
  alias CodingAgent.BashExecutor
  alias CodingAgent.ProcessManager
  alias CodingAgent.Tools.Bash.StreamingPreview

  @default_timeout_ms 120_000
  @max_timeout_ms 600_000

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
      description:
        "Execute a bash command in the project root. Foreground commands time out after " <>
          "`timeout` ms (default #{@default_timeout_ms}, max #{@max_timeout_ms}). For servers, " <>
          "watchers, or builds that may run longer, set run_in_background: true, then poll with " <>
          "bash_output and stop with kill_process.",
      label: "Run Command",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "The bash command to execute"},
          "timeout" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => @max_timeout_ms,
            "description" =>
              "Foreground timeout in milliseconds (default #{@default_timeout_ms}, " <>
                "max #{@max_timeout_ms}). The command and its children are killed when it expires."
          },
          "run_in_background" => %{
            "type" => "boolean",
            "description" =>
              "Start the command in the background and return a process_id immediately " <>
                "(default: false). Read output with bash_output; stop it with kill_process."
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

    * `tool_call_id` - Unique identifier for this tool invocation
    * `params` - "command" (required), "timeout", "run_in_background", "pty"
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
      |> CodingAgent.Artifacts.attach(cwd, opts)
      |> ToolResultTrust.untrusted(:shell)
    end
  end

  defp do_execute(params, signal, on_update, cwd, opts) do
    command = Map.get(params, "command")
    use_pty = Map.get(params, "pty", false)

    cond do
      not is_binary(command) or String.trim(command) == "" ->
        {:error, "command must be a non-empty string"}

      not is_boolean(use_pty) ->
        {:error, "pty must be a boolean"}

      not is_boolean(Map.get(params, "run_in_background", false)) ->
        {:error, "run_in_background must be a boolean"}

      Map.get(params, "run_in_background", false) != true ->
        with {:ok, timeout_ms} <- resolve_timeout(params, opts) do
          run_foreground(command, use_pty, timeout_ms, signal, on_update, cwd, opts)
        end

      use_pty == true ->
        {:error, "pty is not supported with run_in_background"}

      true ->
        run_in_background(command, cwd, opts)
    end
  end

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

  defp run_foreground(command, use_pty, timeout_ms, signal, on_update, cwd, opts) do
    # Set up streaming callback if on_update is provided
    {accumulator_pid, streaming_callback} = build_streaming_callback(on_update)

    executor_opts =
      [
        on_chunk: streaming_callback,
        signal: signal,
        timeout: timeout_ms,
        pty: use_pty
      ]

    executor =
      if Keyword.get(opts, :acp_client_terminal) == true and not use_pty,
        do: CodingAgent.ACPTerminalExecutor,
        else: BashExecutor

    executor_opts =
      executor_opts
      |> Keyword.put(:run_id, Keyword.get(opts, :run_id))
      |> Keyword.put(:on_terminal, fn id ->
        if is_function(on_update, 1) do
          on_update.(%AgentToolResult{content: [], details: %{terminalId: id}})
        end
      end)

    try do
      case executor.execute(command, cwd, executor_opts) do
        {:ok, result} ->
          format_result(result, timeout_ms)

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

  defp run_in_background(command, cwd, opts) do
    exec_opts = [
      command: command,
      cwd: cwd,
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
        {:error,
         "Launch outcome unknown for #{process_id}. Reconcile with bash_output; " <>
           "do not automatically rerun the command."}

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

  defp format_result(%BashExecutor.Result{} = result, timeout_ms) do
    cond do
      result.timed_out ->
        output = output_with_spill(result)

        notice =
          "Command timed out after #{timeout_ms} ms and was killed. Pass a larger timeout " <>
            "(max #{@max_timeout_ms} ms) or use run_in_background: true."

        text = if output != "", do: "#{output}\n\n#{notice}", else: notice

        %AgentToolResult{
          content: [%TextContent{text: text}],
          details: result |> build_details() |> Map.put(:timed_out, true),
          is_error: true
        }

      result.cancelled ->
        # Cancelled via abort signal
        output = output_with_spill(result)

        output_text =
          if output != "", do: "Command cancelled.\n\n#{output}", else: "Command cancelled."

        %AgentToolResult{
          content: [%TextContent{text: output_text}],
          details: build_details(result),
          is_error: true
        }

      result.exit_code == 0 ->
        text = output_with_spill(result)

        %AgentToolResult{
          content: [%TextContent{text: text}],
          details: build_details(result)
        }

      true ->
        output = output_with_spill(result)

        text =
          if output != "",
            do: "#{output}\n\nCommand exited with code #{result.exit_code}",
            else: "Command exited with code #{result.exit_code}"

        %AgentToolResult{
          content: [%TextContent{text: text}],
          details: build_details(result),
          is_error: true
        }
    end
  end

  defp output_with_spill(result) do
    output = result.output || ""

    cond do
      result.truncated && result.full_output_path ->
        "#{output}\n\n[Full output saved to: #{result.full_output_path}. Use read with offset/limit to retrieve it.]"

      result.client_output_truncated ->
        "#{output}\n\n[The ACP client discarded earlier terminal output; only its retained output tail is available.]"

      true ->
        output
    end
  end

  defp build_details(%BashExecutor.Result{} = result) do
    details = %{
      exit_code: result.exit_code,
      truncated: result.truncated
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
