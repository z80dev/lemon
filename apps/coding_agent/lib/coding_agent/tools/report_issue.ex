defmodule CodingAgent.Tools.ReportIssue do
  @moduledoc "Appends short tool-misbehavior notes to a bounded, private session JSONL log."

  alias CodingAgent.{Artifacts, MutationLock}
  alias CodingAgent.Tools.FileValidation
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @max_bytes 1_048_576
  @max_note_bytes 4096

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
      path = Path.join(directory, "tool-issues.jsonl")

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
             :ok <- append(path, line, limit) do
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

  defp append(path, line, limit) when is_integer(limit) and limit >= byte_size(line) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, previous, size} <- recent_bytes(path, limit) do
      if size + byte_size(line) <= limit do
        write_private(path, line, [:append, :binary])
      else
        retained = tail_lines(previous, limit - byte_size(line))
        temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

        try do
          with :ok <- write_private(temporary, retained <> line, [:write, :binary, :exclusive]),
               :ok <- File.rename(temporary, path),
               do: :ok
        after
          File.rm(temporary)
        end
      end
    end
  end

  defp append(_path, _line, _limit), do: {:error, "Issue record exceeds the log byte limit"}

  defp recent_bytes(path, limit) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        offset = max(size - limit, 0)

        case File.open(path, [:read, :binary], &:file.pread(&1, offset, limit)) do
          {:ok, {:ok, bytes}} ->
            {:ok, if(offset == 0, do: bytes, else: drop_partial(bytes)), size}

          {:ok, :eof} ->
            {:ok, "", size}

          {:ok, error} ->
            error

          error ->
            error
        end

      {:error, :enoent} ->
        {:ok, "", 0}

      error ->
        error
    end
  end

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

  defp write_private(path, bytes, modes) do
    case File.open(path, modes, fn file ->
           with :ok <- File.chmod(path, 0o600), do: IO.binwrite(file, bytes)
         end) do
      {:ok, result} -> result
      error -> error
    end
  end
end
