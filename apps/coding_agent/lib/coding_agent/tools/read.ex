defmodule CodingAgent.Tools.Read do
  @moduledoc """
  Read file tool for the coding agent.

  Reads the contents of a file with support for:
  - Text files with line number formatting
  - Image files (returned as base64-encoded data)
  - Offset and limit parameters for partial reads
  - Automatic truncation for large files
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.{TextContent, ImageContent}

  @default_max_lines 2000
  @default_max_bytes 50 * 1024
  @workspace_bootstrap_fallback_files MapSet.new(["SOUL.md", "USER.md"])
  @daily_memory_path_regex Regex.compile!(
                             "(?:^|[\\\\/])memory[\\\\/](\\d{4}-\\d{2}-\\d{2})\\.md$"
                           )

  @doc """
  Returns the Read tool definition.

  ## Options

  - `:max_lines` - Maximum lines to return (default: 2000)
  - `:max_bytes` - Maximum bytes to return (default: 50KB)
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "read",
      description:
        "Read the contents of a file. For images, the contents will be returned as a base64-encoded data URL.",
      label: "Read File",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "The path to the file to read (relative to cwd or absolute)"
          },
          "offset" => %{
            "type" => "integer",
            "description" => "Line number to start reading from (1-indexed)"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of lines to read"
          }
        },
        "required" => ["path"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Execute the read tool.

  ## Parameters

  - `tool_call_id` - Unique identifier for this tool invocation
  - `params` - Parameters map with "path", optional "offset" and "limit"
  - `signal` - Abort signal for cancellation (can be nil)
  - `on_update` - Callback for streaming partial results (unused for read)
  - `cwd` - Current working directory
  - `opts` - Tool options

  ## Returns

  - `AgentToolResult.t()` - Result with file contents
  - `{:error, term()}` - Error if file cannot be read
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: function() | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(tool_call_id, params, signal, _on_update, cwd, opts) do
    _ = tool_call_id

    # Check for abort at start
    if aborted?(signal) do
      {:error, "Operation aborted"}
    else
      do_execute(params, signal, cwd, opts)
    end
  end

  defp do_execute(params, signal, cwd, opts) do
    path = Map.get(params, "path", "")
    offset = Map.get(params, "offset")
    limit = Map.get(params, "limit")

    with {:ok, resolved_path} <- resolve_path(path, cwd, opts),
         :ok <- check_abort(signal) do
      case resolve_existing_read_path(path, resolved_path, cwd, opts) do
        {:ok, readable_path, stat} ->
          case detect_mime_type(readable_path) do
            nil ->
              read_text_file(readable_path, stat, offset, limit, opts)

            mime_type ->
              read_image_file(readable_path, mime_type)
          end

        {:ok_optional_missing, readable_path} ->
          optional_missing_daily_memory_result(readable_path)

        {:error, _} = error ->
          error
      end
    end
  end

  defp resolve_existing_read_path(path, resolved_path, cwd, opts) do
    case check_file_access(resolved_path) do
      {:ok, stat} ->
        {:ok, resolved_path, stat}

      {:error, _} = error ->
        if missing_file?(resolved_path) do
          case maybe_workspace_bootstrap_fallback(path, cwd, opts) do
            {:ok, fallback_path, stat} ->
              {:ok, fallback_path, stat}

            :no_fallback ->
              if optional_missing_daily_memory?(path, resolved_path, opts) do
                {:ok_optional_missing, resolved_path}
              else
                error
              end
          end
        else
          error
        end
    end
  end

  defp missing_file?(path) do
    match?({:error, :enoent}, File.stat(path))
  end

  defp maybe_workspace_bootstrap_fallback(path, cwd, opts) do
    workspace_dir = Keyword.get(opts, :workspace_dir)

    cond do
      not is_binary(path) or String.trim(path) == "" ->
        :no_fallback

      Path.type(path) == :absolute ->
        :no_fallback

      explicit_relative?(path) ->
        :no_fallback

      Path.dirname(path) != "." ->
        :no_fallback

      not MapSet.member?(@workspace_bootstrap_fallback_files, path) ->
        :no_fallback

      not is_binary(workspace_dir) or String.trim(workspace_dir) == "" ->
        :no_fallback

      true ->
        fallback_path = Path.join(workspace_dir, path) |> Path.expand()
        primary_path = Path.join(cwd, path) |> Path.expand()

        if fallback_path == primary_path do
          :no_fallback
        else
          case check_file_access(fallback_path) do
            {:ok, stat} -> {:ok, fallback_path, stat}
            _ -> :no_fallback
          end
        end
    end
  end

  defp optional_missing_daily_memory?(path, resolved_path, opts) do
    workspace_dir = Keyword.get(opts, :workspace_dir)

    with true <- is_binary(workspace_dir) and String.trim(workspace_dir) != "",
         {:ok, date} <- extract_daily_memory_date(path, resolved_path),
         true <- date in [Date.utc_today(), Date.add(Date.utc_today(), -1)] do
      memory_dir = Path.join(workspace_dir, "memory")
      path_within_dir?(resolved_path, memory_dir)
    else
      _ -> false
    end
  end

  defp extract_daily_memory_date(path, resolved_path) do
    case parse_daily_memory_date(path) do
      {:ok, _} = ok -> ok
      :error -> parse_daily_memory_date(resolved_path)
    end
  end

  defp parse_daily_memory_date(path) when is_binary(path) do
    case Regex.run(@daily_memory_path_regex, path, capture: :all_but_first) do
      [iso_date] -> Date.from_iso8601(iso_date)
      _ -> :error
    end
  end

  defp parse_daily_memory_date(_), do: :error

  defp path_within_dir?(path, dir) do
    expanded_path = Path.expand(path)
    expanded_dir = Path.expand(dir)

    dir_prefix =
      if String.ends_with?(expanded_dir, "/"),
        do: expanded_dir,
        else: expanded_dir <> "/"

    expanded_path == expanded_dir or String.starts_with?(expanded_path, dir_prefix)
  end

  defp optional_missing_daily_memory_result(path) do
    %AgentToolResult{
      content: [%TextContent{text: ""}],
      details: %{
        path: path,
        total_lines: 0,
        start_line: 1,
        lines_shown: 0,
        truncation: nil,
        missing_optional: true
      }
    }
  end

  # ============================================================================
  # Path Resolution
  # ============================================================================

  defp resolve_path("", _cwd, _opts) do
    {:error, "Path is required"}
  end

  defp resolve_path(path, cwd, opts) do
    expanded =
      path
      |> expand_home()
      |> resolve_relative(cwd, opts)

    {:ok, expanded}
  end

  defp expand_home("~" <> rest) do
    Path.expand("~") <> rest
  end

  defp expand_home(path), do: path

  defp resolve_relative(path, cwd, opts) do
    if Path.type(path) == :absolute do
      path
    else
      workspace_dir = Keyword.get(opts, :workspace_dir)

      if prefer_workspace_for_path?(path, workspace_dir) do
        Path.join(workspace_dir, path) |> Path.expand()
      else
        Path.join(cwd, path) |> Path.expand()
      end
    end
  end

  defp prefer_workspace_for_path?(path, workspace_dir) do
    is_binary(workspace_dir) and String.trim(workspace_dir) != "" and
      not explicit_relative?(path) and
      (path == "MEMORY.md" or String.starts_with?(path, "memory/") or
         String.starts_with?(path, "memory\\"))
  end

  defp explicit_relative?(path) when is_binary(path) do
    String.starts_with?(path, "./") or String.starts_with?(path, "../") or
      String.starts_with?(path, ".\\") or String.starts_with?(path, "..\\")
  end

  # ============================================================================
  # File Access Check
  # ============================================================================

  defp check_file_access(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {:ok, stat}

      {:ok, %File.Stat{type: :directory}} ->
        {:error, "Path is a directory, not a file: #{path}"}

      {:ok, %File.Stat{type: type}} ->
        {:error, "Path is not a regular file (#{type}): #{path}"}

      {:error, :enoent} ->
        {:error, "File not found: #{path}"}

      {:error, :eacces} ->
        {:error, "Permission denied: #{path}"}

      {:error, reason} ->
        {:error, "Cannot access file: #{path} (#{reason})"}
    end
  end

  # ============================================================================
  # MIME Type Detection
  # ============================================================================

  defp detect_mime_type(path) do
    ext = path |> Path.extname() |> String.downcase()

    case ext do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> nil
    end
  end

  # ============================================================================
  # Image File Reading
  # ============================================================================

  defp read_image_file(path, mime_type) do
    case File.read(path) do
      {:ok, binary} ->
        base64_data = Base.encode64(binary)

        %AgentToolResult{
          content: [
            %ImageContent{
              data: base64_data,
              mime_type: mime_type
            }
          ],
          details: %{
            path: path,
            size: byte_size(binary),
            mime_type: mime_type
          }
        }

      {:error, reason} ->
        {:error, "Failed to read image file: #{path} (#{reason})"}
    end
  end

  # ============================================================================
  # Text File Reading
  # ============================================================================

  defp read_text_file(path, _stat, offset, limit, opts) do
    max_lines = Keyword.get(opts, :max_lines, @default_max_lines)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, ~r/\r?\n/, trim: false)
        total_lines = length(lines)

        # Apply offset (1-indexed to 0-indexed)
        start_line = normalize_offset(offset)
        lines_after_offset = Enum.drop(lines, start_line)

        # Apply user limit
        lines_after_limit =
          if limit && limit > 0 do
            Enum.take(lines_after_offset, limit)
          else
            lines_after_offset
          end

        # Apply truncation (max lines and max bytes)
        {truncated_lines, truncation_info} =
          truncate_head(lines_after_limit, start_line, total_lines, max_lines, max_bytes)

        # Format with line numbers
        formatted = format_line_numbers(truncated_lines, start_line + 1)

        # Build result text
        result_text =
          if truncation_info do
            formatted <> "\n" <> truncation_info.message
          else
            formatted
          end

        %AgentToolResult{
          content: [%TextContent{text: result_text}],
          details: %{
            path: path,
            total_lines: total_lines,
            start_line: start_line + 1,
            lines_shown: length(truncated_lines),
            truncation: truncation_info
          }
        }

      {:error, reason} ->
        {:error, "Failed to read file: #{path} (#{reason})"}
    end
  end

  defp normalize_offset(nil), do: 0
  defp normalize_offset(offset) when offset < 1, do: 0
  defp normalize_offset(offset), do: offset - 1

  # ============================================================================
  # Truncation
  # ============================================================================

  defp truncate_head(lines, start_line, total_lines, max_lines, max_bytes) do
    # First apply max_lines limit
    {lines_by_count, truncated_by_lines?} =
      if length(lines) > max_lines do
        {Enum.take(lines, max_lines), true}
      else
        {lines, false}
      end

    # Then apply max_bytes limit
    {final_lines, truncated_by_bytes?} = truncate_by_bytes(lines_by_count, max_bytes)

    truncated? = truncated_by_lines? || truncated_by_bytes?
    shown_count = length(final_lines)
    end_line = start_line + shown_count

    if truncated? do
      message =
        "[Showing lines #{start_line + 1}-#{end_line} of #{total_lines}. Use offset=#{end_line + 1} to continue.]"

      truncation_info = %{
        truncated: true,
        reason: truncation_reason(truncated_by_lines?, truncated_by_bytes?),
        message: message,
        next_offset: end_line + 1
      }

      {final_lines, truncation_info}
    else
      {final_lines, nil}
    end
  end

  defp truncate_by_bytes(lines, max_bytes) do
    truncate_by_bytes(lines, max_bytes, 0, [])
  end

  defp truncate_by_bytes([], _max_bytes, _acc_bytes, acc_lines) do
    {Enum.reverse(acc_lines), false}
  end

  defp truncate_by_bytes([line | rest], max_bytes, acc_bytes, acc_lines) do
    line_bytes = byte_size(line) + 1

    if acc_bytes + line_bytes > max_bytes and acc_lines != [] do
      {Enum.reverse(acc_lines), true}
    else
      truncate_by_bytes(rest, max_bytes, acc_bytes + line_bytes, [line | acc_lines])
    end
  end

  defp truncation_reason(true, true), do: "lines_and_bytes"
  defp truncation_reason(true, false), do: "max_lines"
  defp truncation_reason(false, true), do: "max_bytes"
  defp truncation_reason(false, false), do: nil

  # ============================================================================
  # Line Number Formatting
  # ============================================================================

  defp format_line_numbers(lines, start_line) do
    lines
    |> Enum.with_index(start_line)
    |> Enum.map(fn {line, line_num} ->
      "#{line_num}: #{line}"
    end)
    |> Enum.join("\n")
  end

  # ============================================================================
  # Abort Signal Handling
  # ============================================================================

  defp aborted?(nil), do: false
  defp aborted?(signal), do: AgentCore.AbortSignal.aborted?(signal)

  defp check_abort(signal) do
    if aborted?(signal) do
      {:error, "Operation aborted"}
    else
      :ok
    end
  end
end
