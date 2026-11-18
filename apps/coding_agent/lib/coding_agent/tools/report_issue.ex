defmodule CodingAgent.Tools.ReportIssue do
  @moduledoc """
  Appends short tool-misbehavior notes to a bounded, private session JSONL log.

  The log is `tool-issues.jsonl` directly in the session spill directory
  (`CodingAgent.Artifacts.spill_dir/2`: the configured guardrail spill
  directory or `CodingAgent.Config.spill_dir/2` under the agent's sessions
  tree, not a model-chosen path). That directory is the trusted root: the log is
  read, appended, created (0600) and rotated only through a `LemonCore.ConfinedFS`
  descriptor on it, never following a symlink, so an entry swapped for a symlink
  after validation is refused. A log already larger than the byte limit (written
  by something else) is replaced by the new record alone.
  """

  alias CodingAgent.{Artifacts, MutationLock}
  alias LemonCore.ConfinedFS
  alias CodingAgent.Tools.FileValidation
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @max_bytes 1_048_576
  @max_note_bytes 4096
  @log "tool-issues.jsonl"
  @private [mode: 0o600, exact_mode: true]

  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "report_issue",
      label: "Report Tool Issue",
      description:
        "Record a short plain-text note about tool misbehavior locally. Do not include secrets or full tool arguments/results. No network request is made.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "note" => %{
            "type" => "string",
            "description" =>
              "Short plain-text description of observed tool misbehavior (up to 4096 UTF-8 bytes)"
          },
          "tool" => %{
            "type" => "string",
            "description" => "Name of the misbehaving tool, if known"
          }
        },
        "required" => ["note"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  def execute(_id, params, signal, _update, cwd, opts) do
    with :ok <- check_abort(signal),
         {:ok, note} <- text(params["note"], "note", @max_note_bytes),
         {:ok, tool} <- optional_tool(params["tool"]),
         {:ok, directory} <- Artifacts.spill_dir(cwd, opts) do
      path = Path.join(directory, @log)

      record = %{
        note: note,
        tool: tool,
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        session_id: opts[:session_id]
      }

      line = Jason.encode!(record) <> "\n"
      limit = Keyword.get(opts, :report_issue_max_bytes, @max_bytes)

      MutationLock.with_lock(MutationLock.path_key(path), fn ->
        with :ok <- check_abort(signal),
             :ok <- FileValidation.check_mutation_target(path, mutation_root: directory),
             :ok <- File.mkdir_p(directory),
             :ok <- append(directory, path, line, limit) do
          %AgentToolResult{
            content: [%TextContent{text: "Tool issue recorded locally."}],
            details: %{path: path}
          }
        end
      end)
    end
  end

  defp optional_tool(nil), do: {:ok, nil}
  defp optional_tool(tool), do: text(tool, "tool", 128)

  defp text(value, label, limit) when is_binary(value) do
    with :ok <- FileValidation.check_text_content(value, label) do
      if String.trim(value) != "" and byte_size(value) <= limit,
        do: {:ok, value},
        else: {:error, "#{label} must be non-empty and at most #{limit} UTF-8 bytes"}
    end
  end

  defp text(_value, label, _limit), do: {:error, "#{label} must be a string"}

  defp check_abort(signal),
    do: if(AbortSignal.aborted?(signal), do: {:error, :aborted}, else: :ok)

  defp append(directory, path, line, limit) when is_integer(limit) and limit >= byte_size(line) do
    ConfinedFS.with_root(directory, fn fs ->
      case ConfinedFS.read(fs, :root, @log, limit) do
        {:ok, previous, stat} when byte_size(previous) + byte_size(line) <= limit ->
          ConfinedFS.append(fs, :root, @log, line, [expect: stat] ++ @private)

        {:ok, previous, stat} ->
          rotate(fs, tail_lines(previous, limit - byte_size(line)) <> line, stat)

        {:error, :enoent} ->
          ConfinedFS.append(fs, :root, @log, line, [create: true] ++ @private)

        {:error, :too_large} ->
          with {:ok, stat} <- ConfinedFS.stat(fs, :root, @log), do: rotate(fs, line, stat)

        error ->
          error
      end
    end)
    |> case do
      {:ok, _stat} -> :ok
      {:error, reason} when is_atom(reason) -> FileValidation.confined_error(reason, path)
      error -> error
    end
  end

  defp append(_directory, _path, _line, _limit),
    do: {:error, "Issue record exceeds the log byte limit"}

  defp rotate(fs, bytes, stat),
    do: ConfinedFS.replace(fs, :root, @log, bytes, [expect: stat] ++ @private)

  defp tail_lines(bytes, limit) do
    offset = max(byte_size(bytes) - limit, 0)
    tail = binary_part(bytes, offset, byte_size(bytes) - offset)
    if offset == 0, do: tail, else: drop_partial(tail)
  end

  defp drop_partial(bytes) do
    case :binary.match(bytes, "\n") do
      {offset, 1} -> binary_part(bytes, offset + 1, byte_size(bytes) - offset - 1)
      :nomatch -> ""
    end
  end
end
