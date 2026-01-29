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

    with {:ok, resolved_path} <- resolve_path(path, cwd),
         {:ok, stat} <- check_file_access(resolved_path),
         :ok <- check_abort(signal) do
      case detect_mime_type(resolved_path) do
        nil ->
          read_text_file(resolved_path, stat, offset, limit, opts)

        mime_type ->
          read_image_file(resolved_path, mime_type)
      end
    end
  end

  # ============================================================================
  # Path Resolution
  # ============================================================================

  defp resolve_path("", _cwd) do
    {:error, "Path is required"}
  end

  defp resolve_path(path, cwd) do
    expanded =
      path
      |> expand_home()
      |> resolve_relative(cwd)

    {:ok, expanded}
  end

  defp expand_home("~" <> rest) do
    Path.expand("~") <> rest
  end

  defp expand_home(path), do: path

  defp resolve_relative(path, cwd) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(cwd, path) |> Path.expand()
    end
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
