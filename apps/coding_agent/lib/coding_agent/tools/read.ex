defmodule CodingAgent.Tools.Read do
  @moduledoc """
  Read file tool for the coding agent.

  Reads the contents of a file with support for:
  - Numbered physical text lines and full-byte snapshots for anchored edits
  - Directories, in-memory archive members, PDF pages and notebook cells/outputs
  - Native image content with bounded proportional previews when a backend exists
  - Offset and limit parameters for partial reads, with format-specific continuation
  - Path line selectors (`file:50-80`, `file:50+20`, `file:50`, `file:-30`, `file:raw`)
    applied only when the literal path does not exist
  - Bounded chunked text scanning, including oversized single-line files
  - Binary/invalid UTF-8 refusal with actionable inspection guidance
  - `agent://` live family rosters and `agent://<task-id-or-name>` identities
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAi.Types.{TextContent, ImageContent}
  alias CodingAgent.FileReadTracker
  alias CodingAgent.InternalUrls
  alias CodingAgent.Tools.ACPFileBridge
  alias CodingAgent.Tools.FileValidation
  alias CodingAgent.Tools.PathHelpers

  import CodingAgent.Tools.AbortHelpers, only: [aborted?: 1, check_abort: 1]

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
        "Read files, directories, archives (archive.zip:member), PDFs, notebooks, images, and SQLite databases " <>
          "(app.db lists tables; app.db:table, app.db:table:key, app.db:table?limit=&offset=&where=&order=, app.db?q=SELECT ...). " <>
          "Text files include a snapshot tag and 1-based lines; prefer edit with snapshot + edits " <>
          "to change line ranges without copying old text. Use offset/limit or a path selector " <>
          "(file:50-80, file:50+20, file:50 from line 50, file:-30 last 30 lines, file:raw or " <>
          "file:50-80:raw for unnumbered text) to page. " <>
          "Text output is capped at 2000 lines / 50KB. PDF page/page_limit and notebook cell/cell_limit select source units. " <>
          "Returned skill:// and artifact:// references are readable paths.",
      label: "Read File",
      parallel_safe: true,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "A local path, skill://<key>[/relative-path], returned artifact://<id> handle, or agent://[task-id-or-name] live roster. May end with a line selector such as :50-80, :50+20, :50, :-30 or :raw"
          },
          "offset" => %{
            "type" => "integer",
            "description" => "Line number to start reading from (positive, 1-indexed)",
            "minimum" => 1
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of lines to read (positive integer)",
            "minimum" => 1
          },
          "page" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "First PDF page (1-based)"
          },
          "page_limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "Maximum PDF pages to extract"
          },
          "cell" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "First notebook cell (1-based)"
          },
          "cell_limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "Maximum notebook cells to show"
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
  def execute(_tool_call_id, %{"path" => "agent://" <> _ = path}, signal, _on_update, _cwd, opts) do
    if aborted?(signal),
      do: {:error, "Operation aborted"},
      else: CodingAgent.Tools.Task.Messaging.read(path, opts)
  end

  def execute(tool_call_id, params, signal, _on_update, cwd, opts) do
    _ = tool_call_id

    # Check for abort at start
    if aborted?(signal) do
      {:error, "Operation aborted"}
    else
      params
      |> do_execute(signal, cwd, opts)
      |> ToolResultTrust.untrusted(:local_file)
    end
  end

  defp do_execute(params, signal, cwd, opts) do
    case apply_path_selector(params, cwd, opts) do
      {:ok, params, %{tail: tail} = view} when is_integer(tail) ->
        read_tail(params, tail, view, signal, cwd, opts)

      {:ok, params, view} ->
        do_read(params, view, signal, cwd, opts)

      {:error, _} = error ->
        error
    end
  end

  defp do_read(params, view, signal, cwd, opts) do
    path = Map.get(params, "path", "")
    offset = Map.get(params, "offset")
    limit = Map.get(params, "limit")

    with :ok <- validate_params(path, offset, limit),
         {:ok, resolved_path} <- resolve_path(path, cwd, opts),
         :ok <- check_abort(signal) do
      # Client filesystem reads are authoritative for unsaved text buffers.
      # Internal references deliberately stay local, as do native rich reads.
      rich_result =
        if not ACPFileBridge.read_enabled?(opts) or InternalUrls.internal_url?(path),
          do: CodingAgent.Tools.ReadFormats.read(resolved_path, params, signal, cwd, opts),
          else: :not_supported

      case rich_result do
        {:ok, result} -> result
        :not_supported -> read_plain(path, resolved_path, offset, limit, view, signal, cwd, opts)
        {:error, _} = error -> error
      end
    end
  end

  # `-N` needs the rendered line count first; a one-line probe reports it for
  # plain text and every rich format alike.
  defp read_tail(params, tail, view, signal, cwd, opts) do
    case do_read(Map.merge(params, %{"offset" => 1, "limit" => 1}), view, signal, cwd, opts) do
      %AgentToolResult{details: %{total_lines: total}} when is_integer(total) and total > 0 ->
        offset = max(total - tail + 1, 1)

        do_read(
          Map.merge(params, %{"offset" => offset, "limit" => tail}),
          view,
          signal,
          cwd,
          opts
        )

      %AgentToolResult{} ->
        do_read(params, view, signal, cwd, opts)

      other ->
        other
    end
  end

  # ============================================================================
  # Path Line Selectors
  # ============================================================================

  @selector_token ~r/\A(?:raw|\d+(?:-\d*|\+\d+)?|-\d+)\z/

  # A trailing `:selector` (up to two, e.g. `:10-20:raw`) only applies when the
  # literal path is missing and the remaining base names a real source, so
  # files containing colons and archive members keep their existing meaning.
  defp apply_path_selector(%{"path" => path} = params, cwd, opts) when is_binary(path) do
    with {base, tokens} <- split_selector(path),
         true <- selector_target?(path, base, cwd, opts) do
      build_selector_view(params, base, tokens)
    else
      _ -> {:ok, params, %{}}
    end
  end

  defp apply_path_selector(params, _cwd, _opts), do: {:ok, params, %{}}

  defp split_selector(path) do
    {base_segments, tokens} =
      path |> String.split(":") |> Enum.reverse() |> take_selector_tokens([])

    base = base_segments |> Enum.reverse() |> Enum.join(":")

    if tokens == [] or String.trim(base) == "", do: nil, else: {base, tokens}
  end

  defp take_selector_tokens([token | rest], acc) when rest != [] and length(acc) < 2 do
    if Regex.match?(@selector_token, token),
      do: take_selector_tokens(rest, [token | acc]),
      else: {[token | rest], acc}
  end

  defp take_selector_tokens(segments, acc), do: {segments, acc}

  defp selector_target?(path, base, cwd, opts) do
    cond do
      InternalUrls.internal_url?(base) ->
        true

      InternalUrls.internal_url?(path) ->
        false

      File.exists?(PathHelpers.resolve_path(path, cwd, opts)) ->
        false

      true ->
        resolved_base = PathHelpers.resolve_path(base, cwd, opts)

        File.exists?(resolved_base) or
          CodingAgent.Tools.ReadArchive.split_path(resolved_base) != nil
    end
  end

  defp build_selector_view(params, base, tokens) do
    {raw_tokens, range_tokens} = Enum.split_with(tokens, &(&1 == "raw"))

    cond do
      length(raw_tokens) > 1 or length(range_tokens) > 1 ->
        {:error, "A path selector takes at most one line range and one :raw"}

      range_tokens != [] and
          (not is_nil(Map.get(params, "offset")) or not is_nil(Map.get(params, "limit"))) ->
        {:error, "Use either a path line selector or offset/limit, not both"}

      true ->
        view = %{raw: raw_tokens != []}
        params = Map.put(params, "path", base)

        case range_tokens do
          [] -> {:ok, params, view}
          [range] -> apply_selector_range(params, view, range)
        end
    end
  end

  defp apply_selector_range(params, view, "-" <> count) do
    case String.to_integer(count) do
      n when n >= 1 -> {:ok, params, Map.put(view, :tail, n)}
      _ -> {:error, "Line selector :-N needs N >= 1"}
    end
  end

  defp apply_selector_range(params, view, range) do
    [start | rest] = Regex.run(~r/\A(\d+)(?:(-|\+)(\d*))?\z/, range, capture: :all_but_first)

    case selector_window(String.to_integer(start), rest) do
      {:ok, window} -> {:ok, Map.merge(params, window), view}
      {:error, _} = error -> error
    end
  end

  defp selector_window(start, _rest) when start < 1,
    do: {:error, "Line selectors are 1-based; use :1 or later"}

  defp selector_window(start, rest) when rest in [[], ["-", ""]],
    do: {:ok, %{"offset" => start}}

  defp selector_window(start, ["-", stop]) do
    case String.to_integer(stop) do
      stop when stop >= start -> {:ok, %{"offset" => start, "limit" => stop - start + 1}}
      stop -> {:error, "Line selector :#{start}-#{stop} ends before it starts"}
    end
  end

  defp selector_window(start, ["+", count]) when count != "" do
    case String.to_integer(count) do
      count when count >= 1 -> {:ok, %{"offset" => start, "limit" => count}}
      _ -> {:error, "Line selector :N+K needs K >= 1"}
    end
  end

  defp selector_window(start, _rest), do: {:error, "Invalid line selector starting at #{start}"}

  defp read_plain(path, resolved_path, offset, limit, view, signal, cwd, opts) do
    cond do
      not InternalUrls.internal_url?(path) and ACPFileBridge.read_enabled?(opts) and
          is_nil(detect_mime_type(resolved_path)) ->
        read_text_file_from_acp(resolved_path, offset, limit, view, opts)

      true ->
        case resolve_existing_read_path(path, resolved_path, cwd, opts) do
          {:ok, readable_path, stat} ->
            case detect_mime_type(readable_path) do
              nil ->
                read_text_file(
                  readable_path,
                  stat,
                  offset,
                  limit,
                  view,
                  signal,
                  opts,
                  not InternalUrls.internal_url?(path)
                )

              mime_type ->
                read_image_file(readable_path, mime_type, stat)
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

      PathHelpers.explicit_relative?(path) ->
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
    if InternalUrls.internal_url?(path) do
      InternalUrls.resolve(path, Keyword.put(opts, :cwd, cwd))
    else
      {:ok, PathHelpers.resolve_path(path, cwd, opts)}
    end
  end

  # ============================================================================
  # File Access Check
  # ============================================================================

  defp check_file_access(path), do: FileValidation.check_path_access(path, [:regular])

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

  defp read_image_file(_path, _mime_type, %{size: size}) when size > 20 * 1024 * 1024 do
    {:error,
     "Image is #{size} bytes, exceeding the 20 MiB limit. Resize or crop it with bash before reading."}
  end

  defp read_image_file(path, mime_type, _stat) do
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

  defp read_text_file(path, _stat, offset, limit, view, signal, opts, editable?) do
    max_lines = Keyword.get(opts, :max_lines, @default_max_lines)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    case CodingAgent.Tools.ReadText.read(
           path,
           normalize_offset(offset),
           limit,
           max_lines,
           max_bytes,
           signal
         ) do
      {:ok, window} ->
        FileReadTracker.record_digest(opts, path, window.digest)

        render_window(path, window, normalize_offset(offset), max_bytes, %{
          immutable: not editable?,
          raw: Map.get(view, :raw, false)
        })

      {:error, _} = error ->
        error
    end
  end

  defp read_text_file_from_acp(path, offset, limit, view, opts) do
    case ACPFileBridge.read_text_file(path, offset, limit, opts) do
      {:ok, content} ->
        max_lines = Keyword.get(opts, :max_lines, @default_max_lines)
        max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

        with {:ok, window} <-
               CodingAgent.Tools.ReadText.from_content(content, max_lines, max_bytes) do
          window =
            if normalize_offset(offset) == 0 and is_nil(limit),
              do: Map.put(window, :digest, :erlang.md5(content)),
              else: window

          # The ACP client has already applied line/limit; do not slice twice.
          render_window(path, window, normalize_offset(offset), max_bytes, %{
            acp_client: true,
            raw: Map.get(view, :raw, false)
          })
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp render_window(path, window, start_line, max_bytes, extra_details) do
    if not Map.get(extra_details, :acp_client, false) and start_line >= window.total_lines do
      {:error,
       "offset=#{start_line + 1} is beyond the end of the file (#{window.total_lines} lines)."}
    else
      shown = length(window.lines)
      next_offset = start_line + shown + 1

      total =
        if Map.get(extra_details, :acp_client, false),
          do: start_line + window.total_lines,
          else: window.total_lines

      truncation =
        case window.truncation do
          nil ->
            nil

          "long_line" ->
            %{
              truncated: true,
              reason: "long_line",
              next_offset: next_offset,
              message:
                "[Line #{start_line + 1} exceeds the #{max_bytes}-byte read budget; only a prefix is shown. Full content remains at #{path}; use bash to inspect byte ranges on this line.]"
            }

          reason ->
            %{
              truncated: true,
              reason: reason,
              next_offset: next_offset,
              message:
                "[Showing lines #{start_line + 1}-#{next_offset - 1} of #{total}. Use offset=#{next_offset} to continue.]"
            }
        end

      raw? = Map.get(extra_details, :raw, false)

      formatted =
        if raw?,
          do: Enum.join(window.lines, "\n"),
          else: format_line_numbers(window.lines, start_line + 1)

      text = if truncation, do: formatted <> "\n" <> truncation.message, else: formatted

      snapshot =
        case {raw? or Map.get(extra_details, :immutable, false), Map.get(window, :digest)} do
          {false, digest} when is_binary(digest) ->
            CodingAgent.Tools.AnchoredEdit.snapshot_for_digest(digest)

          _ ->
            nil
        end

      text = if snapshot, do: "[#{path}##{snapshot}]\n" <> text, else: text

      %AgentToolResult{
        content: [%TextContent{text: text}],
        details:
          Map.merge(
            %{
              path: path,
              total_lines: total,
              start_line: start_line + 1,
              lines_shown: shown,
              truncation: truncation,
              snapshot: snapshot
            },
            extra_details
          )
      }
    end
  end

  defp validate_params(path, offset, limit) do
    cond do
      not is_binary(path) or String.trim(path) == "" ->
        {:error, "path must be a non-empty string"}

      not is_nil(offset) and (not is_integer(offset) or offset < 1) ->
        {:error, "offset must be a positive integer (1-indexed line number)"}

      not is_nil(limit) and (not is_integer(limit) or limit < 1) ->
        {:error, "limit must be a positive integer (number of lines)"}

      true ->
        :ok
    end
  end

  defp normalize_offset(nil), do: 0
  defp normalize_offset(offset), do: offset - 1

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
end
