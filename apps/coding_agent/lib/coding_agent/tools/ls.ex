defmodule CodingAgent.Tools.Ls do
  @moduledoc """
  List directory contents tool for the coding agent.

  Lists files and directories with support for:
  - Hidden files (dot files)
  - Long format with metadata (size, modified time, permissions)
  - Recursive listing with depth control
  - Entry limits to prevent overwhelming output
  """

  import Bitwise

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @default_max_entries 500

  @doc """
  Returns the Ls tool definition.

  ## Options

  - `:max_entries` - Maximum entries to return (default: 500)
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "ls",
      description:
        "List directory contents. Shows files and directories with optional metadata.",
      label: "List Directory",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Directory path to list (relative to cwd or absolute). Defaults to cwd."
          },
          "all" => %{
            "type" => "boolean",
            "description" => "Include hidden files (starting with dot). Defaults to false."
          },
          "long" => %{
            "type" => "boolean",
            "description" =>
              "Show detailed metadata (size, modified time, type indicator). Defaults to false."
          },
          "recursive" => %{
            "type" => "boolean",
            "description" => "List subdirectories recursively. Defaults to false."
          },
          "max_depth" => %{
            "type" => "integer",
            "description" => "Maximum depth for recursive listing. Only used when recursive is true."
          },
          "max_entries" => %{
            "type" => "integer",
            "description" => "Maximum number of entries to return. Defaults to 500."
          }
        },
        "required" => []
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Execute the ls tool.

  ## Parameters

  - `tool_call_id` - Unique identifier for this tool invocation
  - `params` - Parameters map with optional "path", "all", "long", "recursive", "max_depth", "max_entries"
  - `signal` - Abort signal for cancellation (can be nil)
  - `on_update` - Callback for streaming partial results (unused for ls)
  - `cwd` - Current working directory
  - `opts` - Tool options

  ## Returns

  - `AgentToolResult.t()` - Result with directory listing
  - `{:error, term()}` - Error if directory cannot be listed
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

    if aborted?(signal) do
      {:error, "Operation aborted"}
    else
      do_execute(params, signal, cwd, opts)
    end
  end

  defp do_execute(params, signal, cwd, opts) do
    path = Map.get(params, "path", "")
    show_all = Map.get(params, "all", false)
    long_format = Map.get(params, "long", false)
    recursive = Map.get(params, "recursive", false)
    max_depth = Map.get(params, "max_depth")
    max_entries = Map.get(params, "max_entries", Keyword.get(opts, :max_entries, @default_max_entries))

    with {:ok, resolved_path} <- resolve_path(path, cwd),
         {:ok, _stat} <- check_directory_access(resolved_path),
         :ok <- check_abort(signal) do
      list_directory(resolved_path, show_all, long_format, recursive, max_depth, max_entries)
    end
  end

  # ============================================================================
  # Path Resolution
  # ============================================================================

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

  # ============================================================================
  # Directory Access Check
  # ============================================================================

  defp check_directory_access(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        {:ok, stat}

      {:ok, %File.Stat{type: :regular}} ->
        {:error, "Path is a file, not a directory: #{path}"}

      {:ok, %File.Stat{type: type}} ->
        {:error, "Path is not a directory (#{type}): #{path}"}

      {:error, :enoent} ->
        {:error, "Directory not found: #{path}"}

      {:error, :eacces} ->
        {:error, "Permission denied: #{path}"}

      {:error, reason} ->
        {:error, "Cannot access directory: #{path} (#{reason})"}
    end
  end

  # ============================================================================
  # Directory Listing
  # ============================================================================

  defp list_directory(path, show_all, long_format, recursive, max_depth, max_entries) do
    case collect_entries(path, show_all, recursive, max_depth, max_entries, 0, path) do
      {:ok, entries, total_count, truncated} ->
        # Sort entries: directories first, then files, alphabetically within each group
        sorted_entries = sort_entries(entries)

        # Format output
        output = format_entries(sorted_entries, long_format, path, truncated, total_count, max_entries)

        %AgentToolResult{
          content: [%TextContent{text: output}],
          details: %{
            path: path,
            total_entries: total_count,
            shown_entries: length(sorted_entries),
            truncated: truncated,
            recursive: recursive
          }
        }

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_entries(path, show_all, recursive, max_depth, max_entries, current_depth, base_path) do
    case File.ls(path) do
      {:ok, names} ->
        # Filter hidden files if not showing all
        filtered_names =
          if show_all do
            names
          else
            Enum.reject(names, &String.starts_with?(&1, "."))
          end

        # Build entry list with metadata
        entries =
          filtered_names
          |> Enum.map(fn name ->
            full_path = Path.join(path, name)
            relative_path = Path.relative_to(full_path, base_path)

            case File.stat(full_path) do
              {:ok, stat} ->
                %{
                  name: name,
                  relative_path: relative_path,
                  full_path: full_path,
                  type: stat.type,
                  size: stat.size,
                  mtime: stat.mtime,
                  mode: stat.mode,
                  depth: current_depth
                }

              {:error, _} ->
                # Entry exists but can't stat (permission issue, etc.)
                %{
                  name: name,
                  relative_path: relative_path,
                  full_path: full_path,
                  type: :unknown,
                  size: 0,
                  mtime: nil,
                  mode: nil,
                  depth: current_depth
                }
            end
          end)

        # Check if we need to recurse
        if recursive && should_continue_recursion?(current_depth, max_depth) do
          collect_recursive(entries, show_all, max_depth, max_entries, current_depth, base_path)
        else
          total = length(entries)
          truncated = total > max_entries

          final_entries =
            if truncated do
              Enum.take(entries, max_entries)
            else
              entries
            end

          {:ok, final_entries, total, truncated}
        end

      {:error, reason} ->
        {:error, "Failed to list directory #{path}: #{reason}"}
    end
  end

  defp should_continue_recursion?(_current_depth, nil), do: true
  defp should_continue_recursion?(current_depth, max_depth), do: current_depth < max_depth

  defp collect_recursive(entries, show_all, max_depth, max_entries, current_depth, base_path) do
    # Start with current entries
    {final_entries, total_count, truncated} =
      Enum.reduce_while(entries, {[], 0, false}, fn entry, {acc_entries, acc_count, _truncated} ->
        new_count = acc_count + 1

        if new_count > max_entries do
          {:halt, {acc_entries, new_count, true}}
        else
          new_entries = acc_entries ++ [entry]

          # Recurse into directories
          if entry.type == :directory do
            case collect_entries(
                   entry.full_path,
                   show_all,
                   true,
                   max_depth,
                   max_entries - new_count,
                   current_depth + 1,
                   base_path
                 ) do
              {:ok, sub_entries, sub_total, sub_truncated} ->
                combined_count = new_count + sub_total

                if combined_count > max_entries do
                  take_count = max_entries - new_count
                  {:halt, {new_entries ++ Enum.take(sub_entries, take_count), combined_count, true}}
                else
                  {:cont, {new_entries ++ sub_entries, combined_count, sub_truncated}}
                end

              {:error, _reason} ->
                # Skip directories we can't read
                {:cont, {new_entries, new_count, false}}
            end
          else
            {:cont, {new_entries, new_count, false}}
          end
        end
      end)

    {:ok, final_entries, total_count, truncated}
  end

  # ============================================================================
  # Sorting
  # ============================================================================

  defp sort_entries(entries) do
    # Group by depth first, then sort within each group
    entries
    |> Enum.group_by(& &1.depth)
    |> Enum.sort_by(fn {depth, _} -> depth end)
    |> Enum.flat_map(fn {_depth, group_entries} ->
      # Within each depth level, sort directories first, then files, alphabetically
      group_entries
      |> Enum.sort_by(fn entry ->
        type_order = if entry.type == :directory, do: 0, else: 1
        {type_order, String.downcase(entry.name)}
      end)
    end)
  end

  # ============================================================================
  # Formatting
  # ============================================================================

  defp format_entries(entries, long_format, base_path, truncated, total_count, max_entries) do
    lines =
      if long_format do
        format_long(entries)
      else
        format_short(entries)
      end

    header = "Directory: #{base_path}\n"

    footer =
      cond do
        truncated ->
          "\n[Showing #{length(entries)} of #{total_count} entries. Limit: #{max_entries}]"

        length(entries) == 0 ->
          "\n(empty directory)"

        true ->
          "\n#{length(entries)} entries"
      end

    header <> lines <> footer
  end

  defp format_short(entries) do
    entries
    |> Enum.map(fn entry ->
      indicator = type_indicator(entry.type)
      "#{indicator} #{entry.relative_path}"
    end)
    |> Enum.join("\n")
  end

  defp format_long(entries) do
    entries
    |> Enum.map(fn entry ->
      indicator = type_indicator(entry.type)
      size = format_size(entry.size)
      mtime = format_mtime(entry.mtime)
      permissions = format_permissions(entry.mode, entry.type)

      "#{indicator} #{permissions} #{size} #{mtime} #{entry.relative_path}"
    end)
    |> Enum.join("\n")
  end

  defp type_indicator(:directory), do: "d"
  defp type_indicator(:regular), do: "-"
  defp type_indicator(:symlink), do: "l"
  defp type_indicator(:device), do: "c"
  defp type_indicator(:other), do: "?"
  defp type_indicator(:unknown), do: "?"
  defp type_indicator(_), do: "?"

  defp format_size(size) when is_integer(size) do
    cond do
      size >= 1_073_741_824 -> "#{Float.round(size / 1_073_741_824, 1)}G"
      size >= 1_048_576 -> "#{Float.round(size / 1_048_576, 1)}M"
      size >= 1024 -> "#{Float.round(size / 1024, 1)}K"
      true -> "#{size}B"
    end
    |> String.pad_leading(8)
  end

  defp format_size(_), do: String.pad_leading("?", 8)

  defp format_mtime(nil), do: String.pad_leading("?", 16)

  defp format_mtime({{year, month, day}, {hour, minute, _second}}) do
    "#{year}-#{pad2(month)}-#{pad2(day)} #{pad2(hour)}:#{pad2(minute)}"
  end

  defp format_mtime(_), do: String.pad_leading("?", 16)

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"

  defp format_permissions(nil, _type), do: "---------"

  defp format_permissions(mode, type) when is_integer(mode) do
    # Extract permission bits (last 9 bits)
    user = permission_triplet((mode >>> 6) &&& 0o7)
    group = permission_triplet((mode >>> 3) &&& 0o7)
    other = permission_triplet(mode &&& 0o7)

    prefix =
      case type do
        :directory -> "d"
        :symlink -> "l"
        _ -> "-"
      end

    "#{prefix}#{user}#{group}#{other}"
  end

  defp format_permissions(_, _), do: "----------"

  defp permission_triplet(bits) do
    r = if (bits &&& 0o4) != 0, do: "r", else: "-"
    w = if (bits &&& 0o2) != 0, do: "w", else: "-"
    x = if (bits &&& 0o1) != 0, do: "x", else: "-"
    "#{r}#{w}#{x}"
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
