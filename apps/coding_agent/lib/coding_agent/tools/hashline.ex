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

  @typedoc "Any hashline edit operation"
  @type edit :: set_edit() | replace_edit() | append_edit() | prepend_edit() | insert_edit()

  @typedoc "Result of applying edits"
  @type apply_result :: %{
          content: String.t(),
          first_changed_line: pos_integer() | nil,
          noop_edits: [map()] | nil
        }

  @typedoc "Hash mismatch information"
  @type hash_mismatch :: %{line: pos_integer(), expected: String.t(), actual: String.t()}

  # Number of context lines shown above/below each mismatched line
  @mismatch_context 2

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
      {:ok, %{content: content, first_changed_line: nil, noop_edits: nil}}
    else
      file_lines = String.split(content, "\n")
      original_file_lines = file_lines

      with :ok <- validate_all_edits(edits, file_lines) do
        edits = deduplicate_edits(edits, file_lines)
        sorted_edits = sort_edits(edits, file_lines)

        {result_lines, first_changed, noop_edits} =
          apply_sorted_edits(sorted_edits, file_lines, original_file_lines, nil, [])

        result = %{
          content: Enum.join(result_lines, "\n"),
          first_changed_line: first_changed,
          noop_edits: if(Enum.empty?(noop_edits), do: nil, else: Enum.reverse(noop_edits))
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
  defp deduplicate_edits(edits, file_lines) do
    {deduped, _} =
      edits
      |> Enum.reduce({[], %{}}, fn edit, {acc, seen} ->
        key = edit_key(edit, file_lines)
        content_key = edit_content_key(edit)
        full_key = "#{key}:#{content_key}"

        if Map.has_key?(seen, full_key) do
          {acc, seen}
        else
          {[edit | acc], Map.put(seen, full_key, true)}
        end
      end)

    Enum.reverse(deduped)
  end

  defp edit_key(%{op: :set, tag: tag}, _file_lines), do: "s:#{tag.line}"

  defp edit_key(%{op: :replace, first: first, last: last}, _file_lines),
    do: "r:#{first.line}:#{last.line}"

  defp edit_key(%{op: :append, after: nil}, _file_lines), do: "ieof"
  defp edit_key(%{op: :append, after: tag}, _file_lines), do: "i:#{tag.line}"

  defp edit_key(%{op: :prepend, before: nil}, _file_lines), do: "ibef"
  defp edit_key(%{op: :prepend, before: tag}, _file_lines), do: "ib:#{tag.line}"

  defp edit_key(%{op: :insert, after: after_tag, before: before_tag}, _file_lines),
    do: "ix:#{after_tag.line}:#{before_tag.line}"

  defp edit_content_key(%{content: content}), do: Enum.join(content, "\n")

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

  # Apply sorted edits to file lines
  defp apply_sorted_edits([], file_lines, _original_lines, first_changed, noop_edits),
    do: {file_lines, first_changed, noop_edits}

  defp apply_sorted_edits([edit | rest], file_lines, original_lines, first_changed, noop_edits) do
    {new_lines, new_first, new_noop} =
      apply_single_edit(edit, file_lines, original_lines, first_changed, noop_edits)

    apply_sorted_edits(rest, new_lines, original_lines, new_first, new_noop)
  end

  defp apply_single_edit(%{op: :set, tag: tag, content: content}, file_lines, original_lines, first_changed, noop_edits) do
    orig_lines = [Enum.at(original_lines, tag.line - 1)]

    if lines_equal?(orig_lines, content) do
      noop = %{
        edit_index: tag.line,
        loc: "#{tag.line}##{tag.hash}",
        current_content: Enum.join(orig_lines, "\n")
      }

      {file_lines, first_changed, [noop | noop_edits]}
    else
      new_lines = List.replace_at(file_lines, tag.line - 1, hd(content))
      {new_lines, min_line(first_changed, tag.line), noop_edits}
    end
  end

  defp apply_single_edit(%{op: :replace, first: first, last: last, content: content}, file_lines, original_lines, first_changed, noop_edits) do
    count = last.line - first.line + 1
    orig_lines = Enum.slice(original_lines, first.line - 1, count)

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

  defp apply_single_edit(%{op: :append, after: nil, content: content}, file_lines, _original_lines, first_changed, noop_edits) do
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

  defp apply_single_edit(%{op: :append, after: tag, content: content}, file_lines, original_lines, first_changed, noop_edits) do
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

  defp apply_single_edit(%{op: :prepend, before: nil, content: content}, file_lines, _original_lines, first_changed, noop_edits) do
    # Prepend at BOF
    if length(file_lines) == 1 and hd(file_lines) == "" do
      {content, min_line(first_changed, 1), noop_edits}
    else
      new_lines = content ++ file_lines
      {new_lines, min_line(first_changed, 1), noop_edits}
    end
  end

  defp apply_single_edit(%{op: :prepend, before: tag, content: content}, file_lines, original_lines, first_changed, noop_edits) do
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

  defp apply_single_edit(%{op: :insert, after: after_tag, before: before_tag, content: content}, file_lines, original_lines, first_changed, noop_edits) do
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
      "#{length(mismatches)} line#{if length(mismatches) > 1, do: "s have", else: " has"} changed since last read. Use the updated LINE#ID references shown below (>>> marks changed lines).",
      ""
    ]

    {lines_with_context, _} =
      display_lines
      |> Enum.reduce({[], nil}, fn line_num, {acc, prev_line} ->
        # Gap separator between non-contiguous regions
        acc =
          if prev_line != nil and line_num > prev_line + 1 do
            acc ++ ["    ..."]
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

        {acc ++ [line], line_num}
      end)

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
