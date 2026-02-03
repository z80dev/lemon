defmodule CodingAgent.Tools.Process do
  @moduledoc """
  Process tool for managing background processes started with the exec tool.

  Actions:
  - list: List all processes with optional status filter
  - poll: Get status and recent logs for a process
  - log: Get logs for a process (alias for poll with focus on logs)
  - write: Write to a process's stdin
  - kill: Kill a running process
  - clear: Remove a completed process from the store

  This tool provides the control interface for processes started via exec.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent
  alias CodingAgent.ProcessManager

  @valid_actions ["list", "poll", "log", "write", "kill", "clear"]

  @doc """
  Returns the process tool definition.
  """
  @spec tool(opts :: keyword()) :: AgentTool.t()
  def tool(_opts \\ []) do
    %AgentTool{
      name: "process",
      description: build_description(),
      label: "Manage Background Process",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => @valid_actions,
            "description" => "Action to perform: list, poll, log, write, kill, or clear"
          },
          "process_id" => %{
            "type" => "string",
            "description" => "Process ID (required for poll, log, write, kill, clear)"
          },
          "status" => %{
            "type" => "string",
            "enum" => ["all", "running", "completed", "error", "killed", "lost"],
            "description" => "Status filter for list action (default: all)"
          },
          "lines" => %{
            "type" => "integer",
            "description" => "Number of log lines to return (default: 100)"
          },
          "data" => %{
            "type" => "string",
            "description" => "Data to write to stdin (required for write action)"
          },
          "signal" => %{
            "type" => "string",
            "enum" => ["sigterm", "sigkill"],
            "description" => "Signal to send when killing (default: sigterm)"
          }
        },
        "required" => ["action"]
      },
      execute: &execute(&1, &2, &3, &4)
    }
  end

  @doc """
  Execute the process tool.
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update) do
    if AbortSignal.aborted?(signal) do
      %AgentToolResult{
        content: [%TextContent{text: "Operation cancelled."}]
      }
    else
      do_execute(params)
    end
  end

  defp do_execute(params) do
    action = Map.get(params, "action", "list")

    case action do
      "list" -> do_list(params)
      "poll" -> do_poll(params)
      "log" -> do_log(params)
      "write" -> do_write(params)
      "kill" -> do_kill(params)
      "clear" -> do_clear(params)
      _ -> {:error, "Unknown action: #{action}"}
    end
  end

  defp do_list(params) do
    status_filter = Map.get(params, "status", "all")

    status_atom =
      case status_filter do
        "running" -> :running
        "completed" -> :completed
        "error" -> :error
        "killed" -> :killed
        "lost" -> :lost
        _ -> :all
      end

    processes = ProcessManager.list(status: status_atom)

    items =
      Enum.map(processes, fn {process_id, record} ->
        %{
          process_id: process_id,
          status: record.status,
          command: record.command,
          cwd: record.cwd,
          exit_code: record.exit_code,
          os_pid: record.os_pid,
          started_at: record.started_at,
          completed_at: record.completed_at
        }
      end)

    text = format_process_list(items)

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{
        action: "list",
        count: length(items),
        processes: items
      }
    }
  end

  defp do_poll(params) do
    with {:ok, process_id} <- get_process_id(params) do
      line_count = Map.get(params, "lines", 100)

      case ProcessManager.poll(process_id, lines: line_count) do
        {:ok, result} ->
          text = format_poll_result(result)

          %AgentToolResult{
            content: [%TextContent{text: text}],
            details: %{
              action: "poll",
              process_id: process_id,
              status: result.status,
              exit_code: result.exit_code,
              os_pid: result.os_pid,
              command: result.command,
              logs: result.logs
            }
          }

        {:error, :not_found} ->
          {:error, "Process not found: #{process_id}"}

        {:error, reason} ->
          {:error, "Failed to poll process: #{inspect(reason)}"}
      end
    end
  end

  defp do_log(params) do
    # log is essentially poll focused on logs
    with {:ok, process_id} <- get_process_id(params) do
      line_count = Map.get(params, "lines", 100)

      case ProcessManager.logs(process_id, lines: line_count) do
        {:ok, logs} ->
          text = if logs == [], do: "[No logs]", else: Enum.join(logs, "\n")

          %AgentToolResult{
            content: [%TextContent{text: text}],
            details: %{
              action: "log",
              process_id: process_id,
              line_count: length(logs)
            }
          }

        {:error, :not_found} ->
          {:error, "Process not found: #{process_id}"}

        {:error, reason} ->
          {:error, "Failed to get logs: #{inspect(reason)}"}
      end
    end
  end

  defp do_write(params) do
    with {:ok, process_id} <- get_process_id(params),
         {:ok, data} <- get_write_data(params) do
      case ProcessManager.write(process_id, data) do
        :ok ->
          %AgentToolResult{
            content: [%TextContent{text: "Data written to process stdin."}],
            details: %{
              action: "write",
              process_id: process_id,
              bytes_written: byte_size(data)
            }
          }

        {:error, :process_not_running} ->
          {:error, "Process is not running: #{process_id}"}

        {:error, reason} ->
          {:error, "Failed to write to process: #{inspect(reason)}"}
      end
    end
  end

  defp do_kill(params) do
    with {:ok, process_id} <- get_process_id(params) do
      signal =
        case Map.get(params, "signal", "sigterm") do
          "sigkill" -> :sigkill
          _ -> :sigterm
        end

      case ProcessManager.kill(process_id, signal) do
        :ok ->
          signal_str = if signal == :sigkill, do: "SIGKILL", else: "SIGTERM"

          %AgentToolResult{
            content: [%TextContent{text: "Process #{process_id} killed with #{signal_str}."}],
            details: %{
              action: "kill",
              process_id: process_id,
              signal: signal_str
            }
          }

        {:error, :process_not_running} ->
          {:error, "Process is not running: #{process_id}"}

        {:error, :not_found} ->
          {:error, "Process not found: #{process_id}"}

        {:error, reason} ->
          {:error, "Failed to kill process: #{inspect(reason)}"}
      end
    end
  end

  defp do_clear(params) do
    with {:ok, process_id} <- get_process_id(params) do
      case ProcessManager.clear(process_id) do
        :ok ->
          %AgentToolResult{
            content: [%TextContent{text: "Process #{process_id} cleared."}],
            details: %{
              action: "clear",
              process_id: process_id
            }
          }

        {:error, :not_found} ->
          {:error, "Process not found: #{process_id}"}

        {:error, reason} ->
          {:error, "Failed to clear process: #{inspect(reason)}"}
      end
    end
  end

  # Helper functions

  defp get_process_id(params) do
    case Map.get(params, "process_id") do
      nil -> {:error, "process_id is required for this action"}
      "" -> {:error, "process_id cannot be empty"}
      process_id when is_binary(process_id) -> {:ok, process_id}
      _ -> {:error, "process_id must be a string"}
    end
  end

  defp get_write_data(params) do
    case Map.get(params, "data") do
      nil -> {:error, "data is required for write action"}
      data when is_binary(data) -> {:ok, data}
      _ -> {:error, "data must be a string"}
    end
  end

  defp format_process_list([]) do
    "No processes found."
  end

  defp format_process_list(processes) do
    header = "Processes:\n\n"

    lines =
      Enum.map(processes, fn p ->
        status = p.status |> to_string() |> String.upcase()
        cmd = String.slice(p.command || "", 0, 50)
        cmd = if String.length(p.command || "") > 50, do: cmd <> "...", else: cmd

        "#{p.process_id} [#{status}] #{cmd}"
      end)

    header <> Enum.join(lines, "\n")
  end

  defp format_poll_result(result) do
    status = result.status |> to_string() |> String.upcase()

    header = "Process: #{result.process_id}\nStatus: #{status}\n"

    header =
      if result.exit_code do
        header <> "Exit Code: #{result.exit_code}\n"
      else
        header
      end

    header =
      if result.os_pid do
        header <> "OS PID: #{result.os_pid}\n"
      else
        header
      end

    header = header <> "Command: #{result.command}\n\n"

    logs = if result.logs == [], do: "[No output yet]", else: Enum.join(result.logs, "\n")

    header <> "Output:\n" <> logs
  end

  defp build_description do
    """
    Manage background processes started with the exec tool.

    Actions:
    - list: List all processes with optional status filter
    - poll: Get status and recent logs for a process
    - log: Get logs for a process (same as poll but focused on logs)
    - write: Write data to a process's stdin
    - kill: Kill a running process
    - clear: Remove a completed process from the store

    Parameters:
    - action: The action to perform (required)
    - process_id: Process ID (required for poll, log, write, kill, clear)
    - status: Status filter for list action (all, running, completed, error, killed, lost)
    - lines: Number of log lines to return (default: 100)
    - data: Data to write to stdin (required for write action)
    - signal: Signal for kill action (sigterm or sigkill, default: sigterm)
    """
  end
end
