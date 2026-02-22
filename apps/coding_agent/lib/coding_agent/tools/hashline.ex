defmodule CodingAgent.Tools.Hashline do
  @moduledoc """
  Hashline Edit Mode - a line-addressable edit format using content hashes.

  Each line in a file is identified by its 1-indexed line number and a short
  hexadecimal hash derived from the normalized line content (whitespace removed,
  hash computed using `:erlang.phash2/2`, truncated to 2 hex chars).

  The combined `LINE#ID` reference acts as both an address and a staleness check:
  if the file has changed since the caller last read it, hash mismatches are caught
  before any mutation occurs.

  Displayed format: `LINENUM#HASH:CONTENT`
  Reference format: `"LINENUM#HASH"` (e.g. `"5#ab"`)

  ## Edit Operations

  - `set` - Replace a single line
  - `replace` - Replace a range of lines (first to last)
  - `append` - Insert after a line (or at EOF if no anchor)
  - `prepend` - Insert before a line (or at BOF if no anchor)
  - `insert` - Insert between two lines

  ## Example Usage

      content = "Hello\\nWorld\\n"
      edits = [
        %{op: :set, tag: %{line: 1, hash: compute_line_hash("Hello")}, content: ["Hi"]},
        %{op: :append, after: %{line: 2, hash: compute_line_hash("World")}, content: ["!"]}
      ]
      {:ok, result} = apply_edits(content, edits)
  """

  alias CodingAgent.Tools.Hashline.HashlineMismatchError
  import Bitwise

  @typedoc "Line tag with line number and hash"
  @type line_tag :: %{line: pos_integer(), hash: String.t()}

  @typedoc "Set operation - replace a single line"
  @type set_edit :: %{op: :set, tag: line_tag(), content: [String.t()]}

  @typedoc "Replace operation - replace a range of lines"
  @type replace_edit :: %{op: :replace, first: line_tag(), last: line_tag(), content: [String.t()]}

  @typedoc "Append operation - insert after a line (or at EOF if no anchor)"
  @type append_edit :: %{op: :append, after: line_tag() | nil, content: [String.t()]}

  @typedoc "Prepend operation - insert before a line (or at BOF if no anchor)"
  @type prepend_edit :: %{op: :prepend, before: line_tag() | nil, content: [String.t()]}

  @typedoc "Insert operation - insert between two lines"
  @type insert_edit :: %{op: :insert, after: line_tag(), before: line_tag(), content: [String.t()]}

  @typedoc "ReplaceText operation - substring-based search and replace"
  @type replace_text_edit :: %{op: :replace_text, old_text: String.t(), new_text: String.t(), all: boolean()}

  @typedoc "Any hashline edit operation"
  @type edit :: set_edit() | replace_edit() | append_edit() | prepend_edit() | insert_edit() | replace_text_edit()

  @typedoc "Result of applying edits"
  @type apply_result :: %{
          content: String.t(),
          first_changed_line: pos_integer() | nil,
          noop_edits: [map()] | nil,
          deduplicated_edits: [map()] | nil
        }

  @typedoc "Hash mismatch information"
  @type hash_mismatch :: %{line: pos_integer(), expected: String.t(), actual: String.t()}

  # Number of context lines shown above/below each mismatched line
  @mismatch_context 2

  # Check whether autocorrect mode is enabled.
  # When enabled, applies heuristics to fix common LLM edit artifacts:
  # - Restores indentation stripped by the model
  # - Undoes formatting rewrites where the model reflows lines
  # - Strips echoed boundary context lines from range replacements
  defp autocorrect_enabled? do
    Application.get_env(:coding_agent, :hashline_autocorrect, false)
  end

  @doc """
  Compute a short hexadecimal hash of a single line.

  Uses `:erlang.phash2/2` on a whitespace-normalized line, truncated to 2
  hex characters. The line input should not include a trailing newline.

  ## Examples

      iex> compute_line_hash("hello world")
      "a1"  # actual hash will vary

      iex> compute_line_hash("  hello  world  ")
      "a1"  # same hash after whitespace normalization
  """
  @spec compute_line_hash(String.t()) :: String.t()
  def compute_line_hash(line) do
    line
    |> normalize_line()
    |> :erlang.phash2(256)
    |> format_hash()
  end

  @doc """
  Normalize a line by removing all whitespace characters.

  ## Examples

      iex> normalize_line("  hello  world  ")
      "helloworld"
  """
  @spec normalize_line(String.t()) :: String.t()
  def normalize_line(line) do
    line
    |> String.replace(~r/\s+/, "")
    |> String.replace("\r", "")
  end

  @doc """
  Format a hash value (0-255) as a 2-character hex string.

  Uses a custom nibble encoding compatible with the original TypeScript
  implementation for consistent hash display.
  """
  @spec format_hash(non_neg_integer()) :: String.t()
  def format_hash(hash) when hash >= 0 and hash < 256 do
    nibble_str = "ZPMQVRWSNKTXJBYH"
    high = hash >>> 4
    low = hash &&& 0x0F
    <<String.at(nibble_str, high)::binary, String.at(nibble_str, low)::binary>>
  end

  @doc """
  Formats a tag given the line number and content.

  ## Examples

      iex> format_line_tag(5, "hello")
      "5#XX"  # where XX is the computed hash
  """
  @spec format_line_tag(pos_integer(), String.t()) :: String.t()
  def format_line_tag(line, content) do
    hash = compute_line_hash(content)
    "#{line}##{hash}"
  end

  @doc """
  Format file content with hashline prefixes for display.

  Each line becomes `LINENUM#HASH:CONTENT` where LINENUM is 1-indexed.

  ## Parameters

    - `content` - Raw file content string
    - `start_line` - First line number (1-indexed, defaults to 1)

  ## Returns

  Formatted string with one hashline-prefixed line per input line.

  ## Examples

      iex> format_hashlines("function hi() {\\n  return;\\n}")
      "1#XX:function hi() {\\n2#YY:  return;\\n3#ZZ:}"
  """
  @spec format_hashlines(String.t(), pos_integer()) :: String.t()
  def format_hashlines(content, start_line \\ 1) do
    lines = String.split(content, "\n")

    lines
    |> Enum.with_index(start_line)
    |> Enum.map_join("\n", fn {line, num} ->
      "#{format_line_tag(num, line)}:#{line}"
    end)
  end

  @nibble_chars "ZPMQVRWSNKTXJBYH"

  @doc """
  Parse a line reference string like `"5#ZZ"` into structured form.

  ## Examples

      iex> parse_tag("5#ZZ")
      %{line: 5, hash: "ZZ"}

      iex> parse_tag("  5  #  ZZ  ")
      %{line: 5, hash: "ZZ"}

  ## Errors

  Raises `ArgumentError` if the format is invalid.
  """
  @spec parse_tag(String.t()) :: %{line: pos_integer(), hash: String.t()}
  def parse_tag(ref) do
    # Regex captures:
    # 1. optional leading ">+" and whitespace
    # 2. line number (1+ digits)
    # 3. "#" with optional surrounding spaces
    # 4. hash (2 chars from our nibble alphabet)
    hash_pattern = "[#{@nibble_chars}]{2}"

    regex = ~r/^\s*[>+\-]*\s*(\d+)\s*#\s*(#{hash_pattern})/

    case Regex.run(regex, ref) do
      [_, line_str, hash] ->
        line = String.to_integer(line_str)

        if line < 1 do
          raise ArgumentError, "Line number must be >= 1, got #{line} in \"#{ref}\"."
        end

        %{line: line, hash: hash}

      nil ->
        raise ArgumentError,
              "Invalid line reference \"#{ref}\". Expected format \"LINE#ID\" (e.g. \"5#ZZ\")."
    end
  end

  @doc """
  Validate that a line reference points to an existing line with a matching hash.

  ## Parameters

    - `ref` - Parsed line reference (1-indexed line number + expected hash)
    - `file_lines` - Array of file lines (0-indexed)

  ## Returns

  `:ok` if the hash matches.

  ## Raises

  - `HashlineMismatchError` if the hash doesn't match (includes correct hashes in context)
  - `ArgumentError` if the line is out of range
  """
  @spec validate_line_ref(line_tag(), [String.t()]) :: :ok
  def validate_line_ref(%{line: line, hash: expected_hash}, file_lines) do
    if line < 1 or line > length(file_lines) do
      raise ArgumentError, "Line #{line} does not exist (file has #{length(file_lines)} lines)"
    end

    actual_line = Enum.at(file_lines, line - 1)
    actual_hash = compute_line_hash(actual_line)

    if actual_hash != expected_hash do
      mismatch = %{line: line, expected: expected_hash, actual: actual_hash}
      raise HashlineMismatchError, mismatches: [mismatch], file_lines: file_lines
    end

    :ok
  end

  @doc """
  Apply a list of hashline edits to file content.

  Each edit operation identifies target lines directly. Line references are resolved
  via `parse_tag/1` and hashes validated before any mutation.

  Edits are sorted bottom-up (highest effective line first) so earlier
  splices don't invalidate later line numbers.

  ## Parameters

    - `content` - Original file content string
    - `edits` - List of edit operations

  ## Returns

  `{:ok, apply_result()}` on success, `{:error, HashlineMismatchError.t()}` on hash mismatch.

  ## Examples

      content = "line1\\nline2\\nline3"
      edits = [%{op: :set, tag: %{line: 2, hash: "XX"}, content: ["new line2"]}]
      {:ok, result} = apply_edits(content, edits)
  """
  @spec apply_edits(String.t(), [edit()]) :: {:ok, apply_result()} | {:error, HashlineMismatchError.t()}
  def apply_edits(content, edits) when is_list(edits) do
    if Enum.empty?(edits) do
      {:ok, %{content: content, first_changed_line: nil, noop_edits: nil, deduplicated_edits: nil}}
    else
      file_lines = String.split(content, "\n")
      original_file_lines = file_lines

      with :ok <- validate_all_edits(edits, file_lines) do
        {edits, deduplicated_edits} = deduplicate_edits(edits)
        sorted_edits = sort_edits(edits, file_lines)
        touched_lines = build_touched_lines(sorted_edits)

        {result_lines, first_changed, noop_edits} =
          apply_sorted_edits(sorted_edits, file_lines, original_file_lines, nil, [], touched_lines)

        result = %{
          content: Enum.join(result_lines, "\n"),
          first_changed_line: first_changed,
          noop_edits: if(Enum.empty?(noop_edits), do: nil, else: Enum.reverse(noop_edits)),
          deduplicated_edits:
            if(Enum.empty?(deduplicated_edits), do: nil, else: deduplicated_edits)
        }

        {:ok, result}
      end
    end
  end

  # Validate all edits before making any changes, collecting all mismatches
  defp validate_all_edits(edits, file_lines) do
    mismatches =
      edits
      |> Enum.reduce([], fn edit, acc ->
        case validate_edit(edit, file_lines) do
          :ok -> acc
          {:mismatch, m} -> acc ++ m
        end
      end)

    if Enum.empty?(mismatches) do
      :ok
    else
      {:error, HashlineMismatchError.exception(mismatches: mismatches, file_lines: file_lines)}
    end
  end

  # Validate a single edit, returning {:mismatch, list} or :ok
  defp validate_edit(%{op: :set, tag: tag}, file_lines) do
    validate_edit_ref(tag, file_lines)
  end

  defp validate_edit(%{op: :append, content: content, after: after_tag}, file_lines) do
    if Enum.empty?(content) do
      raise ArgumentError, "Insert-after edit requires non-empty content"
    end

    if after_tag do
      validate_edit_ref(after_tag, file_lines)
    else
      :ok
    end
  end

  defp validate_edit(%{op: :prepend, content: content, before: before_tag}, file_lines) do
    if Enum.empty?(content) do
      raise ArgumentError, "Insert-before edit requires non-empty content"
    end

    if before_tag do
      validate_edit_ref(before_tag, file_lines)
    else
      :ok
    end
  end

  defp validate_edit(%{op: :insert, content: content, after: after_tag, before: before_tag}, file_lines) do
    if Enum.empty?(content) do
      raise ArgumentError, "Insert-between edit requires non-empty content"
    end

    if before_tag.line <= after_tag.line do
      raise ArgumentError,
            "insert requires after (#{after_tag.line}) < before (#{before_tag.line})"
    end

    after_valid = validate_edit_ref(after_tag, file_lines)
    before_valid = validate_edit_ref(before_tag, file_lines)

    case {after_valid, before_valid} do
      {:ok, :ok} -> :ok
      {{:mismatch, m1}, {:mismatch, m2}} -> {:mismatch, m1 ++ m2}
      {:ok, {:mismatch, m}} -> {:mismatch, m}
      {{:mismatch, m}, :ok} -> {:mismatch, m}
    end
  end

  defp validate_edit(%{op: :replace, first: first, last: last}, file_lines) do
    if first.line > last.line do
      raise ArgumentError,
            "Range start line #{first.line} must be <= end line #{last.line}"
    end

    start_valid = validate_edit_ref(first, file_lines)
    end_valid = validate_edit_ref(last, file_lines)

    case {start_valid, end_valid} do
      {:ok, :ok} -> :ok
      {{:mismatch, m1}, {:mismatch, m2}} -> {:mismatch, m1 ++ m2}
      {:ok, {:mismatch, m}} -> {:mismatch, m}
      {{:mismatch, m}, :ok} -> {:mismatch, m}
    end
  end

  defp validate_edit(%{op: :replace_text, old_text: old_text}, file_lines) do
    if old_text == "" do
      raise ArgumentError, "replaceText edit requires non-empty old_text"
    end

    content = Enum.join(file_lines, "\n")

    if not String.contains?(content, old_text) do
      raise ArgumentError, "replaceText old_text not found in file content"
    end

    :ok
  end

  defp validate_edit_ref(tag, file_lines) do
    if tag.line < 1 or tag.line > length(file_lines) do
      raise ArgumentError, "Line #{tag.line} does not exist (file has #{length(file_lines)} lines)"
    end

    actual_line = Enum.at(file_lines, tag.line - 1)
    actual_hash = compute_line_hash(actual_line)

    if actual_hash != tag.hash do
      {:mismatch, [%{line: tag.line, expected: tag.hash, actual: actual_hash}]}
    else
      :ok
    end
  end

  # Deduplicate identical edits targeting the same line(s)
  defp deduplicate_edits(edits) do
    {deduped, deduplicated, _seen} =
      edits
      |> Enum.with_index()
      |> Enum.reduce({[], [], %{}}, fn {edit, idx}, {acc, dups, seen} ->
        key = deduplication_key(edit)

        case Map.get(seen, key) do
          nil ->
            {[edit | acc], dups, Map.put(seen, key, idx)}

          first_idx ->
            dedup = %{edit_index: idx, duplicate_of: first_idx, key: key, op: edit.op}
            {acc, [dedup | dups], seen}
        end
      end)

    {Enum.reverse(deduped), Enum.reverse(deduplicated)}
  end

  defp deduplication_key(edit) do
    op = edit.op
    line_range = edit_line_range(edit)
    content_hash = edit_content_hash(edit)
    "#{op}:#{line_range}:#{content_hash}"
  end

  defp edit_line_range(%{op: :set, tag: tag}), do: "#{tag.line}"
  defp edit_line_range(%{op: :replace, first: first, last: last}), do: "#{first.line}-#{last.line}"
  defp edit_line_range(%{op: :append, after: nil}), do: "eof"
  defp edit_line_range(%{op: :append, after: tag}), do: "#{tag.line}"
  defp edit_line_range(%{op: :prepend, before: nil}), do: "bof"
  defp edit_line_range(%{op: :prepend, before: tag}), do: "#{tag.line}"

  defp edit_line_range(%{op: :insert, after: after_tag, before: before_tag}),
    do: "#{after_tag.line}-#{before_tag.line}"

  defp edit_line_range(%{op: :replace_text}), do: "global"

  defp edit_content_hash(%{op: :replace_text, old_text: old, new_text: new, all: all}) do
    :erlang.phash2({old, new, all})
    |> Integer.to_string(16)
  end

  defp edit_content_hash(%{content: content}) do
    :erlang.phash2(content)
    |> Integer.to_string(16)
  end

  @doc """
  Sort edits for bottom-up application.

  Returns edits sorted by their effective line position in descending order,
  so earlier splices don't invalidate later line numbers.
  """
  @spec sort_edits([edit()], [String.t()]) :: [{edit(), pos_integer()}]
  def sort_edits(edits, file_lines) do
    edits
    |> Enum.with_index()
    |> Enum.map(fn {edit, idx} ->
      {sort_line, precedence} = edit_sort_key(edit, file_lines)
      {edit, idx, sort_line, precedence}
    end)
    |> Enum.sort(fn {_, idx1, line1, prec1}, {_, idx2, line2, prec2} ->
      # Higher line first, then lower precedence, then original index
      line1 > line2 or (line1 == line2 and prec1 < prec2) or
        (line1 == line2 and prec1 == prec2 and idx1 < idx2)
    end)
    |> Enum.map(fn {edit, _, _, _} -> edit end)
  end

  defp edit_sort_key(%{op: :set, tag: tag}, _file_lines), do: {tag.line, 0}
  defp edit_sort_key(%{op: :replace, last: last}, _file_lines), do: {last.line, 0}

  defp edit_sort_key(%{op: :append, after: nil}, file_lines),
    do: {length(file_lines) + 1, 1}

  defp edit_sort_key(%{op: :append, after: tag}, _file_lines), do: {tag.line, 1}

  defp edit_sort_key(%{op: :prepend, before: nil}, _file_lines), do: {0, 2}
  defp edit_sort_key(%{op: :prepend, before: tag}, _file_lines), do: {tag.line, 2}
  defp edit_sort_key(%{op: :insert, before: before}, _file_lines), do: {before.line, 3}
  defp edit_sort_key(%{op: :replace_text}, _file_lines), do: {0, 4}

  # Apply sorted edits to file lines
  defp apply_sorted_edits([], file_lines, _original_lines, first_changed, noop_edits, _touched),
    do: {file_lines, first_changed, noop_edits}

  defp apply_sorted_edits([edit | rest], file_lines, original_lines, first_changed, noop_edits, touched) do
    {new_lines, new_first, new_noop} =
      apply_single_edit(edit, file_lines, original_lines, first_changed, noop_edits, touched)

    apply_sorted_edits(rest, new_lines, original_lines, new_first, new_noop, touched)
  end

  defp apply_single_edit(%{op: :set, tag: tag, content: content}, file_lines, original_lines, first_changed, noop_edits, touched) do
    orig_lines = [Enum.at(original_lines, tag.line - 1)]

    # Check merge detection FIRST on raw content (before other autocorrect transforms).
    # If a merge is detected, the other transforms (indent restore, etc.) are not
    # applicable since the line context has changed.
    merge_expansion = if autocorrect_enabled?() do
      maybe_expand_single_line_merge(tag.line, content, original_lines, touched)
    else
      nil
    end

    case merge_expansion do
      %{start_line: start, delete_count: del_count, new_lines: new_content} ->
        # Expanded merge: replace del_count lines starting at start with new_content
        idx = start - 1
        {before, after_parts} = Enum.split(file_lines, idx)
        {_removed, after_rest} = Enum.split(after_parts, del_count)
        new_lines = before ++ new_content ++ after_rest
        {new_lines, min_line(first_changed, start), noop_edits}

      nil ->
        # No merge - apply standard autocorrect transformations
        content =
          if autocorrect_enabled?() do
            content
            |> strip_range_boundary_echo(original_lines, tag.line, tag.line)
            |> restore_old_wrapped_lines(orig_lines)
            |> restore_indent_for_paired_replacement(orig_lines)
          else
            content
          end

        if lines_equal?(orig_lines, content) do
          noop = %{
            edit_index: tag.line,
            loc: "#{tag.line}##{tag.hash}",
            current_content: Enum.join(orig_lines, "\n")
          }

          {file_lines, first_changed, [noop | noop_edits]}
        else
          idx = tag.line - 1

          new_lines =
            case content do
              [] ->
                List.delete_at(file_lines, idx)

              [single_line] ->
                List.replace_at(file_lines, idx, single_line)

              _multiple_lines ->
                {before, after_parts} = Enum.split(file_lines, idx)
                {_removed, after_rest} = Enum.split(after_parts, 1)
                before ++ content ++ after_rest
            end

          {new_lines, min_line(first_changed, tag.line), noop_edits}
        end
    end
  end

  defp apply_single_edit(%{op: :replace, first: first, last: last, content: content}, file_lines, original_lines, first_changed, noop_edits, _touched) do
    count = last.line - first.line + 1
    orig_lines = Enum.slice(original_lines, first.line - 1, count)

    # Apply autocorrect transformations if enabled
    content =
      if autocorrect_enabled?() do
        content
        |> strip_range_boundary_echo(original_lines, first.line, last.line)
        |> restore_old_wrapped_lines(orig_lines)
        |> restore_indent_for_paired_replacement(orig_lines)
      else
        content
      end

    if lines_equal?(orig_lines, content) do
      noop = %{
        edit_index: first.line,
        loc: "#{first.line}##{first.hash}",
        current_content: Enum.join(orig_lines, "\n")
      }

      {file_lines, first_changed, [noop | noop_edits]}
    else
      {before, after_parts} = Enum.split(file_lines, first.line - 1)
      {_removed, after_rest} = Enum.split(after_parts, count)
      new_lines = before ++ content ++ after_rest
      {new_lines, min_line(first_changed, first.line), noop_edits}
    end
  end

  defp apply_single_edit(%{op: :append, after: nil, content: content}, file_lines, _original_lines, first_changed, noop_edits, _touched) do
    # Append at EOF
    if length(file_lines) == 1 and hd(file_lines) == "" do
      # Empty file case
      {content, min_line(first_changed, 1), noop_edits}
    else
      new_lines = file_lines ++ content
      changed_line = length(file_lines) - length(content) + 1
      {new_lines, min_line(first_changed, changed_line), noop_edits}
    end
  end

  defp apply_single_edit(%{op: :append, after: tag, content: content}, file_lines, original_lines, first_changed, noop_edits, _touched) do
    orig_line = Enum.at(original_lines, tag.line - 1)

    # Strip echo of anchor line if present
    inserted = strip_anchor_echo_after(orig_line, content)

    if Enum.empty?(inserted) do
      noop = %{
        edit_index: tag.line,
        loc: "#{tag.line}##{tag.hash}",
        current_content: orig_line
      }

      {file_lines, first_changed, [noop | noop_edits]}
    else
      {before, rest} = Enum.split(file_lines, tag.line)
      new_lines = before ++ inserted ++ rest
      {new_lines, min_line(first_changed, tag.line + 1), noop_edits}
    end
  end

  defp apply_single_edit(%{op: :prepend, before: nil, content: content}, file_lines, _original_lines, first_changed, noop_edits, _touched) do
    # Prepend at BOF
    if length(file_lines) == 1 and hd(file_lines) == "" do
      {content, min_line(first_changed, 1), noop_edits}
    else
      new_lines = content ++ file_lines
      {new_lines, min_line(first_changed, 1), noop_edits}
    end
  end

  defp apply_single_edit(%{op: :prepend, before: tag, content: content}, file_lines, original_lines, first_changed, noop_edits, _touched) do
    orig_line = Enum.at(original_lines, tag.line - 1)

    # Strip echo of anchor line if present
    inserted = strip_anchor_echo_before(orig_line, content)

    if Enum.empty?(inserted) do
      noop = %{
        edit_index: tag.line,
        loc: "#{tag.line}##{tag.hash}",
        current_content: orig_line
      }

      {file_lines, first_changed, [noop | noop_edits]}
    else
      {before, rest} = Enum.split(file_lines, tag.line - 1)
      new_lines = before ++ inserted ++ rest
      {new_lines, min_line(first_changed, tag.line), noop_edits}
    end
  end

  defp apply_single_edit(%{op: :insert, after: after_tag, before: before_tag, content: content}, file_lines, original_lines, first_changed, noop_edits, _touched) do
    after_line = Enum.at(original_lines, after_tag.line - 1)
    before_line = Enum.at(original_lines, before_tag.line - 1)

    # Strip echo of boundary lines if present
    inserted = strip_boundary_echo(after_line, before_line, content)

    if Enum.empty?(inserted) do
      noop = %{
        edit_index: after_tag.line,
        loc: "#{after_tag.line}##{after_tag.hash}..#{before_tag.line}##{before_tag.hash}",
        current_content: "#{after_line}\n#{before_line}"
      }

      {file_lines, first_changed, [noop | noop_edits]}
    else
      {before, rest} = Enum.split(file_lines, before_tag.line - 1)
      new_lines = before ++ inserted ++ rest
      {new_lines, min_line(first_changed, before_tag.line), noop_edits}
    end
  end

  defp apply_single_edit(%{op: :replace_text, old_text: old_text, new_text: new_text, all: replace_all}, file_lines, _original_lines, first_changed, noop_edits, _touched) do
    content = Enum.join(file_lines, "\n")

    if not String.contains?(content, old_text) do
      noop = %{
        edit_index: 0,
        loc: "replaceText",
        current_content: "old_text not found in file"
      }
      {file_lines, first_changed, [noop | noop_edits]}
    else
      new_content = if replace_all do
        String.replace(content, old_text, new_text)
      else
        String.replace(content, old_text, new_text, global: false)
      end

      new_lines = String.split(new_content, "\n")

      # Find first changed line
      changed_line = find_first_diff_line(file_lines, new_lines)

      {new_lines, min_line(first_changed, changed_line), noop_edits}
    end
  end

  defp apply_single_edit(%{op: :replace_text, old_text: _old_text, new_text: _new_text} = edit, file_lines, original_lines, first_changed, noop_edits, touched) do
    apply_single_edit(Map.put(edit, :all, false), file_lines, original_lines, first_changed, noop_edits, touched)
  end

  defp find_first_diff_line(old_lines, new_lines) do
    old_lines
    |> Stream.zip(new_lines)
    |> Stream.with_index(1)
    |> Enum.find_value(1, fn {{old, new}, idx} -> if old != new, do: idx end)
  end

  defp lines_equal?(a, b) when length(a) != length(b), do: false

  defp lines_equal?(a, b) do
    Enum.zip(a, b)
    |> Enum.all?(fn {x, y} -> x == y end)
  end

  defp min_line(nil, b), do: b
  defp min_line(a, b) when a < b, do: a
  defp min_line(_a, b), do: b

  # Strip echo of anchor line when appending (if first inserted line equals anchor)
  defp strip_anchor_echo_after(_anchor_line, inserted) when length(inserted) <= 1, do: inserted

  defp strip_anchor_echo_after(anchor_line, [first | rest]) do
    if equals_ignoring_whitespace?(first, anchor_line) do
      rest
    else
      [first | rest]
    end
  end

  # Strip echo of anchor line when prepending (if last inserted line equals anchor)
  defp strip_anchor_echo_before(_anchor_line, inserted) when length(inserted) <= 1, do: inserted

  defp strip_anchor_echo_before(anchor_line, inserted) do
    {init, [last]} = Enum.split(inserted, -1)

    if equals_ignoring_whitespace?(last, anchor_line) do
      init
    else
      inserted
    end
  end

  # Strip echo of boundary lines when inserting
  defp strip_boundary_echo(_after_line, _before_line, inserted) when length(inserted) <= 1,
    do: inserted

  defp strip_boundary_echo(after_line, before_line, inserted) do
    [first | rest] = inserted
    {init, [last]} = Enum.split(inserted, -1)

    first_matches = equals_ignoring_whitespace?(first, after_line)
    last_matches = equals_ignoring_whitespace?(last, before_line)

    cond do
      # Both boundaries match - strip both
      length(inserted) > 2 and first_matches and last_matches ->
        # Remove first from init (which includes last)
        [_ | middle] = init
        middle

      # Only first matches
      length(inserted) > 1 and first_matches ->
        rest

      # Only last matches
      length(inserted) > 1 and last_matches ->
        init

      true ->
        inserted
    end
  end

  defp equals_ignoring_whitespace?(a, b) do
    normalize_line(a) == normalize_line(b)
  end

  # ============================================================================
  # Autocorrect Helpers (ported from Oh-My-Pi hashline.ts)
  # ============================================================================

  @doc false
  # Extract leading whitespace from a string.
  defp leading_whitespace(s) do
    case Regex.run(~r/^\s*/, s) do
      [match] -> match
      _ -> ""
    end
  end

  @doc false
  # Restore leading indentation from a template line onto a replacement line.
  # If the replacement line has no indentation but the template does,
  # the template's indentation is prepended.
  defp restore_leading_indent(_template, ""), do: ""

  defp restore_leading_indent(template, line) do
    template_indent = leading_whitespace(template)

    if template_indent == "" do
      line
    else
      line_indent = leading_whitespace(line)

      if line_indent != "" do
        line
      else
        template_indent <> line
      end
    end
  end

  @doc false
  # Restore indentation for paired line replacements.
  # When old and new line counts match, restores the original indentation
  # on each corresponding replacement line that lost its whitespace.
  defp restore_indent_for_paired_replacement(new_lines, old_lines) do
    if length(old_lines) != length(new_lines) do
      new_lines
    else
      restored =
        Enum.zip(old_lines, new_lines)
        |> Enum.map(fn {old, new} -> restore_leading_indent(old, new) end)

      if restored == new_lines, do: new_lines, else: restored
    end
  end

  @doc false
  # Undo pure formatting rewrites where the model reflows a single logical line
  # into multiple lines (or similar), but the non-whitespace content is identical.
  defp restore_old_wrapped_lines(new_lines, old_lines) do
    if Enum.empty?(old_lines) or length(new_lines) < 2 do
      new_lines
    else
      # Build canonical form -> original line mapping (only unique canonical forms)
      canon_to_old =
        Enum.reduce(old_lines, %{}, fn line, acc ->
          canon = normalize_line(line)
          Map.update(acc, canon, {line, 1}, fn {l, c} -> {l, c + 1} end)
        end)

      # Find candidates: spans of 2-10 new lines whose join matches one old line
      max_idx = length(new_lines) - 1

      candidates =
        for start <- 0..max_idx,
            max_len = min(10, length(new_lines) - start),
            max_len >= 2,
            len <- 2..max_len,
            span = Enum.slice(new_lines, start, len),
            canon_span = normalize_line(Enum.join(span, "")),
            String.length(canon_span) >= 6,
            old = Map.get(canon_to_old, canon_span),
            match?({_, 1}, old) do
          {old_line, _} = old
          %{start: start, len: len, replacement: old_line, canon: canon_span}
        end

      if Enum.empty?(candidates) do
        new_lines
      else
        # Only keep spans whose canonical match is unique in the new output
        canon_counts =
          Enum.reduce(candidates, %{}, fn c, acc ->
            Map.update(acc, c.canon, 1, &(&1 + 1))
          end)

        unique = Enum.filter(candidates, fn c -> Map.get(canon_counts, c.canon, 0) == 1 end)

        if Enum.empty?(unique) do
          new_lines
        else
          # Apply replacements back-to-front so indices remain stable
          unique
          |> Enum.sort_by(& &1.start, :desc)
          |> Enum.reduce(new_lines, fn c, lines ->
            {before, rest} = Enum.split(lines, c.start)
            {_removed, after_rest} = Enum.split(rest, c.len)
            before ++ [c.replacement] ++ after_rest
          end)
        end
      end
    end
  end

  @doc false
  # Strip echoed boundary context lines from range replacements.
  # The model sometimes echoes the line before/after the range as extra context.
  # Only strips when the replacement grew (has more lines than the original range).
  defp strip_range_boundary_echo(dst_lines, file_lines, start_line, end_line) do
    count = end_line - start_line + 1

    if length(dst_lines) <= 1 or length(dst_lines) <= count do
      dst_lines
    else
      # Check if first dst line matches line before range
      before_idx = start_line - 2

      out =
        if before_idx >= 0 and
             equals_ignoring_whitespace?(hd(dst_lines), Enum.at(file_lines, before_idx)) do
          tl(dst_lines)
        else
          dst_lines
        end

      # Check if last dst line matches line after range
      after_idx = end_line

      if after_idx < length(file_lines) and length(out) > 0 do
        last = List.last(out)

        if equals_ignoring_whitespace?(last, Enum.at(file_lines, after_idx)) do
          Enum.drop(out, -1)
        else
          out
        end
      else
        out
      end
    end
  end

  # ============================================================================
  # Single-Line Merge Detection (ported from Oh-My-Pi hashline.ts)
  # ============================================================================

  # Build the set of line numbers explicitly targeted by edits.
  # Used by merge detection to avoid absorbing lines that are targeted
  # by another edit in the same batch.
  defp build_touched_lines(edits) do
    Enum.reduce(edits, MapSet.new(), fn edit, acc ->
      case edit do
        %{op: :set, tag: tag} -> MapSet.put(acc, tag.line)
        %{op: :replace, first: first, last: last} ->
          Enum.reduce(first.line..last.line, acc, &MapSet.put(&2, &1))
        %{op: :append, after: %{line: line}} -> MapSet.put(acc, line)
        %{op: :prepend, before: %{line: line}} -> MapSet.put(acc, line)
        %{op: :insert, after: after_tag, before: before_tag} ->
          acc |> MapSet.put(after_tag.line) |> MapSet.put(before_tag.line)
        _ -> acc
      end
    end)
  end

  @doc false
  # Strip trailing continuation tokens (operators that commonly end continuation lines).
  # Used by merge detection when the LLM merges adjacent lines while changing
  # the trailing operator (e.g. `&&` → `||`).
  def strip_trailing_continuation_tokens(s) do
    Regex.replace(~r/(?:&&|\|\||\?\?|\?|:|=|,|\+|-|\*|\/|\.|\()\s*$/u, s, "")
  end

  @doc false
  # Strip merge operator characters (|, &, ?) for fuzzy merge detection
  # when the model changes a logical operator while also merging lines.
  def strip_merge_operator_chars(s) do
    String.replace(s, ~r/[|&?]/, "")
  end

  @doc false
  # Detect when the LLM merged 2 adjacent lines into 1.
  #
  # Case A: The model absorbed the next continuation line into the current line.
  #   e.g. `foo &&` + `bar` → `foo && bar`
  #
  # Case B: The model absorbed the previous declaration/continuation line.
  #   e.g. `let x =` + `getValue()` → `let x = getValue()`
  #
  # Returns %{start_line, delete_count, new_lines} if merge detected, nil otherwise.
  defp maybe_expand_single_line_merge(_line, content, _file_lines, _touched_lines)
       when length(content) != 1,
       do: nil

  defp maybe_expand_single_line_merge(line, [new_line], file_lines, touched_lines) do
    total_lines = length(file_lines)

    with true <- line >= 1 and line <= total_lines,
         new_canon = normalize_line(new_line),
         true <- new_canon != "",
         orig_canon = normalize_line(Enum.at(file_lines, line - 1)),
         true <- orig_canon != "" do
      detect_next_line_merge(line, new_line, new_canon, orig_canon, total_lines, file_lines, touched_lines) ||
        detect_prev_line_merge(line, new_line, new_canon, orig_canon, file_lines, touched_lines)
    else
      _ -> nil
    end
  end

  # Case A: dst absorbed the next continuation line
  # e.g. `foo &&\n  bar` → `foo && bar`
  defp detect_next_line_merge(line, new_line, new_canon, orig_canon, total_lines, file_lines, touched_lines) do
    orig_canon_for_match = strip_trailing_continuation_tokens(orig_canon)

    with true <- String.length(orig_canon_for_match) < String.length(orig_canon),
         true <- line < total_lines,
         false <- MapSet.member?(touched_lines, line + 1),
         next_canon = normalize_line(Enum.at(file_lines, line)),
         {a_pos, _} <- :binary.match(new_canon, orig_canon_for_match),
         {b_pos, _} <- :binary.match(new_canon, next_canon),
         true <- a_pos < b_pos,
         true <- String.length(new_canon) <= String.length(orig_canon) + String.length(next_canon) + 32 do
      %{start_line: line, delete_count: 2, new_lines: [new_line]}
    else
      _ -> nil
    end
  end

  # Case B: dst absorbed the previous declaration/continuation line
  # e.g. `let x =\n  getValue()` → `let x = getValue()`
  defp detect_prev_line_merge(line, new_line, new_canon, orig_canon, file_lines, touched_lines) do
    prev_idx = line - 2

    with true <- prev_idx >= 0,
         false <- MapSet.member?(touched_lines, line - 1),
         prev_canon = normalize_line(Enum.at(file_lines, prev_idx)),
         prev_canon_for_match = strip_trailing_continuation_tokens(prev_canon),
         true <- String.length(prev_canon_for_match) < String.length(prev_canon),
         new_canon_ops = strip_merge_operator_chars(new_canon),
         {a_pos, _} <- :binary.match(new_canon_ops, strip_merge_operator_chars(prev_canon_for_match)),
         {b_pos, _} <- :binary.match(new_canon_ops, strip_merge_operator_chars(orig_canon)),
         true <- a_pos < b_pos,
         true <- String.length(new_canon) <= String.length(prev_canon) + String.length(orig_canon) + 32 do
      %{start_line: line - 1, delete_count: 2, new_lines: [new_line]}
    else
      _ -> nil
    end
  end

  # ============================================================================
  # Streaming Hashline Formatter
  # ============================================================================

  @doc """
  Stream hashline-formatted output from file content.

  Yields chunks of formatted lines, suitable for large files where callers
  want incremental output rather than allocating a single large string.

  ## Options

    - `:start_line` - First line number (1-indexed, defaults to 1)
    - `:max_chunk_lines` - Maximum formatted lines per yielded chunk (default: 200)
    - `:max_chunk_bytes` - Maximum UTF-8 bytes per yielded chunk (default: 65536)

  ## Returns

  An Elixir `Stream` that yields `String.t()` chunks, each containing one or
  more `\\n`-joined hashline-formatted lines.

  ## Examples

      "line1\\nline2\\nline3"
      |> Hashline.stream_hashlines(max_chunk_lines: 1)
      |> Enum.to_list()
      # => ["1#XX:line1", "2#YY:line2", "3#ZZ:line3"]
  """
  @spec stream_hashlines(String.t(), keyword()) :: Enumerable.t()
  def stream_hashlines(content, opts \\ []) do
    start_line = Keyword.get(opts, :start_line, 1)
    max_chunk_lines = Keyword.get(opts, :max_chunk_lines, 200)
    max_chunk_bytes = Keyword.get(opts, :max_chunk_bytes, 65_536)

    lines = String.split(content, "\n")

    lines
    |> Stream.with_index(start_line)
    |> Stream.chunk_while(
      {[], 0, 0},
      fn {line, num}, {acc, acc_lines, acc_bytes} ->
        formatted = "#{format_line_tag(num, line)}:#{line}"
        line_bytes = byte_size(formatted)
        sep_bytes = if acc_lines == 0, do: 0, else: 1

        cond do
          # First line in chunk always goes in
          acc_lines == 0 ->
            {:cont, {[formatted], 1, line_bytes}}

          # Would exceed limits - emit current chunk, start new one
          acc_lines >= max_chunk_lines or
              acc_bytes + sep_bytes + line_bytes > max_chunk_bytes ->
            chunk = Enum.reverse(acc) |> Enum.join("\n")
            {:cont, chunk, {[formatted], 1, line_bytes}}

          # Add to current chunk
          true ->
            {:cont, {[formatted | acc], acc_lines + 1, acc_bytes + sep_bytes + line_bytes}}
        end
      end,
      fn
        {[], _, _} -> {:cont, {[], 0, 0}}
        {acc, _, _} ->
          chunk = Enum.reverse(acc) |> Enum.join("\n")
          {:cont, chunk, {[], 0, 0}}
      end
    )
  end

  @doc """
  Stream hashline-formatted output from an enumerable of binary chunks.

  Unlike `stream_hashlines/2` which takes a complete string, this function
  accepts an `Enumerable.t()` of binary chunks (e.g. from `File.stream!/3`)
  and streams hashline-formatted output without loading the entire file into
  memory.  Handles partial-line buffering across chunk boundaries.

  Ported from Oh-My-Pi's `streamHashLinesFromUtf8()`.

  ## Options

    - `:start_line` - First line number (1-indexed, defaults to 1)
    - `:max_chunk_lines` - Maximum formatted lines per yielded chunk (default: 200)
    - `:max_chunk_bytes` - Maximum UTF-8 bytes per yielded chunk (default: 65536)

  ## Returns

  An Elixir `Stream` that yields `String.t()` chunks, each containing one or
  more `\\n`-joined hashline-formatted lines.

  ## Examples

      File.stream!("big_file.ex", [], 8192)
      |> Hashline.stream_hashlines_from_enumerable(max_chunk_lines: 100)
      |> Enum.each(&IO.write/1)
  """
  @spec stream_hashlines_from_enumerable(Enumerable.t(), keyword()) :: Enumerable.t()
  def stream_hashlines_from_enumerable(source, opts \\ []) do
    start_line = Keyword.get(opts, :start_line, 1)
    max_chunk_lines = Keyword.get(opts, :max_chunk_lines, 200)
    max_chunk_bytes = Keyword.get(opts, :max_chunk_bytes, 65_536)

    Stream.transform(
      source,
      fn ->
        # {pending_partial_line, line_number, output_acc, acc_line_count, acc_byte_count, saw_any_text, ended_with_newline}
        {"", start_line, [], 0, 0, false, false}
      end,
      fn chunk, {pending, line_num, out_acc, out_lines, out_bytes, _saw_any, _ended_nl} ->
        text = pending <> IO.iodata_to_binary(chunk)

        {emitted, new_pending, new_line_num, new_out_acc, new_out_lines, new_out_bytes, new_ended_nl} =
          consume_text(text, line_num, out_acc, out_lines, out_bytes, max_chunk_lines, max_chunk_bytes)

        {emitted, {new_pending, new_line_num, new_out_acc, new_out_lines, new_out_bytes, true, new_ended_nl}}
      end,
      fn {pending, line_num, out_acc, out_lines, out_bytes, saw_any, ended_nl} ->
        # Flush remaining content
        final_emitted =
          cond do
            not saw_any ->
              # Empty source - emit one empty line (mirrors "".split("\n") behavior)
              formatted = "#{format_line_tag(line_num, "")}:"
              [flush_acc([formatted | out_acc])]

            byte_size(pending) > 0 or ended_nl ->
              # Emit the final line (may be empty if file ended with newline)
              {extra_emitted, _pending, _ln, final_acc, _ol, _ob, _enl} =
                consume_text(pending <> "\n", line_num, out_acc, out_lines, out_bytes, max_chunk_lines, max_chunk_bytes)

              last = flush_acc(final_acc)
              if last, do: extra_emitted ++ [last], else: extra_emitted

            true ->
              last = flush_acc(out_acc)
              if last, do: [last], else: []
          end

        {final_emitted, nil}
      end,
      fn _acc -> :ok end
    )
  end

  # Consume text, splitting on newlines, accumulating formatted lines into chunks.
  # Returns {emitted_chunks, remaining_pending, line_num, out_acc, out_lines, out_bytes, ended_with_newline}
  defp consume_text(text, line_num, out_acc, out_lines, out_bytes, max_chunk_lines, max_chunk_bytes) do
    case :binary.split(text, "\n") do
      [^text] ->
        # No newline found - entire text is pending
        {[], text, line_num, out_acc, out_lines, out_bytes, false}

      [line, rest] ->
        formatted = "#{format_line_tag(line_num, line)}:#{line}"
        line_bytes = byte_size(formatted)
        sep_bytes = if out_lines == 0, do: 0, else: 1

        # Check if we need to flush before adding this line
        {pre_emitted, out_acc, out_lines, out_bytes} =
          if out_lines > 0 and
               (out_lines >= max_chunk_lines or out_bytes + sep_bytes + line_bytes > max_chunk_bytes) do
            {[flush_acc(out_acc)], [], 0, 0}
          else
            {[], out_acc, out_lines, out_bytes}
          end

        new_sep = if out_lines == 0, do: 0, else: 1
        new_out_acc = [formatted | out_acc]
        new_out_lines = out_lines + 1
        new_out_bytes = out_bytes + new_sep + line_bytes

        # Check if we should flush after adding
        {post_emitted, new_out_acc, new_out_lines, new_out_bytes} =
          if new_out_lines >= max_chunk_lines or new_out_bytes >= max_chunk_bytes do
            {[flush_acc(new_out_acc)], [], 0, 0}
          else
            {[], new_out_acc, new_out_lines, new_out_bytes}
          end

        # Recurse to consume the rest
        {rest_emitted, final_pending, final_ln, final_acc, final_ol, final_ob, final_enl} =
          consume_text(rest, line_num + 1, new_out_acc, new_out_lines, new_out_bytes, max_chunk_lines, max_chunk_bytes)

        ended_nl = if byte_size(rest) == 0, do: true, else: final_enl

        {pre_emitted ++ post_emitted ++ rest_emitted, final_pending, final_ln, final_acc, final_ol, final_ob, ended_nl}
    end
  end

  defp flush_acc([]), do: nil
  defp flush_acc(acc), do: acc |> Enum.reverse() |> Enum.join("\n")

  @doc """
  Format a mismatch error message with context lines.

  Shows grep-style output with `>>>` markers on mismatched lines,
  showing the correct `LINE#ID` so the caller can fix all refs at once.
  """
  @spec format_mismatch_message([hash_mismatch()], [String.t()]) :: String.t()
  def format_mismatch_message(mismatches, file_lines) do
    mismatch_map =
      mismatches
      |> Enum.map(fn m -> {m.line, m} end)
      |> Map.new()

    # Collect line ranges to display (mismatch lines + context)
    display_lines =
      mismatches
      |> Enum.flat_map(fn m ->
        lo = max(1, m.line - @mismatch_context)
        hi = min(length(file_lines), m.line + @mismatch_context)
        Enum.to_list(lo..hi)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    lines = [
      "#{length(mismatches)} line#{if length(mismatches) > 1, do: "s have", else: " has"} changed since last read. Line references may have changed. Use the updated LINE#ID references shown below (>>> marks changed lines).",
      ""
    ]

    {lines_with_context_rev, _} =
      display_lines
      |> Enum.reduce({[], nil}, fn line_num, {acc, prev_line} ->
        # Gap separator between non-contiguous regions
        acc =
          if prev_line != nil and line_num > prev_line + 1 do
            ["    ..." | acc]
          else
            acc
          end

        content = Enum.at(file_lines, line_num - 1)
        hash = compute_line_hash(content)
        prefix = "#{line_num}##{hash}"

        line =
          if Map.has_key?(mismatch_map, line_num) do
            ">>> #{prefix}:#{content}"
          else
            "    #{prefix}:#{content}"
          end

        {[line | acc], line_num}
      end)

    lines_with_context = Enum.reverse(lines_with_context_rev)

    Enum.join(lines ++ lines_with_context, "\n")
  end
end

defmodule CodingAgent.Tools.Hashline.HashlineMismatchError do
  @moduledoc """
  Error raised when one or more hashline references have stale hashes.

  Displays grep-style output with `>>>` markers on mismatched lines,
  showing the correct `LINE#ID` so the caller can fix all refs at once.
  """

  alias CodingAgent.Tools.Hashline

  defexception [:message, :mismatches, :file_lines, :remaps]

  @type t :: %__MODULE__{
          message: String.t(),
          mismatches: [Hashline.hash_mismatch()],
          file_lines: [String.t()],
          remaps: %{String.t() => String.t()}
        }

  @impl true
  def exception(opts) do
    mismatches = Keyword.fetch!(opts, :mismatches)
    file_lines = Keyword.fetch!(opts, :file_lines)

    # Build remap dictionary
    remaps =
      mismatches
      |> Enum.map(fn m ->
        actual = Hashline.compute_line_hash(Enum.at(file_lines, m.line - 1))
        {"#{m.line}##{m.expected}", "#{m.line}##{actual}"}
      end)
      |> Map.new()

    message = Hashline.format_mismatch_message(mismatches, file_lines)

    %__MODULE__{
      message: message,
      mismatches: mismatches,
      file_lines: file_lines,
      remaps: remaps
    }
  end
end
