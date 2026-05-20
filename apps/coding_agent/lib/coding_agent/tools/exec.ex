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
  alias CodingAgent.ToolExecutor
  alias CodingAgent.Tools.CheckpointGuard
  alias LemonCore.{TerminalBackendPolicy, TerminalBackends}

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
          "backend" => %{
            "type" => "string",
            "enum" => ["local", "local_pty", "docker", "ssh"],
            "description" => "Terminal backend to use (default: local)"
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
          },
          "checkpoint_paths" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "Files to snapshot before risky shell commands when filesystem checkpoints are enabled"
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
  def execute(_tool_call_id, params, signal, _on_update, default_cwd, opts) do
    if AbortSignal.aborted?(signal) do
      %AgentToolResult{
        content: [%TextContent{text: "Command cancelled."}]
      }
    else
      do_execute(params, default_cwd, opts)
    end
  end

  defp do_execute(params, default_cwd, opts) do
    command = Map.fetch!(params, "command")
    backend = Map.get(params, "backend", "local")
    cwd = Map.get(params, "cwd", default_cwd)
    yield_ms = Map.get(params, "yield_ms")
    background? = Map.get(params, "background", false)
    env = Map.get(params, "env", %{})
    max_log_lines = Map.get(params, "max_log_lines", 1000)

    checkpoint_paths =
      Map.get(params, "checkpoint_paths", Keyword.get(opts, :risky_shell_checkpoint_paths, []))

    # Validate parameters
    with :ok <- validate_command(command),
         {:ok, backend} <- validate_backend(backend),
         :ok <- validate_yield_ms(yield_ms),
         :ok <- validate_env(env),
         {:ok, checkpoint_paths} <- validate_checkpoint_paths(checkpoint_paths) do
      exec_opts = [
        command: command,
        backend: backend,
        cwd: cwd,
        env: env,
        max_log_lines: max_log_lines
      ]

      maybe_with_backend_approval(backend, command, cwd, env, opts, fn ->
        with {:ok, checkpoint} <-
               maybe_checkpoint_risky_shell(command, checkpoint_paths, cwd, backend, opts) do
          run_process(exec_opts, background?, yield_ms, command, backend, checkpoint)
        end
      end)
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

  defp validate_env(env) when is_map(env) do
    Enum.reduce_while(env, :ok, fn
      {key, value}, :ok when is_binary(key) and is_binary(value) ->
        if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, key) do
          {:cont, :ok}
        else
          {:halt, {:error, "env keys must be valid environment variable names"}}
        end

      {_key, _value}, :ok ->
        {:halt, {:error, "env keys and values must be strings"}}
    end)
  end

  defp validate_env(_), do: {:error, "env must be an object"}

  defp validate_checkpoint_paths(paths) when is_list(paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn
      path, {:ok, acc} when is_binary(path) ->
        case String.trim(path) do
          "" -> {:halt, {:error, "checkpoint_paths entries must be non-empty strings"}}
          trimmed -> {:cont, {:ok, [trimmed | acc]}}
        end

      _path, {:ok, _acc} ->
        {:halt, {:error, "checkpoint_paths must be a list of strings"}}
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      error -> error
    end
  end

  defp validate_checkpoint_paths(_), do: {:error, "checkpoint_paths must be a list of strings"}

  defp validate_backend(backend) do
    case TerminalBackends.validate(backend) do
      {:ok, backend} ->
        cond do
          not TerminalBackends.available?(backend) ->
            {:error, "Terminal backend unavailable: #{inspect(backend)}"}

          TerminalBackendPolicy.validate(backend) != :ok ->
            {:error, "Terminal backend blocked by policy: #{inspect(backend)}"}

          true ->
            {:ok, backend}
        end

      {:error, :unknown_backend} ->
        {:error, "Unknown terminal backend: #{inspect(backend)}"}
    end
  end

  defp maybe_with_backend_approval(backend, command, cwd, env, opts, run_fun) do
    if TerminalBackendPolicy.requires_approval?(backend) do
      case Keyword.get(opts, :approval_context) do
        nil ->
          {:error,
           "Terminal backend requires approval but no approval context is available: #{inspect(backend)}"}

        approval_context ->
          ToolExecutor.execute_with_approval(
            "exec",
            approval_action(backend, command, cwd, env),
            run_fun,
            approval_context
          )
      end
    else
      run_fun.()
    end
  end

  defp approval_action(backend, command, cwd, env) do
    %{
      "cmd" => "terminal backend #{backend} command #{short_hash(command)}",
      "backend" => Atom.to_string(backend),
      "commandHash" => short_hash(command),
      "cwdHash" => short_hash(cwd || ""),
      "envKeys" => env |> Map.keys() |> Enum.sort()
    }
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp maybe_checkpoint_risky_shell(_command, [], _cwd, _backend, _opts), do: {:ok, nil}

  defp maybe_checkpoint_risky_shell(command, paths, cwd, backend, opts) do
    if risky_shell_command?(command) or Keyword.get(opts, :checkpoint_all_shell_mutations, false) do
      CheckpointGuard.before_mutation(paths, cwd, opts, %{
        tool: "exec",
        action: "risky_shell",
        backend: Atom.to_string(backend),
        command_hash: short_hash(command)
      })
    else
      {:ok, nil}
    end
  end

  defp risky_shell_command?(command) do
    Regex.match?(
      ~r/(^|[;&|()\s])(?:rm|rmdir|mv|cp|dd|truncate|chmod|chown|sed\s+-i|perl\s+-pi|find\b.*\s-delete|git\s+(?:reset|clean|checkout|restore)\b)/,
      command
    )
  end

  defp run_process(exec_opts, background?, yield_ms, command, backend, checkpoint) do
    cond do
      background? or yield_ms != nil ->
        # Start in background
        case ProcessManager.exec(exec_opts) do
          {:ok, process_id} ->
            build_background_result(process_id, command, yield_ms, backend, checkpoint)

          {:error, reason} ->
            {:error, "Failed to start process: #{inspect(reason)}"}
        end

      true ->
        # Run synchronously
        case ProcessManager.exec_sync(exec_opts) do
          {:ok, result} ->
            build_sync_result(result, checkpoint)

          {:error, reason} ->
            {:error, "Command failed: #{inspect(reason)}"}
        end
    end
  end

  defp build_background_result(process_id, command, yield_ms, backend, checkpoint) do
    text =
      if yield_ms do
        "Process started in background after #{yield_ms}ms: #{command}"
      else
        "Process started in background: #{command}"
      end

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details:
        %{
          process_id: process_id,
          status: "running",
          command: command,
          backend: backend,
          background: true
        }
        |> CheckpointGuard.put_details(checkpoint)
        |> maybe_put_checkpoint_trigger(checkpoint)
    }
  end

  defp build_sync_result(result, checkpoint) do
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
      details:
        %{
          process_id: result.process_id,
          status: status_str,
          exit_code: exit_code,
          command: result.command,
          backend: Map.get(result, :backend, :local),
          background: false
        }
        |> CheckpointGuard.put_details(checkpoint)
        |> maybe_put_checkpoint_trigger(checkpoint)
    }
  end

  defp maybe_put_checkpoint_trigger(details, nil), do: details

  defp maybe_put_checkpoint_trigger(details, _checkpoint),
    do: Map.put(details, :checkpoint_trigger, "risky_shell")

  defp build_description do
    """
    Execute a shell command as a background process with poll/kill/write capabilities.

    This tool is similar to 'bash' but designed for long-running processes that need
    to be monitored or controlled after starting.

    Parameters:
    - command: The shell command to execute (required)
    - backend: Terminal backend to use (local, local_pty, docker, or ssh)
    - cwd: Working directory (optional, defaults to project root)
    - yield_ms: Return immediately after this many milliseconds, leaving process running (optional)
    - background: Start in background immediately without waiting (optional, default: false)
    - env: Environment variables as key-value pairs (optional)
    - max_log_lines: Maximum log lines to keep (default: 1000)
    - checkpoint_paths: files to snapshot before risky shell commands when filesystem checkpoints are enabled

    Use the 'process' tool to poll status, get logs, write to stdin, or kill the process.
    """
  end
end
