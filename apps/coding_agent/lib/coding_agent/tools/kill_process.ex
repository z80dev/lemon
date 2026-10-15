defmodule CodingAgent.Tools.KillProcess do
  @moduledoc """
  `kill_process` tool: stop a background process started by `bash` with
  `run_in_background: true`. The whole process tree is killed. A session can
  only kill processes it started.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias CodingAgent.ProcessManager
  alias CodingAgent.Tools.BashOutput

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "kill_process",
      description:
        "Stop a background process and its children. Default term allows 2 seconds for cleanup before SIGKILL; kill sends SIGKILL immediately.",
      label: "Kill Process",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "process_id" => %{
            "type" => "string",
            "description" => "The process_id returned by bash with run_in_background"
          },
          "signal" => %{
            "type" => "string",
            "enum" => ["term", "kill"],
            "description" =>
              "term (default): SIGTERM then SIGKILL after 2 seconds; kill: immediate SIGKILL"
          }
        },
        "required" => ["process_id"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, _signal, _on_update, _cwd, opts) do
    with {:ok, process_id} <- BashOutput.fetch_process_id(params),
         :ok <- BashOutput.authorize(process_id, opts),
         {:ok, signal} <- fetch_signal(params) do
      kill(process_id, signal)
    end
  end

  defp fetch_signal(params) do
    case Map.get(params, "signal", "term") do
      "term" -> {:ok, :sigterm}
      "kill" -> {:ok, :sigkill}
      _ -> {:error, "signal must be term or kill"}
    end
  end

  defp kill(process_id, signal) do
    case ProcessManager.kill(process_id, signal) do
      :ok ->
        {status, exit_code} =
          case ProcessManager.poll(process_id, lines: 0) do
            {:ok, result} -> {result.status, result.exit_code}
            _ -> {:outcome_unknown, nil}
          end

        text =
          if status == :canceled,
            do: "Canceled queued launch #{process_id}; it will not start.",
            else:
              "Cancellation requested for background process #{process_id} (status: #{status})."

        %AgentToolResult{
          content: [%TextContent{text: text}],
          details: %{process_id: process_id, status: status, exit_code: exit_code}
        }

      {:error, :process_not_running} ->
        {:error, "Process #{process_id} is not running (status: #{current_status(process_id)})."}

      {:error, :not_found} ->
        {:error, "No background process with id #{process_id}"}

      {:error, reason} ->
        {:error, "Failed to kill process #{process_id}: #{inspect(reason)}"}
    end
  end

  defp current_status(process_id) do
    case ProcessManager.poll(process_id, lines: 0) do
      {:ok, %{status: status, exit_code: exit_code}} ->
        BashOutput.describe_status(status, exit_code)

      _ ->
        "unknown"
    end
  end
end
