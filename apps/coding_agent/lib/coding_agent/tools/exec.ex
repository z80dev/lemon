defmodule CodingAgent.Tools.Exec do
  @moduledoc """
  Exec tool for running background processes with poll/kill/write capabilities.

  Similar to the bash tool but designed for long-running background processes
  that can be polled, killed, and written to after starting.

  Features:
  - Background execution with process_id tracking
  - yield_ms option to auto-background after specified time
  - Integration with ProcessManager for durability
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent
  alias CodingAgent.ProcessManager
  alias CodingAgent.Tools.ExecSecurity

  @doc """
  Returns the exec tool definition.

  ## Parameters

    * `cwd` - The working directory for command execution
    * `opts` - Optional keyword list of options
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "exec",
      description: build_description(),
      label: "Execute Background Process",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "The command to execute"
          },
          "cwd" => %{
            "type" => "string",
            "description" => "Working directory (optional, defaults to project root)"
          },
          "yield_ms" => %{
            "type" => "integer",
            "description" => "Auto-background after this many milliseconds (optional)"
          },
          "background" => %{
            "type" => "boolean",
            "description" => "Run in background immediately (optional, default: false)"
          },
          "env" => %{
            "type" => "object",
            "description" => "Environment variables as key-value pairs (optional)"
          },
          "max_log_lines" => %{
            "type" => "integer",
            "description" => "Maximum log lines to keep (default: 1000)"
          }
        },
        "required" => ["command"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Execute the exec tool.

  ## Parameters

    * `tool_call_id` - Unique identifier for this tool invocation
    * `params` - Map containing command and options
    * `signal` - Abort signal reference for cancellation
    * `on_update` - Callback function for streaming partial results
    * `cwd` - Working directory for command execution
    * `opts` - Additional options
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, default_cwd, _opts) do
    if AbortSignal.aborted?(signal) do
      %AgentToolResult{
        content: [%TextContent{text: "Command cancelled."}]
      }
    else
      do_execute(params, default_cwd)
    end
  end

  defp do_execute(params, default_cwd) do
    command = Map.fetch!(params, "command")
    cwd = Map.get(params, "cwd", default_cwd)
    yield_ms = Map.get(params, "yield_ms")
    background? = Map.get(params, "background", false)
    env = Map.get(params, "env", %{})
    max_log_lines = Map.get(params, "max_log_lines", 1000)

    # Reject obfuscated commands before execution
    case ExecSecurity.check(command) do
      {:obfuscated, technique} ->
        %AgentToolResult{
          content: [%TextContent{text: ExecSecurity.rejection_message(technique)}],
          details: %{error: :obfuscated_command}
        }

      :ok ->
        do_execute_validated(command, cwd, yield_ms, background?, env, max_log_lines)
    end
  end

  defp do_execute_validated(command, cwd, yield_ms, background?, env, max_log_lines) do
    # Validate parameters
    with :ok <- validate_command(command),
         :ok <- validate_yield_ms(yield_ms) do
      exec_opts = [
        command: command,
        cwd: cwd,
        env: env,
        max_log_lines: max_log_lines
      ]

      cond do
        background? or yield_ms != nil ->
          # Start in background
          case ProcessManager.exec(exec_opts) do
            {:ok, process_id} ->
              build_background_result(process_id, command, yield_ms)

            {:error, reason} ->
              {:error, "Failed to start process: #{inspect(reason)}"}
          end

        true ->
          # Run synchronously
          case ProcessManager.exec_sync(exec_opts) do
            {:ok, result} ->
              build_sync_result(result)

            {:error, reason} ->
              {:error, "Command failed: #{inspect(reason)}"}
          end
      end
    end
  end

  defp validate_command(command) when is_binary(command) do
    trimmed = String.trim(command)

    if trimmed == "" do
      {:error, "Command cannot be empty"}
    else
      :ok
    end
  end

  defp validate_command(_), do: {:error, "Command must be a string"}

  defp validate_yield_ms(nil), do: :ok

  defp validate_yield_ms(yield_ms) when is_integer(yield_ms) and yield_ms >= 0 do
    if yield_ms > 3_600_000 do
      {:error, "yield_ms cannot exceed 1 hour (3600000ms)"}
    else
      :ok
    end
  end

  defp validate_yield_ms(_), do: {:error, "yield_ms must be a non-negative integer"}

  defp build_background_result(process_id, command, yield_ms) do
    text =
      if yield_ms do
        "Process started in background after #{yield_ms}ms: #{command}"
      else
        "Process started in background: #{command}"
      end

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{
        process_id: process_id,
        status: "running",
        command: command,
        background: true
      }
    }
  end

  defp build_sync_result(result) do
    logs = Enum.join(result.logs, "\n")

    status = result.status
    exit_code = result.exit_code

    {text, status_str} =
      cond do
        status == :completed and exit_code == 0 ->
          {logs, "completed"}

        status == :completed ->
          {"#{logs}\n\n[Exited with code #{exit_code}]", "completed"}

        status == :error ->
          {"#{logs}\n\n[Error: exit code #{exit_code}]", "error"}

        status == :killed ->
          {"#{logs}\n\n[Process killed]", "killed"}

        true ->
          {logs, to_string(status)}
      end

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{
        process_id: result.process_id,
        status: status_str,
        exit_code: exit_code,
        command: result.command,
        background: false
      }
    }
  end

  defp build_description do
    """
    Execute a shell command as a background process with poll/kill/write capabilities.

    This tool is similar to 'bash' but designed for long-running processes that need
    to be monitored or controlled after starting.

    Parameters:
    - command: The shell command to execute (required)
    - cwd: Working directory (optional, defaults to project root)
    - yield_ms: Return immediately after this many milliseconds, leaving process running (optional)
    - background: Start in background immediately without waiting (optional, default: false)
    - env: Environment variables as key-value pairs (optional)
    - max_log_lines: Maximum log lines to keep (default: 1000)

    Use the 'process' tool to poll status, get logs, write to stdin, or kill the process.
    """
  end
end
