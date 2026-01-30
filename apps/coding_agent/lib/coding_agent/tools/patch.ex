defmodule CodingAgent.Tools.Patch do
  @moduledoc """
  Patch tool for the coding agent.

  Applies a unified patch format similar to apply_patch.

  ## Security Features

  - Path traversal validation (blocks `..` escaping outside cwd for relative paths)
  - Null byte injection protection
  - Special file type detection (symlinks, devices, etc.)
  - Path length validation
  - File size limits for safe operation

  ## Supported Operations

  - `*** Add File: <path>` - Create a new file with specified content
  - `*** Delete File: <path>` - Remove an existing file
  - `*** Update File: <path>` - Modify existing file with hunks
  - `*** Move to: <path>` - Rename/move a file (after Update File)

  ## Patch Format

  ```
  *** Begin Patch
  *** Update File: path/to/file.txt
  @@ context description
   context line (keep)
  -removed line
  +added line
   context line (keep)
  *** End Patch
  ```
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  # Maximum file size to process (10 MB)
  @max_file_size 10 * 1024 * 1024

  # Maximum path length (POSIX PATH_MAX is typically 4096)
  @max_path_length 4096

  @doc """
  Returns the patch tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "patch",
      description: "Apply a patch describing file edits, additions, and deletions.",
      label: "Apply Patch",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "patch_text" => %{
            "type" => "string",
            "description" => "Full patch text to apply"
          }
        },
        "required" => ["patch_text"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Execute the patch tool.

  Parses and applies a patch in a unified-diff-like format. Supports three
  operation types:
  - Update File: Modify existing file content with hunks
  - Add File: Create a new file with specified content
  - Delete File: Remove an existing file

  ## Parameters

  - `tool_call_id` - Unique identifier for this tool invocation
  - `params` - Parameters map with "patch_text" containing the full patch
  - `signal` - Abort signal for cancellation (can be nil)
  - `on_update` - Callback for streaming partial results (unused for patch)
  - `cwd` - Current working directory for resolving relative paths
  - `opts` - Tool options:
    - `:allow_symlinks` - Whether to allow modifying symlinks (default: false)
    - `:allow_path_traversal` - Whether to allow paths that escape cwd (default: false)

  ## Returns

  - `AgentToolResult.t()` - Result with summary of changes applied
  - `{:error, term()}` - Error if patch parsing or application fails
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      with {:ok, patch_text} <- get_patch_text(params),
           {:ok, operations} <- parse_patch(patch_text),
           :ok <- validate_operations(operations, cwd, opts),
           {:ok, summary} <- apply_operations(operations, cwd, signal, opts) do
        %AgentToolResult{
          content: [%TextContent{text: summary.output}],
          details: summary.details
        }
      end
    end
  end

  # ============================================================================
  # Parameter Extraction and Validation
  # ============================================================================

  defp get_patch_text(%{"patch_text" => patch_text}) when is_binary(patch_text) do
    if String.trim(patch_text) == "" do
      {:error, "patch_text is required"}
    else
      {:ok, patch_text}
    end
  end

  defp get_patch_text(%{"patch_text" => _}), do: {:error, "patch_text must be a string"}
  defp get_patch_text(_), do: {:error, "patch_text is required"}

  @doc """
  Validates all operations in a patch before applying any of them.
  This prevents partial application of patches.
  """
  @spec validate_operations([map()], String.t(), keyword()) :: :ok | {:error, String.t()}
  def validate_operations(operations, cwd, opts) do
    Enum.reduce_while(operations, :ok, fn op, _acc ->
      case validate_operation(op, cwd, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_operation(%{type: :add, path: path}, cwd, opts) do
    with :ok <- validate_path_security(path),
         {:ok, resolved} <- resolve_and_validate_path(path, cwd, opts) do
      case file_exists?(resolved) do
        {:ok, false} -> :ok
        {:ok, true} -> {:error, "File already exists: #{resolved}"}
        {:error, reason} -> {:error, format_error(reason, resolved)}
      end
    end
  end

  defp validate_operation(%{type: :delete, path: path}, cwd, opts) do
    with :ok <- validate_path_security(path),
         {:ok, resolved} <- resolve_and_validate_path(path, cwd, opts) do
      case file_exists?(resolved) do
        {:ok, true} -> :ok
        {:ok, false} -> {:error, "File not found: #{resolved}"}
        {:error, reason} -> {:error, format_error(reason, resolved)}
      end
    end
  end

  defp validate_operation(%{type: :update, path: path, move_to: move_to}, cwd, opts) do
    with :ok <- validate_path_security(path),
         :ok <- validate_move_to_path(move_to, cwd, opts),
         {:ok, resolved} <- resolve_and_validate_path(path, cwd, opts) do
      case file_exists?(resolved) do
        {:ok, true} -> validate_file_size(resolved)
        {:ok, false} -> {:error, "File not found: #{resolved}"}
        {:error, reason} -> {:error, format_error(reason, resolved)}
      end
    end
  end

  defp validate_move_to_path(nil, _cwd, _opts), do: :ok

  defp validate_move_to_path(path, cwd, opts) do
    with :ok <- validate_path_security(path),
         {:ok, _resolved} <- resolve_and_validate_path(path, cwd, opts) do
      :ok
    end
  end

  defp validate_file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > @max_file_size ->
        {:error,
         "File too large (#{format_size(size)}). Maximum supported size is #{format_size(@max_file_size)}"}

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, format_error(reason, path)}
    end
  end

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  # ============================================================================
  # Path Security Validation
  # ============================================================================

  @spec validate_path_security(String.t()) :: :ok | {:error, String.t()}
  defp validate_path_security(path) do
    cond do
      # Check for null bytes (injection attack)
      String.contains?(path, <<0>>) ->
        {:error, "Path contains null bytes which is not allowed"}

      # Check path length
      byte_size(path) > @max_path_length ->
        {:error, "Path exceeds maximum length of #{@max_path_length} characters"}

      # Check for empty path
      String.trim(path) == "" ->
        {:error, "Path cannot be empty"}

      # Check for empty path components (e.g., "foo//bar")
      String.contains?(path, "//") ->
        {:error, "Path contains empty components (consecutive slashes)"}

      true ->
        :ok
    end
  end

  @spec resolve_and_validate_path(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp resolve_and_validate_path(path, cwd, opts) do
    allow_traversal = Keyword.get(opts, :allow_path_traversal, false)
    allow_symlinks = Keyword.get(opts, :allow_symlinks, false)

    resolved_path = resolve_path(path, cwd)

    with :ok <- validate_path_traversal(path, resolved_path, cwd, allow_traversal),
         :ok <- validate_target_type(resolved_path, allow_symlinks) do
      {:ok, resolved_path}
    end
  end

  # Validate that relative paths don't escape the cwd
  @spec validate_path_traversal(String.t(), String.t(), String.t(), boolean()) ::
          :ok | {:error, String.t()}
  defp validate_path_traversal(_original_path, _resolved_path, _cwd, true = _allow_traversal) do
    :ok
  end

  defp validate_path_traversal(original_path, resolved_path, cwd, false = _allow_traversal) do
    # Only check for relative paths
    if Path.type(original_path) == :absolute do
      :ok
    else
      # Normalize cwd for comparison
      normalized_cwd = Path.expand(cwd)

      if String.starts_with?(resolved_path, normalized_cwd <> "/") or
           resolved_path == normalized_cwd do
        :ok
      else
        {:error,
         "Path traversal not allowed: resolved path '#{resolved_path}' is outside working directory '#{normalized_cwd}'"}
      end
    end
  end

  # Validate the target file type (check for symlinks, devices, etc.)
  @spec validate_target_type(String.t(), boolean()) :: :ok | {:error, String.t()}
  defp validate_target_type(path, allow_symlinks) do
    # Use lstat to get info about the symlink itself, not the target
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} when not allow_symlinks ->
        {:error, "Cannot modify symlink: #{path}. Use :allow_symlinks option to override."}

      {:ok, %File.Stat{type: :device}} ->
        {:error, "Cannot modify device file: #{path}"}

      {:ok, %File.Stat{type: :directory}} ->
        {:error, "Cannot modify directory: #{path}. Please specify a file path."}

      {:ok, %File.Stat{type: :other}} ->
        {:error, "Cannot modify special file: #{path}"}

      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        # Symlinks allowed - validate the target
        validate_symlink_target(path)

      {:error, :enoent} ->
        # File doesn't exist yet - this is fine for add operations
        # But check if parent is a symlink when symlinks are not allowed
        if allow_symlinks do
          :ok
        else
          validate_parent_not_symlink(path)
        end

      {:error, _reason} ->
        # Other errors will be handled during actual operation
        :ok
    end
  end

  # Validate that a symlink points to a regular file or non-existent path
  defp validate_symlink_target(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        {:error, "Symlink points to a directory: #{path}"}

      {:ok, %File.Stat{type: :device}} ->
        {:error, "Symlink points to a device: #{path}"}

      {:error, :enoent} ->
        # Broken symlink - allow for delete
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  # Check that parent directories are not symlinks (when symlinks not allowed)
  defp validate_parent_not_symlink(path) do
    parent = Path.dirname(path)

    case File.lstat(parent) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error,
         "Parent directory is a symlink: #{parent}. Use :allow_symlinks option to override."}

      _ ->
        :ok
    end
  end

  # ============================================================================
  # Patch Parsing
  # ============================================================================

  defp parse_patch(text) do
    lines = String.split(text, ~r/\r?\n/, trim: false)
    {ops, _idx} = parse_lines(lines, 0, [])

    if ops == [] do
      {:error, "No patch operations found"}
    else
      {:ok, Enum.reverse(ops)}
    end
  end

  defp parse_lines(lines, idx, ops) do
    if idx >= length(lines) do
      {ops, idx}
    else
      line = Enum.at(lines, idx)

      cond do
        line == "*** Begin Patch" ->
          parse_lines(lines, idx + 1, ops)

        line == "*** End Patch" ->
          {ops, idx + 1}

        String.starts_with?(line, "*** Update File:") ->
          {op, next_idx} = parse_update(lines, idx)
          parse_lines(lines, next_idx, [op | ops])

        String.starts_with?(line, "*** Add File:") ->
          {op, next_idx} = parse_add(lines, idx)
          parse_lines(lines, next_idx, [op | ops])

        String.starts_with?(line, "*** Delete File:") ->
          {op, next_idx} = parse_delete(lines, idx)
          parse_lines(lines, next_idx, [op | ops])

        true ->
          parse_lines(lines, idx + 1, ops)
      end
    end
  end

  defp parse_update(lines, idx) do
    line = Enum.at(lines, idx)
    path = line |> String.replace_prefix("*** Update File:", "") |> String.trim()
    idx = idx + 1

    {move_to, idx} =
      case Enum.at(lines, idx) do
        nil ->
          {nil, idx}

        next when is_binary(next) ->
          if String.starts_with?(next, "*** Move to:") do
            move_path = next |> String.replace_prefix("*** Move to:", "") |> String.trim()
            {move_path, idx + 1}
          else
            {nil, idx}
          end

        _ ->
          {nil, idx}
      end

    {hunks, next_idx} = parse_hunks(lines, idx, [])

    {%{type: :update, path: path, move_to: move_to, hunks: Enum.reverse(hunks)}, next_idx}
  end

  defp parse_hunks(lines, idx, hunks) do
    if idx >= length(lines) do
      {hunks, idx}
    else
      line = Enum.at(lines, idx)

      cond do
        String.starts_with?(line, "***") ->
          {hunks, idx}

        String.starts_with?(line, "@@") ->
          {hunk, next_idx} = parse_hunk(lines, idx + 1, [])
          parse_hunks(lines, next_idx, [hunk | hunks])

        true ->
          parse_hunks(lines, idx + 1, hunks)
      end
    end
  end

  defp parse_hunk(lines, idx, changes) do
    if idx >= length(lines) do
      {%{changes: Enum.reverse(changes)}, idx}
    else
      line = Enum.at(lines, idx)

      cond do
        String.starts_with?(line, "@@") or String.starts_with?(line, "***") ->
          {%{changes: Enum.reverse(changes)}, idx}

        String.starts_with?(line, " ") ->
          content = String.slice(line, 1..-1//1)
          parse_hunk(lines, idx + 1, [%{type: :keep, content: content} | changes])

        String.starts_with?(line, "-") ->
          content = String.slice(line, 1..-1//1)
          parse_hunk(lines, idx + 1, [%{type: :remove, content: content} | changes])

        String.starts_with?(line, "+") ->
          content = String.slice(line, 1..-1//1)
          parse_hunk(lines, idx + 1, [%{type: :add, content: content} | changes])

        true ->
          parse_hunk(lines, idx + 1, changes)
      end
    end
  end

  defp parse_add(lines, idx) do
    line = Enum.at(lines, idx)
    path = line |> String.replace_prefix("*** Add File:", "") |> String.trim()

    {content_lines, next_idx} = parse_add_lines(lines, idx + 1, [])
    content = Enum.join(content_lines, "\n")

    {%{type: :add, path: path, content: content}, next_idx}
  end

  defp parse_add_lines(lines, idx, acc) do
    if idx >= length(lines) do
      {Enum.reverse(acc), idx}
    else
      line = Enum.at(lines, idx)

      if String.starts_with?(line, "***") do
        {Enum.reverse(acc), idx}
      else
        if String.starts_with?(line, "+") do
          content = String.slice(line, 1..-1//1)
          parse_add_lines(lines, idx + 1, [content | acc])
        else
          parse_add_lines(lines, idx + 1, acc)
        end
      end
    end
  end

  defp parse_delete(lines, idx) do
    line = Enum.at(lines, idx)
    path = line |> String.replace_prefix("*** Delete File:", "") |> String.trim()
    {%{type: :delete, path: path}, idx + 1}
  end

  # ============================================================================
  # Patch Application
  # ============================================================================

  defp apply_operations(operations, cwd, signal, opts) do
    result =
      Enum.reduce_while(operations, %{changed: [], additions: 0, removals: 0}, fn op, acc ->
        if AbortSignal.aborted?(signal) do
          {:halt, {:error, "Operation aborted"}}
        else
          case apply_operation(op, cwd, signal, opts) do
            {:ok, info} ->
              updated = %{
                changed: acc.changed ++ info.changed,
                additions: acc.additions + info.additions,
                removals: acc.removals + info.removals
              }

              {:cont, updated}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end
      end)

    case result do
      {:error, reason} ->
        {:error, reason}

      %{changed: changed, additions: adds, removals: removes} ->
        output =
          "Patch applied successfully. #{length(changed)} files changed, #{adds} additions, #{removes} removals"

        {:ok,
         %{
           output: output,
           details: %{changed: changed, additions: adds, removals: removes}
         }}
    end
  end

  defp apply_operation(%{type: :add, path: path, content: content}, cwd, signal, _opts) do
    resolved = resolve_path(path, cwd)

    with :ok <- check_abort(signal),
         :ok <- ensure_parent_dir(resolved),
         :ok <- safe_write_file(resolved, content, signal) do
      additions = count_lines(content)
      {:ok, %{changed: [resolved], additions: additions, removals: 0}}
    end
  end

  defp apply_operation(%{type: :delete, path: path}, cwd, signal, _opts) do
    resolved = resolve_path(path, cwd)

    with :ok <- check_abort(signal),
         {:ok, content} <- safe_read_file(resolved),
         :ok <- File.rm(resolved) do
      removals = count_lines(content)
      {:ok, %{changed: [resolved], additions: 0, removals: removals}}
    else
      {:error, :enoent} -> {:error, "File not found: #{resolved}"}
      {:error, reason} -> {:error, format_error(reason, resolved)}
    end
  end

  defp apply_operation(
         %{type: :update, path: path, move_to: move_to, hunks: hunks},
         cwd,
         signal,
         _opts
       ) do
    resolved = resolve_path(path, cwd)
    target = if move_to, do: resolve_path(move_to, cwd), else: resolved

    with :ok <- check_abort(signal),
         {:ok, content} <- safe_read_file(resolved),
         :ok <- check_abort(signal),
         {:ok, new_content, adds, removes} <- apply_hunks(content, hunks, signal),
         :ok <- check_abort(signal),
         :ok <- ensure_parent_dir(target),
         :ok <- safe_write_file(target, new_content, signal) do
      if target != resolved do
        _ = File.rm(resolved)
      end

      {:ok, %{changed: [target], additions: adds, removals: removes}}
    else
      {:error, :enoent} -> {:error, "File not found: #{resolved}"}
      {:error, reason} -> {:error, format_error(reason, resolved)}
    end
  end

  # Safe file operations with better error handling

  defp safe_read_file(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, :eacces} ->
        {:error, "Permission denied: #{path}"}

      {:error, :eisdir} ->
        {:error, "Cannot read directory as file: #{path}"}

      {:error, reason} ->
        {:error, "Failed to read file #{path}: #{inspect(reason)}"}
    end
  end

  defp safe_write_file(path, content, signal) do
    # Check abort before write
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      case File.write(path, content) do
        :ok ->
          :ok

        {:error, :eacces} ->
          {:error, "Permission denied: #{path}"}

        {:error, :enospc} ->
          {:error, "No space left on device when writing: #{path}"}

        {:error, :erofs} ->
          {:error, "Read-only file system: #{path}"}

        {:error, :edquot} ->
          {:error, "Disk quota exceeded when writing: #{path}"}

        {:error, reason} ->
          {:error, "Failed to write file #{path}: #{inspect(reason)}"}
      end
    end
  end

  defp apply_hunks(content, hunks, signal) do
    lines = String.split(content, ~r/\r?\n/, trim: false)
    newline = if String.contains?(content, "\r\n"), do: "\r\n", else: "\n"

    result =
      Enum.reduce_while(hunks, {lines, 0, 0}, fn hunk, {acc_lines, acc_adds, acc_removes} ->
        if AbortSignal.aborted?(signal) do
          {:halt, {:error, "Operation aborted"}}
        else
          case apply_hunk(acc_lines, hunk) do
            {:ok, new_lines, adds, removes} ->
              {:cont, {new_lines, acc_adds + adds, acc_removes + removes}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end
      end)

    case result do
      {:error, reason} ->
        {:error, reason}

      {updated_lines, adds, removes} ->
        {:ok, Enum.join(updated_lines, newline), adds, removes}
    end
  end

  defp apply_hunk(lines, %{changes: changes}) do
    pattern =
      changes
      |> Enum.filter(fn change -> change.type in [:keep, :remove] end)
      |> Enum.map(& &1.content)

    start_idx = find_pattern(lines, pattern)

    if start_idx == nil do
      # Provide more helpful error message
      context_preview =
        pattern
        |> Enum.take(3)
        |> Enum.map(&"  #{inspect(&1)}")
        |> Enum.join("\n")

      {:error,
       "Context not found for patch hunk. Expected context starting with:\n#{context_preview}"}
    else
      do_apply_changes(lines, changes, start_idx)
    end
  end

  defp do_apply_changes(lines, changes, start_idx) do
    Enum.reduce_while(changes, {lines, start_idx, 0, 0}, fn change,
                                                           {acc_lines, idx, adds, removes} ->
      case change.type do
        :keep ->
          {:cont, {acc_lines, idx + 1, adds, removes}}

        :remove ->
          if idx >= length(acc_lines) do
            {:halt,
             {:error, "Patch remove out of bounds at index #{idx} (file has #{length(acc_lines)} lines)"}}
          else
            {:cont, {List.delete_at(acc_lines, idx), idx, adds, removes + 1}}
          end

        :add ->
          {:cont, {List.insert_at(acc_lines, idx, change.content), idx + 1, adds + 1, removes}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      {final_lines, _idx, adds, removes} -> {:ok, final_lines, adds, removes}
    end
  end

  defp find_pattern(lines, pattern) do
    plen = length(pattern)

    cond do
      plen == 0 ->
        # Empty pattern matches at end of file
        length(lines)

      length(lines) < plen ->
        nil

      true ->
        0..(length(lines) - plen)
        |> Enum.find(fn idx -> Enum.slice(lines, idx, plen) == pattern end)
    end
  end

  defp resolve_path(path, cwd) do
    expanded = expand_home(path)

    if Path.type(expanded) == :absolute do
      expanded
    else
      Path.join(cwd, expanded) |> Path.expand()
    end
  end

  defp expand_home("~" <> rest), do: Path.expand("~") <> rest
  defp expand_home(path), do: path

  defp ensure_parent_dir(path) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok ->
        :ok

      {:error, :eacces} ->
        {:error, "Permission denied when creating directory: #{dir}"}

      {:error, :enospc} ->
        {:error, "No space left on device when creating directory: #{dir}"}

      {:error, reason} ->
        {:error, "Failed to create directory #{dir}: #{inspect(reason)}"}
    end
  end

  defp file_exists?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, true}
      {:ok, %File.Stat{type: type}} -> {:error, "Path is not a regular file (is #{type}): #{path}"}
      {:error, :enoent} -> {:ok, false}
      {:error, :eacces} -> {:error, "Permission denied: #{path}"}
      {:error, reason} -> {:error, "Failed to check file: #{inspect(reason)}"}
    end
  end

  defp count_lines(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/, trim: false)
    |> length()
  end

  defp check_abort(nil), do: :ok

  defp check_abort(signal) when is_reference(signal) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      :ok
    end
  end

  defp format_error(reason, _path) when is_binary(reason), do: reason
  defp format_error(:eacces, path), do: "Permission denied: #{path}"
  defp format_error(:enoent, path), do: "File not found: #{path}"
  defp format_error(:enospc, path), do: "No space left on device: #{path}"
  defp format_error(:erofs, path), do: "Read-only file system: #{path}"
  defp format_error(:edquot, path), do: "Disk quota exceeded: #{path}"
  defp format_error(:eisdir, path), do: "Is a directory: #{path}"
  defp format_error(:enotdir, path), do: "Not a directory in path: #{path}"
  defp format_error(reason, path), do: "Failed to apply patch for #{path}: #{inspect(reason)}"
end
