defmodule CodingAgent.Tools.Grep do
  @moduledoc """
  Grep tool for the coding agent.

  Searches for patterns in files using ripgrep (rg) if available,
  falling back to Elixir's built-in file/regex operations.

  ## Features

  - Regex pattern matching
  - Optional path/directory to search
  - File glob filtering (e.g., "*.ex")
  - Case sensitive/insensitive search
  - Context lines around matches
  - Result limiting
  - Abort signal support
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @default_max_results 100
  @default_context_lines 0

  @doc """
  Returns the Grep tool definition.

  ## Options

  - `:max_results` - Default maximum results (default: 100)
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "grep",
      description:
        "Search for patterns in files using regex. Uses ripgrep for performance when available.",
      label: "Search Files",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Regex pattern to search for"
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "File or directory to search in (relative to cwd or absolute). Defaults to cwd."
          },
          "glob" => %{
            "type" => "string",
            "description" => "File glob pattern to filter (e.g., \"*.ex\", \"*.{ex,exs}\")"
          },
          "case_sensitive" => %{
            "type" => "boolean",
            "description" => "Whether the search is case sensitive (default: true)"
          },
          "context_lines" => %{
            "type" => "integer",
            "description" => "Number of lines of context to show around matches"
          },
          "max_results" => %{
            "type" => "integer",
            "description" => "Maximum number of matches to return (default: 100)"
          }
        },
        "required" => ["pattern"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Execute the grep tool.

  ## Parameters

  - `tool_call_id` - Unique identifier for this tool invocation
  - `params` - Parameters map with "pattern", optional "path", "glob", etc.
  - `signal` - Abort signal for cancellation (can be nil)
  - `on_update` - Callback for streaming partial results (unused for grep)
  - `cwd` - Current working directory
  - `opts` - Tool options

  ## Returns

  - `AgentToolResult.t()` - Result with matched lines and file paths
  - `{:error, term()}` - Error if search fails
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: function() | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    if aborted?(signal) do
      {:error, "Operation aborted"}
    else
      do_execute(params, signal, cwd, opts)
    end
  end

  defp do_execute(params, signal, cwd, opts) do
    pattern = Map.get(params, "pattern", "")
    path = Map.get(params, "path")
    glob = Map.get(params, "glob")
    case_sensitive = Map.get(params, "case_sensitive", true)
    context_lines = Map.get(params, "context_lines", @default_context_lines)
    max_results = Map.get(params, "max_results", Keyword.get(opts, :max_results, @default_max_results))

    with :ok <- validate_pattern(pattern),
         {:ok, resolved_path} <- resolve_path(path, cwd),
         :ok <- check_path_access(resolved_path),
         :ok <- check_abort(signal) do
      search_opts = %{
        pattern: pattern,
        path: resolved_path,
        glob: glob,
        case_sensitive: case_sensitive,
        context_lines: context_lines,
        max_results: max_results,
        signal: signal
      }

      if ripgrep_available?() do
        search_with_ripgrep(search_opts)
      else
        search_with_elixir(search_opts)
      end
    end
  end

  # ============================================================================
  # Validation
  # ============================================================================

  defp validate_pattern("") do
    {:error, "Pattern is required"}
  end

  defp validate_pattern(nil) do
    {:error, "Pattern is required"}
  end

  defp validate_pattern(pattern) when not is_binary(pattern) do
    {:error, "Pattern must be a string, got: #{inspect(pattern)}"}
  end

  defp validate_pattern(pattern) when byte_size(pattern) > 10_000 do
    {:error, "Pattern is too long (max 10000 bytes)"}
  end

  defp validate_pattern(pattern) do
    case Regex.compile(pattern) do
      {:ok, _} ->
        :ok

      {:error, {reason, position}} ->
        # Provide more helpful error message with position
        hint = suggest_regex_fix(pattern, reason)

        message =
          if position > 0 do
            "Invalid regex pattern at position #{position}: #{reason}#{hint}"
          else
            "Invalid regex pattern: #{reason}#{hint}"
          end

        {:error, message}
    end
  end

  # Suggest common fixes for regex errors
  defp suggest_regex_fix(pattern, _reason) do
    cond do
      String.contains?(pattern, "[") and not String.contains?(pattern, "]") ->
        " (hint: missing closing bracket ']')"

      String.contains?(pattern, "(") and not String.contains?(pattern, ")") ->
        " (hint: missing closing parenthesis ')')"

      String.contains?(pattern, "{") and not String.contains?(pattern, "}") ->
        " (hint: missing closing brace '}')"

      String.ends_with?(pattern, "\\") ->
        " (hint: trailing backslash needs to be escaped as '\\\\')"

      true ->
        ""
    end
  end

  # ============================================================================
  # Path Resolution
  # ============================================================================

  defp resolve_path(nil, cwd), do: {:ok, cwd}
  defp resolve_path("", cwd), do: {:ok, cwd}

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

  defp check_path_access(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: type}} when type in [:regular, :directory] ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        {:error, "Path is not a file or directory (#{type}): #{path}"}

      {:error, :enoent} ->
        {:error, "Path not found: #{path}"}

      {:error, :eacces} ->
        {:error, "Permission denied: #{path}"}

      {:error, reason} ->
        {:error, "Cannot access path: #{path} (#{reason})"}
    end
  end

  # ============================================================================
  # Ripgrep Search
  # ============================================================================

  @doc false
  def ripgrep_available? do
    case System.find_executable("rg") do
      nil -> false
      _ -> true
    end
  end

  defp search_with_ripgrep(opts) do
    args = build_ripgrep_args(opts)

    case System.cmd("rg", args, stderr_to_stdout: true, cd: Path.dirname(opts.path)) do
      {output, 0} ->
        parse_ripgrep_output(output, opts)

      {output, 1} ->
        # Exit code 1 means no matches found
        %AgentToolResult{
          content: [%TextContent{text: "No matches found."}],
          details: %{
            match_count: 0,
            files_searched: count_files_in_output(output),
            truncated: false
          }
        }

      {output, 2} ->
        # Exit code 2 means error
        {:error, "Search error: #{String.trim(output)}"}

      {output, code} ->
        {:error, "ripgrep exited with code #{code}: #{String.trim(output)}"}
    end
  end

  defp build_ripgrep_args(opts) do
    args = [
      "--line-number",
      "--with-filename",
      "--color", "never"
    ]

    args = if opts.case_sensitive, do: args, else: args ++ ["--ignore-case"]

    args =
      if opts.context_lines > 0 do
        args ++ ["--context", to_string(opts.context_lines)]
      else
        args
      end

    args =
      if opts.max_results do
        args ++ ["--max-count", to_string(opts.max_results)]
      else
        args
      end

    args =
      if opts.glob do
        args ++ ["--glob", opts.glob]
      else
        args
      end

    # Add pattern and path
    args ++ [opts.pattern, opts.path]
  end

  defp parse_ripgrep_output(output, opts) do
    lines = String.split(output, "\n", trim: true)
    match_count = count_matches(lines)
    truncated = match_count >= opts.max_results

    result_text =
      if truncated do
        output <> "\n\n[Results truncated at #{opts.max_results} matches]"
      else
        output
      end

    summary =
      if match_count > 0 do
        "Found #{match_count} match#{if match_count == 1, do: "", else: "es"}.\n\n#{result_text}"
      else
        "No matches found."
      end

    %AgentToolResult{
      content: [%TextContent{text: summary}],
      details: %{
        match_count: match_count,
        truncated: truncated
      }
    }
  end

  defp count_matches(lines) do
    # Count lines that look like matches (file:line:content)
    Enum.count(lines, fn line ->
      Regex.match?(~r/^[^:]+:\d+:/, line)
    end)
  end

  defp count_files_in_output(_output), do: 0

  # ============================================================================
  # Elixir Fallback Search
  # ============================================================================

  defp search_with_elixir(opts) do
    case compile_regex(opts.pattern, opts.case_sensitive) do
      {:ok, regex} ->
        do_elixir_search(regex, opts)

      {:error, reason} ->
        {:error, "Invalid regex: #{reason}"}
    end
  end

  defp compile_regex(pattern, case_sensitive) do
    options = if case_sensitive, do: [], else: [:caseless]
    Regex.compile(pattern, options)
  end

  defp do_elixir_search(regex, opts) do
    files = find_files(opts.path, opts.glob)

    results =
      files
      |> Stream.flat_map(fn file ->
        if aborted?(opts.signal) do
          []
        else
          search_file(file, regex, opts.context_lines)
        end
      end)
      |> Stream.take(opts.max_results)
      |> Enum.to_list()

    if aborted?(opts.signal) do
      {:error, "Operation aborted"}
    else
      format_elixir_results(results, opts.max_results)
    end
  end

  defp find_files(path, glob) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        [path]

      {:ok, %File.Stat{type: :directory}} ->
        pattern =
          if glob do
            Path.join([path, "**", glob])
          else
            Path.join(path, "**/*")
          end

        pattern
        |> Path.wildcard()
        |> Enum.filter(&regular_file?/1)
        |> Enum.filter(&text_file?/1)

      _ ->
        []
    end
  end

  defp regular_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      _ -> false
    end
  end

  defp text_file?(path) do
    # Simple heuristic: check first 512 bytes for null bytes
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        result =
          case IO.binread(file, 512) do
            {:error, _} -> false
            :eof -> true
            data -> not String.contains?(data, <<0>>)
          end

        File.close(file)
        result

      _ ->
        false
    end
  end

  defp search_file(file_path, regex, context_lines) do
    case File.read(file_path) do
      {:ok, content} ->
        lines = String.split(content, ~r/\r?\n/)

        lines
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _idx} -> Regex.match?(regex, line) end)
        |> Enum.map(fn {line, idx} ->
          context = get_context(lines, idx, context_lines)
          %{file: file_path, line_number: idx, content: line, context: context}
        end)

      {:error, _} ->
        []
    end
  end

  defp get_context(_lines, _idx, 0), do: nil

  defp get_context(lines, idx, context_lines) do
    total = length(lines)
    start_idx = max(1, idx - context_lines)
    end_idx = min(total, idx + context_lines)

    lines
    |> Enum.slice((start_idx - 1)..(end_idx - 1))
    |> Enum.with_index(start_idx)
    |> Enum.map(fn {line, line_num} ->
      prefix = if line_num == idx, do: ">", else: " "
      "#{prefix}#{line_num}: #{line}"
    end)
    |> Enum.join("\n")
  end

  defp format_elixir_results([], _max_results) do
    %AgentToolResult{
      content: [%TextContent{text: "No matches found."}],
      details: %{
        match_count: 0,
        truncated: false
      }
    }
  end

  defp format_elixir_results(results, max_results) do
    match_count = length(results)
    truncated = match_count >= max_results

    formatted =
      results
      |> Enum.map(&format_match/1)
      |> Enum.join("\n")

    text =
      if truncated do
        "Found #{match_count} match#{if match_count == 1, do: "", else: "es"} (truncated at #{max_results}).\n\n#{formatted}"
      else
        "Found #{match_count} match#{if match_count == 1, do: "", else: "es"}.\n\n#{formatted}"
      end

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{
        match_count: match_count,
        truncated: truncated
      }
    }
  end

  defp format_match(%{file: file, line_number: line_num, content: content, context: nil}) do
    "#{file}:#{line_num}:#{content}"
  end

  defp format_match(%{file: file, line_number: _line_num, context: context}) do
    "#{file}:\n#{context}"
  end

  # ============================================================================
  # Abort Signal Handling
  # ============================================================================

  defp aborted?(nil), do: false
  defp aborted?(signal), do: AbortSignal.aborted?(signal)

  defp check_abort(signal) do
    if aborted?(signal) do
      {:error, "Operation aborted"}
    else
      :ok
    end
  end
end
