defmodule CodingAgent.Tools.BashOutput do
  @moduledoc """
  `bash_output` tool: read new output from a background process started by
  `bash` with `run_in_background: true`.

  Each call returns only the complete output lines produced since the
  previous call for that process, followed by its status and exit code. A
  session can only read processes it started. Truncated or dropped output includes
  the saved output file path; use `read` with line ranges to retrieve it. The
  saved file holds the head of the output up to the capture limit; when that
  limit was reached, the result says so and `details.output` reports received,
  retained and discarded bytes (see `CodingAgent.ProcessSession`).
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAi.Types.TextContent
  alias CodingAgent.BashExecutor
  alias CodingAgent.ProcessManager

  @max_output_bytes 50_000

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "bash_output",
      description:
        "Read new output from a background process started with bash run_in_background. " <>
          "Returns only the output produced since the last bash_output call for that process, " <>
          "plus its status (running, completed, error, killed) and exit code.",
      label: "Read Process Output",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "process_id" => %{
            "type" => "string",
            "description" => "The process_id returned by bash with run_in_background"
          }
        },
        "required" => ["process_id"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, _signal, _on_update, cwd, opts) do
    with {:ok, process_id} <- fetch_process_id(params),
         :ok <- authorize(process_id, opts),
         {:ok, output} <- read(process_id) do
      output
      |> format_output()
      |> CodingAgent.Artifacts.attach(cwd, opts)
      |> ToolResultTrust.untrusted(:shell)
    end
  end

  @doc false
  @spec fetch_process_id(map()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch_process_id(%{"process_id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  def fetch_process_id(_params), do: {:error, "process_id is required"}

  @doc false
  @spec authorize(String.t(), keyword()) :: :ok | {:error, String.t()}
  def authorize(process_id, opts) do
    case ProcessManager.check_owner(process_id, Keyword.get(opts, :session_id)) do
      :ok -> :ok
      {:error, :not_found} -> {:error, "No background process with id #{process_id}"}
    end
  end

  @doc false
  @spec describe_status(atom() | nil, integer() | nil) :: String.t()
  def describe_status(status, nil), do: to_string(status || :unknown)
  def describe_status(status, exit_code), do: "#{status} (exit code #{exit_code})"

  defp read(process_id) do
    case ProcessManager.read_output(process_id) do
      {:ok, output} -> {:ok, output}
      {:error, :not_found} -> {:error, "No background process with id #{process_id}"}
      {:error, reason} -> {:error, "Failed to read process output: #{inspect(reason)}"}
    end
  end

  defp format_output(output) do
    raw = Enum.join(output.lines, "\n")
    sanitized = BashExecutor.sanitize_output(raw)

    {text, truncated?, _info} =
      BashExecutor.truncate_tail(sanitized, max_bytes: @max_output_bytes)

    dropped_note =
      if output.dropped_lines > 0,
        do: "[#{output.dropped_lines} earlier lines were dropped from the log buffer]\n",
        else: ""

    body = if text == "", do: "(no new output)", else: text
    status_line = "Status: #{describe_status(output.status, output.exit_code)}"
    full_output_path = Map.get(output, :full_output_path)
    stats = Map.get(output, :output) || %{}
    artifact_truncated? = Map.get(stats, :artifact_truncated, false)

    spill_note =
      spill_note(
        truncated? or output.dropped_lines > 0 or artifact_truncated? or
          Map.get(stats, :artifact_reclaimed, false),
        full_output_path,
        stats
      )

    %AgentToolResult{
      content: [%TextContent{text: dropped_note <> body <> "\n\n" <> status_line <> spill_note}],
      details: %{
        process_id: output.process_id,
        status: output.status,
        exit_code: output.exit_code,
        new_lines: length(output.lines),
        dropped_lines: output.dropped_lines,
        full_output_path: full_output_path,
        truncated: truncated?,
        artifact_truncated: artifact_truncated?,
        output: Map.get(output, :output)
      }
    }
  end

  defp spill_note(false, _path, _stats), do: ""

  defp spill_note(true, path, %{artifact_reclaimed: true}) when not is_binary(path),
    do:
      "\n\n[Earlier output is no longer saved: its file was reclaimed to stay within " <>
        "the background-process output storage quota.]"

  defp spill_note(true, path, _stats) when not is_binary(path), do: ""

  defp spill_note(true, path, %{artifact_truncated: true} = stats) do
    stopped =
      case stats[:artifact_error] do
        nil -> "the capture limit was reached"
        reason -> "saving failed (#{reason})"
      end

    saved =
      if stats[:artifact_size_unknown],
        do:
          "at least #{stats[:artifact_bytes]} bytes were confirmed saved (the file size could not be checked)",
        else:
          "only the first #{stats[:artifact_bytes]} of #{stats[:received_bytes]} bytes were saved"

    "\n\n[Saved output is incomplete: #{stopped}; #{saved} to: #{path}. " <>
      "Later output was not saved; only the most recent lines are kept. " <>
      "Use read with offset/limit to retrieve the saved part.]"
  end

  defp spill_note(true, path, _stats),
    do: "\n\n[Full output saved to: #{path}. Use read with offset/limit to retrieve it.]"
end
