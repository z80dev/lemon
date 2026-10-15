defmodule CodingAgent.Tools.Find do
  @moduledoc """
  Find files tool for the coding agent.

  Finds files by glob pattern. Uses `fd` in case-sensitive glob mode if
  available, falling back to Elixir's Path.wildcard with the same semantics.

  `.gitignore`/`.ignore` rules are respected by default (so `_build/`,
  `deps/`, and `node_modules/` do not crowd out real results); pass
  `no_ignore: true` to include ignored files. The Elixir fallback filters
  ignored paths with `git check-ignore` when the search path is inside a git
  work tree.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAi.Types.TextContent
  alias CodingAgent.Tools.IgnoreFilter
  alias CodingAgent.Tools.PathHelpers

  import LemonAgent.Tools.AbortHelpers, only: [aborted?: 1, check_abort: 1]

  @default_max_results 100
  @elixir_find_timeout_ms 30_000
  @max_candidates 100_000

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
      parallel_safe: true,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" =>
              "Case-sensitive basename glob, or a path glob when it contains '/' (e.g., 'lib/*.ex'). Plain names match exactly."
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "Directory roots separated by semicolons (relative to cwd or absolute). Defaults to cwd."
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
          "sort" => %{
            "type" => "string",
            "enum" => ["mtime", "path"],
            "description" =>
              "Sort all candidates by path (default) or newest modification time first"
          },
          "max_results" => %{
            "type" => "integer",
            "description" => "Maximum number of results to return (default: 100)"
          },
          "hidden" => %{
            "type" => "boolean",
            "description" => "Include hidden files/directories (default: false)"
          },
          "no_ignore" => %{
            "type" => "boolean",
            "description" =>
              "Include files ignored by .gitignore/.ignore (default: false; ignored files are skipped)"
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
      params
      |> do_execute(signal, cwd, opts)
      |> ToolResultTrust.untrusted(:local_search)
    end
  end

  defp do_execute(params, signal, cwd, opts) do
    pattern = Map.get(params, "pattern", "")
    search_path = Map.get(params, "path", ".")
    entry_type = Map.get(params, "type", "all")
    max_depth = Map.get(params, "max_depth")
    sort = Map.get(params, "sort", "path")

    max_results =
      Map.get(params, "max_results", Keyword.get(opts, :max_results, @default_max_results))

    flags = %{
      hidden: Map.get(params, "hidden", false) == true,
      no_ignore: Map.get(params, "no_ignore", false) == true
    }

    with :ok <- validate_sort(sort),
         {:ok, paths, missing} <-
           PathHelpers.resolve_search_paths(search_path, cwd, [:directory]),
         :ok <- check_abort(signal),
         {:ok, files} <-
           Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, files} ->
             case find_files(
                    pattern,
                    path,
                    entry_type,
                    max_depth,
                    max_results,
                    flags,
                    signal,
                    cwd,
                    opts
                  ) do
               {:ok, found} -> {:cont, {:ok, found ++ files}}
               {:error, _} = error -> {:halt, error}
             end
           end),
         files = Enum.uniq(files),
         :ok <- check_candidate_limit(files) do
      files
      |> format_results(cwd, max_results, sort)
      |> PathHelpers.with_missing_paths(missing)
    end
  end

  defp validate_sort(sort) when sort in ["mtime", "path"], do: :ok
  defp validate_sort(_), do: {:error, "sort must be mtime or path"}

  defp check_candidate_limit(files) do
    if length(files) > @max_candidates,
      do: {:error, "Find exceeds #{@max_candidates} candidates; narrow path or pattern"},
      else: :ok
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
         flags,
         signal,
         cwd,
         opts
       ) do
    case Keyword.get(opts, :fd_available?, fd_available?()) do
      true ->
        find_with_fd(
          pattern,
          search_path,
          entry_type,
          max_depth,
          max_results,
          flags,
          signal,
          cwd,
          opts
        )

      false ->
        find_with_elixir(
          pattern,
          search_path,
          entry_type,
          max_depth,
          max_results,
          flags,
          signal,
          cwd,
          opts
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
         flags,
         signal,
         cwd,
         opts
       ) do
    args = build_fd_args(pattern, search_path, entry_type, max_depth, flags)
    run = Keyword.get(opts, :fd_run_fun, &run_fd/3)

    case run.(args, cwd, signal) do
      {:ok, output} ->
        results =
          output
          |> String.split("\n", trim: true)

        {:ok, results}

      {:error, reason} ->
        # Fall back to Elixir if fd fails
        case find_with_elixir(
               pattern,
               search_path,
               entry_type,
               max_depth,
               max_results,
               flags,
               signal,
               cwd,
               opts
             ) do
          {:error, _} -> {:error, reason}
          result -> result
        end
    end
  end

  defp build_fd_args(pattern, search_path, entry_type, max_depth, flags) do
    # Follow symlinked directories (matches the Elixir fallback). fd respects
    # .gitignore/.ignore rules unless the caller opts out.
    args =
      if flags.no_ignore,
        do: ["--follow", "--no-ignore", "--glob", "--case-sensitive"],
        else: ["--follow", "--glob", "--case-sensitive"]

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

    # This is a safety ceiling, never a result page. Exceeding it fails rather
    # than presenting an arbitrary traversal-order subset as sorted results.
    args = args ++ ["--max-results", to_string(@max_candidates + 1)]
    args = if String.contains?(pattern, "/"), do: args ++ ["--full-path"], else: args
    pattern = if String.contains?(pattern, "/"), do: "**/" <> pattern, else: pattern

    # Hidden files
    args =
      if flags.hidden do
        args ++ ["--hidden"]
      else
        args
      end

    # Pattern and path; `--` keeps a pattern starting with `-` from being
    # parsed as a flag.
    args ++ ["--", pattern, search_path]
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
         _max_results,
         flags,
         signal,
         _cwd,
         opts
       ) do
    glob_patterns = build_glob_patterns(pattern, search_path, max_depth)
    wildcard_fun = Keyword.get(opts, :wildcard_fun, &Path.wildcard/2)
    timeout_ms = Keyword.get(opts, :elixir_timeout_ms, @elixir_find_timeout_ms)

    with :ok <- check_abort(signal),
         {:ok, wildcard_results} <-
           run_wildcard_with_timeout(
             glob_patterns,
             flags.hidden,
             wildcard_fun,
             signal,
             timeout_ms
           ),
         :ok <- check_abort(signal) do
      results =
        wildcard_results
        |> Enum.uniq()
        |> filter_by_type(entry_type)
        |> reject_ignored(search_path, flags.no_ignore)
        |> Enum.sort()

      {:ok, results}
    end
  rescue
    e ->
      {:error, "Find operation failed: #{Exception.message(e)}"}
  end

  defp run_wildcard_with_timeout(patterns, include_hidden, wildcard_fun, signal, timeout_ms) do
    task =
      Task.Supervisor.async_nolink(CodingAgent.TaskSupervisor, fn ->
        Enum.flat_map(patterns, &wildcard_fun.(&1, match_dot: include_hidden))
      end)

    started_at_ms = System.monotonic_time(:millisecond)
    await_wildcard_result(task, signal, timeout_ms, started_at_ms)
  end

  defp await_wildcard_result(task, signal, timeout_ms, started_at_ms) do
    if aborted?(signal) do
      _ = Task.shutdown(task, :brutal_kill)
      {:error, "Operation aborted"}
    else
      case Task.yield(task, 100) do
        {:ok, results} when is_list(results) ->
          {:ok, results}

        {:ok, other} ->
          {:error, "Find operation failed: unexpected wildcard result #{inspect(other)}"}

        {:exit, reason} ->
          {:error, "Find operation failed: #{Exception.format_exit(reason)}"}

        nil ->
          elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

          if elapsed_ms >= timeout_ms do
            _ = Task.shutdown(task, :brutal_kill)
            {:error, "Find operation timed out after #{timeout_ms}ms"}
          else
            await_wildcard_result(task, signal, timeout_ms, started_at_ms)
          end
      end
    end
  end

  defp build_glob_patterns(pattern, search_path, nil) do
    [Path.join([search_path, "**", pattern])]
  end

  # One pattern per level: entries directly under `search_path` are depth 1
  # (fd's `--max-depth` semantics), so depth d means d - 1 directory segments.
  defp build_glob_patterns(pattern, search_path, max_depth)
       when is_integer(max_depth) and max_depth > 0 do
    Enum.map(0..(max_depth - 1), fn dirs ->
      Path.join([search_path | List.duplicate("*", dirs)] ++ [pattern])
    end)
  end

  defp build_glob_patterns(pattern, search_path, _), do: [Path.join(search_path, pattern)]

  defp reject_ignored(paths, _search_path, true), do: paths

  defp reject_ignored(paths, search_path, false),
    do: IgnoreFilter.reject_ignored(paths, search_path)

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

  defp format_results(results, cwd, max_results, sort) do
    # Make paths relative to cwd
    relative_results =
      results
      |> sort_results(cwd, sort)
      |> Enum.map(&make_relative(&1, cwd))

    truncated = length(relative_results) > max_results
    relative_results = Enum.take(relative_results, max_results)
    count = length(relative_results)

    text =
      if count == 0 do
        "No files found matching the pattern."
      else
        header =
          if truncated do
            "Found #{count} matches (limited to #{max_results}); increase max_results or narrow path/pattern for more:\n\n"
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

  defp sort_results(results, cwd, "path"),
    do: Enum.sort_by(results, &make_relative(&1, cwd))

  defp sort_results(results, cwd, "mtime") do
    results
    |> Enum.map(fn path ->
      mtime =
        case File.stat(Path.expand(path, cwd), time: :posix) do
          {:ok, stat} -> stat.mtime
          _ -> 0
        end

      {path, mtime}
    end)
    |> Enum.sort_by(fn {path, mtime} -> {-mtime, make_relative(path, cwd)} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp make_relative(path, cwd), do: Path.relative_to(path, cwd)
end
