defmodule CodingAgent.Tools.Find do
  @moduledoc """
  Find files tool for the coding agent.

  Finds files by name/pattern. Uses `fd` if available for performance,
  falling back to Elixir's Path.wildcard for compatibility.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @default_max_results 100

  @doc """
  Returns the Find tool definition.

  ## Options

  - `:max_results` - Default max results (default: 100)
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "find",
      description:
        "Find files by name or pattern. Searches recursively from the given path. " <>
          "Returns matching file paths relative to the working directory.",
      label: "Find Files",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" =>
              "File name pattern to search for. Supports glob patterns (e.g., '*.ex', 'test_*.exs') " <>
                "and regex patterns when using fd."
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "Directory to search in (relative to cwd or absolute). Defaults to current working directory."
          },
          "type" => %{
            "type" => "string",
            "enum" => ["file", "directory", "all"],
            "description" =>
              "Type of entries to find: 'file', 'directory', or 'all' (default: 'all')"
          },
          "max_depth" => %{
            "type" => "integer",
            "description" => "Maximum directory depth to search"
          },
          "max_results" => %{
            "type" => "integer",
            "description" => "Maximum number of results to return (default: 100)"
          },
          "hidden" => %{
            "type" => "boolean",
            "description" => "Include hidden files/directories (default: false)"
          }
        },
        "required" => ["pattern"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Execute the find tool.

  ## Parameters

  - `tool_call_id` - Unique identifier for this tool invocation
  - `params` - Parameters map with search options
  - `signal` - Abort signal for cancellation (can be nil)
  - `on_update` - Callback for streaming partial results (unused for find)
  - `cwd` - Current working directory
  - `opts` - Tool options

  ## Returns

  - `AgentToolResult.t()` - Result with found files
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
    search_path = Map.get(params, "path", ".")
    entry_type = Map.get(params, "type", "all")
    max_depth = Map.get(params, "max_depth")

    max_results =
      Map.get(params, "max_results", Keyword.get(opts, :max_results, @default_max_results))

    include_hidden = Map.get(params, "hidden", false)

    with {:ok, resolved_path} <- resolve_path(search_path, cwd),
         :ok <- check_directory(resolved_path),
         :ok <- check_abort(signal) do
      find_files(
        pattern,
        resolved_path,
        entry_type,
        max_depth,
        max_results,
        include_hidden,
        signal,
        cwd
      )
    end
  end

  # ============================================================================
  # Path Resolution
  # ============================================================================

  defp resolve_path("", cwd), do: {:ok, cwd}
  defp resolve_path(".", cwd), do: {:ok, cwd}

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
  # Directory Check
  # ============================================================================

  defp check_directory(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{}} ->
        {:error, "Path is not a directory: #{path}"}

      {:error, :enoent} ->
        {:error, "Directory not found: #{path}"}

      {:error, :eacces} ->
        {:error, "Permission denied: #{path}"}

      {:error, reason} ->
        {:error, "Cannot access directory: #{path} (#{reason})"}
    end
  end

  # ============================================================================
  # File Finding
  # ============================================================================

  defp find_files(
         pattern,
         search_path,
         entry_type,
         max_depth,
         max_results,
         include_hidden,
         signal,
         cwd
       ) do
    case fd_available?() do
      true ->
        find_with_fd(
          pattern,
          search_path,
          entry_type,
          max_depth,
          max_results,
          include_hidden,
          signal,
          cwd
        )

      false ->
        find_with_elixir(
          pattern,
          search_path,
          entry_type,
          max_depth,
          max_results,
          include_hidden,
          signal,
          cwd
        )
    end
  end

  # ============================================================================
  # fd-based Finding
  # ============================================================================

  defp fd_available? do
    case System.find_executable("fd") do
      nil -> false
      _ -> true
    end
  end

  defp find_with_fd(
         pattern,
         search_path,
         entry_type,
         max_depth,
         max_results,
         include_hidden,
         signal,
         cwd
       ) do
    args = build_fd_args(pattern, search_path, entry_type, max_depth, max_results, include_hidden)

    case run_fd(args, cwd, signal) do
      {:ok, output} ->
        results =
          output
          |> String.split("\n", trim: true)
          |> Enum.take(max_results)

        format_results(results, cwd, max_results)

      {:error, reason} ->
        # Fall back to Elixir if fd fails
        case find_with_elixir(
               pattern,
               search_path,
               entry_type,
               max_depth,
               max_results,
               include_hidden,
               signal,
               cwd
             ) do
          {:error, _} -> {:error, reason}
          result -> result
        end
    end
  end

  defp build_fd_args(pattern, search_path, entry_type, max_depth, max_results, include_hidden) do
    args = []

    # Use glob mode if pattern contains glob characters
    args =
      if is_glob_pattern?(pattern) do
        args ++ ["--glob"]
      else
        args
      end

    # Entry type
    args =
      case entry_type do
        "file" -> args ++ ["--type", "f"]
        "directory" -> args ++ ["--type", "d"]
        _ -> args
      end

    # Max depth
    args =
      if max_depth do
        args ++ ["--max-depth", to_string(max_depth)]
      else
        args
      end

    # Max results (fd uses --max-results)
    args = args ++ ["--max-results", to_string(max_results)]

    # Hidden files
    args =
      if include_hidden do
        args ++ ["--hidden"]
      else
        args
      end

    # Pattern and path
    args ++ [pattern, search_path]
  end

  # Detect if a pattern contains glob characters
  defp is_glob_pattern?(pattern) do
    String.contains?(pattern, ["*", "?", "[", "]", "{", "}"])
  end

  defp run_fd(args, cwd, signal) do
    try do
      port =
        Port.open(
          {:spawn_executable, System.find_executable("fd")},
          [:binary, :exit_status, :stderr_to_stdout, args: args, cd: cwd]
        )

      collect_fd_output(port, "", signal)
    catch
      :error, reason ->
        {:error, "Failed to run fd: #{inspect(reason)}"}
    end
  end

  defp collect_fd_output(port, acc, signal) do
    if aborted?(signal) do
      Port.close(port)
      {:error, "Operation aborted"}
    else
      receive do
        {^port, {:data, data}} ->
          collect_fd_output(port, acc <> data, signal)

        {^port, {:exit_status, 0}} ->
          {:ok, acc}

        {^port, {:exit_status, 1}} ->
          # fd returns 1 when no matches found
          {:ok, ""}

        {^port, {:exit_status, status}} ->
          {:error, "fd exited with status #{status}: #{acc}"}
      after
        30_000 ->
          Port.close(port)
          {:error, "fd command timed out"}
      end
    end
  end

  # ============================================================================
  # Elixir-based Finding (fallback)
  # ============================================================================

  defp find_with_elixir(
         pattern,
         search_path,
         entry_type,
         max_depth,
         max_results,
         include_hidden,
         signal,
         cwd
       ) do
    glob_pattern = build_glob_pattern(pattern, search_path, max_depth)

    results =
      glob_pattern
      |> Path.wildcard(match_dot: include_hidden)
      |> filter_by_type(entry_type)
      |> Enum.take(max_results)

    if aborted?(signal) do
      {:error, "Operation aborted"}
    else
      format_results(results, cwd, max_results)
    end
  rescue
    e ->
      {:error, "Find operation failed: #{Exception.message(e)}"}
  end

  defp build_glob_pattern(pattern, search_path, nil) do
    Path.join([search_path, "**", pattern])
  end

  defp build_glob_pattern(pattern, search_path, max_depth) when max_depth > 0 do
    # Build pattern for limited depth
    depth_patterns =
      0..max_depth
      |> Enum.map(fn depth ->
        parts = List.duplicate("*", depth)
        Path.join([search_path | parts] ++ [pattern])
      end)

    # Return first pattern; Path.wildcard doesn't support multiple patterns
    # so we'll use the deepest one
    List.last(depth_patterns)
  end

  defp build_glob_pattern(pattern, search_path, _), do: Path.join(search_path, pattern)

  defp filter_by_type(paths, "file") do
    Enum.filter(paths, &File.regular?/1)
  end

  defp filter_by_type(paths, "directory") do
    Enum.filter(paths, &File.dir?/1)
  end

  defp filter_by_type(paths, _), do: paths

  # ============================================================================
  # Result Formatting
  # ============================================================================

  defp format_results(results, cwd, max_results) do
    # Make paths relative to cwd
    relative_results =
      results
      |> Enum.map(&make_relative(&1, cwd))
      |> Enum.sort()

    count = length(relative_results)
    truncated = count >= max_results

    text =
      if count == 0 do
        "No files found matching the pattern."
      else
        header =
          if truncated do
            "Found #{count} matches (limited to #{max_results}):\n\n"
          else
            "Found #{count} match#{if count == 1, do: "", else: "es"}:\n\n"
          end

        file_list = Enum.join(relative_results, "\n")
        header <> file_list
      end

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{
        count: count,
        truncated: truncated,
        max_results: max_results,
        files: relative_results
      }
    }
  end

  defp make_relative(path, cwd) do
    case Path.relative_to(path, cwd) do
      ^path ->
        # Path is not under cwd, try to make it relative anyway
        if String.starts_with?(path, cwd) do
          String.trim_leading(path, cwd) |> String.trim_leading("/")
        else
          path
        end

      relative ->
        relative
    end
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
