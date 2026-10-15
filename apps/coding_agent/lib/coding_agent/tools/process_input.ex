defmodule CodingAgent.Tools.ProcessInput do
  @moduledoc """
  Write exact bytes to a session-owned background process, optionally closing stdin.
  No newline is appended; callers must include `\n` when the program expects a line.
  """

  alias CodingAgent.ProcessManager
  alias CodingAgent.Tools.BashOutput
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "process_input",
      label: "Write Process Input",
      description:
        "Write input to a running background process. Nothing is appended: include \\n explicitly for a line. Set eof: true to close stdin after writing while continuing to collect output.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "process_id" => %{
            "type" => "string",
            "description" => "Background process ID returned by bash"
          },
          "input" => %{
            "type" => "string",
            "description" => "Exact input bytes; no implicit newline"
          },
          "eof" => %{
            "type" => "boolean",
            "description" => "Close stdin after writing (default false)"
          }
        },
        "required" => ["process_id", "input"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  def execute(_id, params, _signal, _on_update, _cwd, opts) do
    with {:ok, process_id} <- BashOutput.fetch_process_id(params),
         :ok <- BashOutput.authorize(process_id, opts),
         {:ok, input, eof} <- fetch_input(params) do
      case ProcessManager.write(process_id, input, eof: eof) do
        :ok ->
          %AgentToolResult{
            content: [
              %TextContent{
                text:
                  "Wrote #{byte_size(input)} bytes to background process #{process_id}." <>
                    if(eof, do: " Stdin closed.", else: "")
              }
            ],
            details: %{process_id: process_id, bytes_written: byte_size(input), eof: eof}
          }

        {:error, :process_not_running} ->
          {:error, "Process #{process_id} is not running."}

        {:error, :stdin_closed} ->
          {:error, "Stdin for process #{process_id} is already closed."}

        {:error, reason} ->
          {:error, "Failed to write process input: #{inspect(reason)}"}
      end
    end
  end

  defp fetch_input(params) do
    input = Map.get(params, "input")
    eof = Map.get(params, "eof", false)

    cond do
      not is_binary(input) -> {:error, "input must be a string"}
      not is_boolean(eof) -> {:error, "eof must be a boolean"}
      true -> {:ok, input, eof}
    end
  end
end
