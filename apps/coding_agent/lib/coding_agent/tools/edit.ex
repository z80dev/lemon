defmodule CodingAgent.Tools.Edit do
  @moduledoc """
  Edit (text replacement) tool for the coding agent.

  This tool replaces exact text in a file. The old_text must match exactly
  and uniquely in the file. Supports fuzzy matching for common character
  substitutions (smart quotes, unicode dashes, etc.).

  ## Features

  - UTF-8 BOM handling (preserves BOM if present)
  - Line ending detection and preservation (CRLF/LF)
  - Fuzzy matching for common character variations
  - Uniqueness validation (text must occur exactly once)
  - Diff generation with context lines
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @doc """
  Returns the tool definition for the edit tool.

  ## Parameters

    - `cwd` - Current working directory for resolving relative paths
    - `opts` - Optional configuration (reserved for future use)
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "edit",
      description:
        "Replace exact text in a file. The old_text must match exactly and uniquely in the file.",
      label: "Edit File",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "The path to the file to edit"},
          "old_text" => %{
            "type" => "string",
            "description" => "The exact text to find and replace (must be unique in the file)"
          },
          "new_text" => %{"type" => "string", "description" => "The replacement text"}
        },
        "required" => ["path", "old_text", "new_text"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Execute the edit tool.

  Replaces exact text in a file, handling BOM, line endings, and fuzzy matching.
  """
  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          String.t(),
          keyword()
        ) :: AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      path = params["path"]
      old_text = params["old_text"]
      new_text = params["new_text"]

      # Parameter validation
      result =
        with :ok <- validate_required_param(path, "path"),
             :ok <- validate_required_param(old_text, "old_text"),
             :ok <- validate_required_param(new_text, "new_text") do
          do_execute(path, old_text, new_text, signal, cwd, opts)
        end

      case result do
        {:error, :aborted} -> {:error, "Operation aborted"}
        other -> other
      end
    end
  end

  defp do_execute(path, old_text, new_text, signal, cwd, opts) do
    resolved_path = resolve_path(path, cwd, opts)

    with :ok <- check_aborted(signal),
         :ok <- check_file_access(resolved_path),
         {:ok, raw_content} <- File.read(resolved_path),
         {bom, content} <- strip_bom(raw_content),
         line_ending <- detect_line_ending(content),
         normalized_content <- normalize_to_lf(content),
         normalized_old_text <- normalize_to_lf(old_text),
         {:ok, match_index, match_length} <-
           fuzzy_find_text(normalized_content, normalized_old_text),
         :ok <-
           check_uniqueness(normalized_content, normalized_old_text, match_index, match_length),
         {:ok, new_content} <-
           perform_replacement(normalized_content, match_index, match_length, new_text),
         :ok <- check_content_changed(normalized_content, new_content),
         :ok <- check_aborted(signal),
         final_content <- finalize_content(new_content, line_ending, bom),
         :ok <- File.write(resolved_path, final_content) do
      diff = generate_diff(content, new_content)
      first_changed_line = find_first_changed_line(content, new_content)

      %AgentToolResult{
        content: [
          %TextContent{
            type: :text,
            text: "Successfully replaced text in #{path}.\n\n#{diff}"
          }
        ],
        details: %{diff: diff, first_changed_line: first_changed_line}
      }
    else
      {:error, :enoent} ->
        {:error, "File not found: #{path}"}

      {:error, :eacces} ->
        {:error, "Permission denied: #{path}"}

      {:error, :not_found} ->
        {:error, "Could not find the exact text to replace. The text must match exactly."}

      {:error, {:multiple_occurrences, count}} ->
        {:error, "Found #{count} occurrences of the text. The text to replace must be unique."}

      {:error, :no_change} ->
        {:error, "No changes made. The replacement produces identical content."}

      {:error, :aborted} ->
        {:error, "Operation aborted"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to edit file: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # Parameter Validation
  # ============================================================================

  @spec validate_required_param(any(), String.t()) :: :ok | {:error, String.t()}
  defp validate_required_param(nil, param_name) do
    {:error, "Missing required parameter: #{param_name}"}
  end

  defp validate_required_param(_value, _param_name), do: :ok

  # ============================================================================
  # Abort Handling
  # ============================================================================

  @spec check_aborted(reference() | nil) :: :ok | {:error, :aborted}
  defp check_aborted(nil), do: :ok

  defp check_aborted(signal) when is_reference(signal) do
    if AbortSignal.aborted?(signal) do
      {:error, :aborted}
    else
      :ok
    end
  end

  defp check_aborted(_), do: :ok

  # ============================================================================
  # Path Resolution
  # ============================================================================

  @spec resolve_path(String.t(), String.t(), keyword()) :: String.t()
  defp resolve_path(path, cwd, opts) do
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
  # File Access
  # ============================================================================

  @spec check_file_access(String.t()) :: :ok | {:error, atom()}
  defp check_file_access(path) do
    case File.stat(path) do
      {:ok, %File.Stat{access: access}} when access in [:read_write, :write] ->
        :ok

      {:ok, %File.Stat{}} ->
        {:error, :eacces}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # BOM Handling
  # ============================================================================

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  @spec strip_bom(binary()) :: {binary() | nil, String.t()}
  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>) do
    {@utf8_bom, rest}
  end

  defp strip_bom(content) do
    {nil, content}
  end

  # ============================================================================
  # Line Ending Detection & Normalization
  # ============================================================================

  @spec detect_line_ending(String.t()) :: String.t()
  defp detect_line_ending(content) do
    if String.contains?(content, "\r\n") do
      "\r\n"
    else
      "\n"
    end
  end

  @spec normalize_to_lf(String.t()) :: String.t()
  defp normalize_to_lf(text) do
    String.replace(text, "\r\n", "\n")
  end

  @spec restore_line_endings(String.t(), String.t()) :: String.t()
  defp restore_line_endings(text, "\r\n") do
    # First normalize to LF to avoid double CRLF, then convert to CRLF
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\n", "\r\n")
  end

  defp restore_line_endings(text, _) do
    text
  end

  # ============================================================================
  # Text Matching
  # ============================================================================

  @spec fuzzy_find_text(String.t(), String.t()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, :not_found}
  defp fuzzy_find_text(content, search_text) do
    # Try exact match first
    case :binary.match(content, search_text) do
      {index, length} ->
        {:ok, index, length}

      :nomatch ->
        # Try fuzzy match
        fuzzy_find_text_fuzzy(content, search_text)
    end
  end

  @spec fuzzy_find_text_fuzzy(String.t(), String.t()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, :not_found}
  defp fuzzy_find_text_fuzzy(content, search_text) do
    normalized_content = normalize_for_fuzzy(content)
    normalized_search = normalize_for_fuzzy(search_text)

    case :binary.match(normalized_content, normalized_search) do
      {index, _length} ->
        # We found a match in normalized space, now find the actual match
        # in the original content at approximately the same position
        find_original_match(content, search_text, index)

      :nomatch ->
        {:error, :not_found}
    end
  end

  @spec find_original_match(String.t(), String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, :not_found}
  defp find_original_match(content, search_text, approx_index) do
    # Search in a window around the approximate index
    search_len = String.length(search_text)
    content_len = String.length(content)

    # Calculate search window (give some buffer for character expansions)
    window_start = max(0, approx_index - search_len)
    window_end = min(content_len, approx_index + search_len * 3)

    # Extract the window and search within it
    window = String.slice(content, window_start, window_end - window_start)
    normalized_window = normalize_for_fuzzy(window)
    normalized_search = normalize_for_fuzzy(search_text)

    case :binary.match(normalized_window, normalized_search) do
      {local_index, _} ->
        # Find the actual span in the original window
        find_matching_span(window, normalized_search, local_index, window_start)

      :nomatch ->
        {:error, :not_found}
    end
  end

  @spec find_matching_span(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, :not_found}
  defp find_matching_span(window, normalized_search, approx_local_index, window_start) do
    normalized_search_len = String.length(normalized_search)

    # Walk through the window character by character to find exact boundaries
    # This handles cases where original chars map to different normalized lengths
    window_chars = String.graphemes(window)
    window_len = length(window_chars)

    # Find start position: walk forward until normalized prefix matches
    result =
      Enum.reduce_while(0..(window_len - 1), nil, fn start_idx, _acc ->
        remaining = Enum.drop(window_chars, start_idx) |> Enum.join()
        normalized_remaining = normalize_for_fuzzy(remaining)

        if String.starts_with?(normalized_remaining, normalized_search) do
          # Found start, now find end
          case find_match_end(window_chars, start_idx, normalized_search, normalized_search_len) do
            {:ok, end_idx} ->
              original_text =
                window_chars
                |> Enum.slice(start_idx..(end_idx - 1))
                |> Enum.join()

              byte_offset = byte_offset_at_grapheme(window, start_idx)
              {:halt, {:ok, window_start + byte_offset, byte_size(original_text)}}

            :error ->
              {:cont, nil}
          end
        else
          if start_idx > approx_local_index + normalized_search_len do
            {:halt, {:error, :not_found}}
          else
            {:cont, nil}
          end
        end
      end)

    case result do
      {:ok, _, _} = success -> success
      _ -> {:error, :not_found}
    end
  end

  @spec find_match_end([String.t()], non_neg_integer(), String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :error
  defp find_match_end(window_chars, start_idx, normalized_search, normalized_search_len) do
    window_len = length(window_chars)

    Enum.reduce_while((start_idx + 1)..window_len, :error, fn end_idx, _acc ->
      slice = Enum.slice(window_chars, start_idx..(end_idx - 1)) |> Enum.join()
      normalized_slice = normalize_for_fuzzy(slice)
      normalized_slice_len = String.length(normalized_slice)

      cond do
        normalized_slice == normalized_search ->
          {:halt, {:ok, end_idx}}

        normalized_slice_len >= normalized_search_len ->
          {:halt, :error}

        true ->
          {:cont, :error}
      end
    end)
  end

  @spec byte_offset_at_grapheme(String.t(), non_neg_integer()) :: non_neg_integer()
  defp byte_offset_at_grapheme(string, grapheme_index) do
    string
    |> String.graphemes()
    |> Enum.take(grapheme_index)
    |> Enum.join()
    |> byte_size()
  end

  # Smart quote characters for normalization
  # Left single quote, right single quote, single high-reversed-9 quote, prime, reversed prime
  @single_quotes [0x2018, 0x2019, 0x201B, 0x2032, 0x2035]
  # Left double quote, right double quote, double low-9 quote, double high-reversed-9 quote, double prime, reversed double prime
  @double_quotes [0x201C, 0x201D, 0x201E, 0x201F, 0x2033, 0x2036]
  # En dash, em dash, horizontal bar, minus sign
  @dashes [0x2013, 0x2014, 0x2015, 0x2212]

  @spec normalize_for_fuzzy(String.t()) :: String.t()
  defp normalize_for_fuzzy(text) do
    text
    # Strip trailing whitespace per line
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
    # Smart quotes to ASCII
    |> replace_unicode_chars(@single_quotes, "'")
    |> replace_unicode_chars(@double_quotes, "\"")
    # Unicode dashes to hyphen
    |> replace_unicode_chars(@dashes, "-")
    # Multiple spaces to single space
    |> String.replace(~r/[ \t]+/, " ")
  end

  @spec replace_unicode_chars(String.t(), [non_neg_integer()], String.t()) :: String.t()
  defp replace_unicode_chars(text, codepoints, replacement) do
    Enum.reduce(codepoints, text, fn codepoint, acc ->
      String.replace(acc, <<codepoint::utf8>>, replacement)
    end)
  end

  # ============================================================================
  # Uniqueness Check
  # ============================================================================

  @spec check_uniqueness(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, {:multiple_occurrences, non_neg_integer()}}
  defp check_uniqueness(content, search_text, match_index, match_length) do
    # Extract the actual matched text from the original content
    matched_text = :binary.part(content, match_index, match_length)

    count = count_occurrences(content, matched_text)

    if count > 1 do
      {:error, {:multiple_occurrences, count}}
    else
      # Also check if the normalized search text appears multiple times
      # (for cases where fuzzy matching might find different variations)
      normalized_count = count_fuzzy_occurrences(content, search_text)

      if normalized_count > 1 do
        {:error, {:multiple_occurrences, normalized_count}}
      else
        :ok
      end
    end
  end

  @spec count_occurrences(String.t(), String.t()) :: non_neg_integer()
  defp count_occurrences(content, search_text) do
    content
    |> String.split(search_text)
    |> length()
    |> Kernel.-(1)
  end

  @spec count_fuzzy_occurrences(String.t(), String.t()) :: non_neg_integer()
  defp count_fuzzy_occurrences(content, search_text) do
    normalized_content = normalize_for_fuzzy(content)
    normalized_search = normalize_for_fuzzy(search_text)

    count_occurrences(normalized_content, normalized_search)
  end

  # ============================================================================
  # Replacement
  # ============================================================================

  @spec perform_replacement(String.t(), non_neg_integer(), non_neg_integer(), String.t()) ::
          {:ok, String.t()}
  defp perform_replacement(content, match_index, match_length, new_text) do
    # Normalize new_text to LF as well
    normalized_new_text = normalize_to_lf(new_text)

    before = :binary.part(content, 0, match_index)

    after_match =
      :binary.part(
        content,
        match_index + match_length,
        byte_size(content) - match_index - match_length
      )

    {:ok, before <> normalized_new_text <> after_match}
  end

  @spec check_content_changed(String.t(), String.t()) :: :ok | {:error, :no_change}
  defp check_content_changed(old_content, new_content) do
    if old_content == new_content do
      {:error, :no_change}
    else
      :ok
    end
  end

  @spec finalize_content(String.t(), String.t(), binary() | nil) :: binary()
  defp finalize_content(content, line_ending, bom) do
    content_with_endings = restore_line_endings(content, line_ending)

    case bom do
      nil -> content_with_endings
      bom_bytes -> bom_bytes <> content_with_endings
    end
  end

  # ============================================================================
  # Diff Generation
  # ============================================================================

  @default_context_lines 4

  @spec generate_diff(String.t(), String.t(), non_neg_integer()) :: String.t()
  defp generate_diff(old_content, new_content, context_lines \\ @default_context_lines) do
    old_lines = String.split(old_content, "\n")
    new_lines = String.split(new_content, "\n")

    # Find changed regions
    changes = compute_line_changes(old_lines, new_lines)

    # Generate diff with context
    format_diff(old_lines, new_lines, changes, context_lines)
  end

  @spec compute_line_changes([String.t()], [String.t()]) :: [
          {:same | :removed | :added, non_neg_integer(), String.t()}
        ]
  defp compute_line_changes(old_lines, new_lines) do
    # Simple diff algorithm using longest common subsequence approach
    # For each line, mark as same, removed, or added
    lcs_diff(old_lines, new_lines)
  end

  @spec lcs_diff([String.t()], [String.t()]) :: [
          {:same | :removed | :added, non_neg_integer(), String.t()}
        ]
  defp lcs_diff(old_lines, new_lines) do
    # Build LCS matrix
    m = length(old_lines)
    n = length(new_lines)

    # Convert to 0-indexed arrays for easier access
    old_arr = :array.from_list(old_lines)
    new_arr = :array.from_list(new_lines)

    # Build the DP table
    dp = build_lcs_table(old_arr, new_arr, m, n)

    # Backtrack to find the diff
    backtrack_diff(old_arr, new_arr, dp, m, n)
  end

  @spec build_lcs_table(
          :array.array(String.t()),
          :array.array(String.t()),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          :array.array(:array.array(non_neg_integer()))
  defp build_lcs_table(old_arr, new_arr, m, n) do
    # Initialize (m+1) x (n+1) table with zeros
    initial_row = :array.new(n + 1, default: 0)
    dp = :array.new(m + 1, default: initial_row)

    # Fill the table
    Enum.reduce(1..m, dp, fn i, dp_acc ->
      row =
        Enum.reduce(1..n, :array.get(i, dp_acc), fn j, row_acc ->
          old_line = :array.get(i - 1, old_arr)
          new_line = :array.get(j - 1, new_arr)

          value =
            if old_line == new_line do
              :array.get(j - 1, :array.get(i - 1, dp_acc)) + 1
            else
              max(
                :array.get(j, :array.get(i - 1, dp_acc)),
                :array.get(j - 1, row_acc)
              )
            end

          :array.set(j, value, row_acc)
        end)

      :array.set(i, row, dp_acc)
    end)
  end

  @spec backtrack_diff(
          :array.array(String.t()),
          :array.array(String.t()),
          :array.array(:array.array(non_neg_integer())),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          [{:same | :removed | :added, non_neg_integer(), String.t()}]
  defp backtrack_diff(old_arr, new_arr, dp, m, n) do
    do_backtrack(old_arr, new_arr, dp, m, n, [])
  end

  defp do_backtrack(_old_arr, _new_arr, _dp, 0, 0, acc), do: acc

  defp do_backtrack(old_arr, _new_arr, _dp, i, 0, acc) do
    # All remaining old lines are removals
    entries =
      for idx <- (i - 1)..0//-1, idx >= 0 do
        {:removed, idx + 1, :array.get(idx, old_arr)}
      end
      |> Enum.reverse()

    entries ++ acc
  end

  defp do_backtrack(_old_arr, new_arr, _dp, 0, j, acc) do
    # All remaining new lines are additions
    entries =
      for idx <- (j - 1)..0//-1, idx >= 0 do
        {:added, idx + 1, :array.get(idx, new_arr)}
      end
      |> Enum.reverse()

    entries ++ acc
  end

  defp do_backtrack(old_arr, new_arr, dp, i, j, acc) do
    old_line = :array.get(i - 1, old_arr)
    new_line = :array.get(j - 1, new_arr)

    if old_line == new_line do
      do_backtrack(old_arr, new_arr, dp, i - 1, j - 1, [{:same, i, old_line} | acc])
    else
      # Choose the direction with the higher LCS value
      up_val = :array.get(j, :array.get(i - 1, dp))
      left_val = :array.get(j - 1, :array.get(i, dp))

      if up_val >= left_val do
        do_backtrack(old_arr, new_arr, dp, i - 1, j, [{:removed, i, old_line} | acc])
      else
        do_backtrack(old_arr, new_arr, dp, i, j - 1, [{:added, j, new_line} | acc])
      end
    end
  end

  @spec format_diff(
          [String.t()],
          [String.t()],
          [{:same | :removed | :added, non_neg_integer(), String.t()}],
          non_neg_integer()
        ) ::
          String.t()
  defp format_diff(_old_lines, _new_lines, changes, context_lines) do
    # Find indices of changed lines
    change_indices =
      changes
      |> Enum.with_index()
      |> Enum.filter(fn {{type, _, _}, _} -> type != :same end)
      |> Enum.map(fn {_, idx} -> idx end)

    if Enum.empty?(change_indices) do
      "(no changes)"
    else
      # Determine which lines to show (changes + context)
      lines_to_show =
        change_indices
        |> Enum.flat_map(fn idx ->
          max(0, idx - context_lines)..min(length(changes) - 1, idx + context_lines)
        end)
        |> Enum.uniq()
        |> Enum.sort()

      # Group into hunks (continuous ranges)
      hunks = group_into_hunks(lines_to_show)

      # Format each hunk
      hunks
      |> Enum.map(fn hunk_indices ->
        format_hunk(changes, hunk_indices)
      end)
      |> Enum.join("\n...\n")
    end
  end

  @spec group_into_hunks([non_neg_integer()]) :: [[non_neg_integer()]]
  defp group_into_hunks([]), do: []

  defp group_into_hunks(indices) do
    indices
    |> Enum.reduce([], fn idx, acc ->
      case acc do
        [] ->
          [[idx]]

        [current_hunk | rest] ->
          last_in_hunk = List.last(current_hunk)

          if idx - last_in_hunk <= 1 do
            [current_hunk ++ [idx] | rest]
          else
            [[idx], current_hunk | rest]
          end
      end
    end)
    |> Enum.reverse()
  end

  @spec format_hunk([{:same | :removed | :added, non_neg_integer(), String.t()}], [
          non_neg_integer()
        ]) :: String.t()
  defp format_hunk(changes, indices) do
    indices
    |> Enum.map(fn idx ->
      {type, line_num, text} = Enum.at(changes, idx)

      case type do
        :same -> " #{line_num}\t#{text}"
        :removed -> "-#{line_num}\t#{text}"
        :added -> "+#{line_num}\t#{text}"
      end
    end)
    |> Enum.join("\n")
  end

  @spec find_first_changed_line(String.t(), String.t()) :: non_neg_integer()
  defp find_first_changed_line(old_content, new_content) do
    old_lines = String.split(old_content, "\n")
    new_lines = String.split(new_content, "\n")

    # Find first differing line (1-indexed)
    old_lines
    |> Enum.zip(new_lines)
    |> Enum.with_index(1)
    |> Enum.find(fn {{old_line, new_line}, _idx} -> old_line != new_line end)
    |> case do
      {{_, _}, idx} ->
        idx

      nil ->
        # Lines match but lengths differ
        min(length(old_lines), length(new_lines)) + 1
    end
  end
end
