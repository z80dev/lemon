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

  - `replace` - Replace a single line or a range of lines
  - `append` - Insert after a line (or at EOF if pos is nil)
  - `prepend` - Insert before a line (or at BOF if pos is nil)

  ## Example Usage

      content = "Hello\\nWorld\\n"
      edits = [
        %{op: :replace, pos: %{line: 1, hash: compute_line_hash(1, "Hello")}, lines: ["Hi"]},
        %{op: :append, pos: %{line: 2, hash: compute_line_hash(2, "World")}, lines: ["!"]}
      ]
      {:ok, result} = apply_edits(content, edits)
  """

  alias CodingAgent.Tools.Hashline.HashlineMismatchError
  import Bitwise

  @typedoc "Line tag with line number and hash"
  @type line_tag :: %{line: pos_integer(), hash: String.t()}

  @typedoc "Replace operation - replace a single line or range of lines"
  @type replace_edit ::
          %{op: :replace, pos: line_tag(), lines: [String.t()]}
          | %{op: :replace, pos: line_tag(), end: line_tag(), lines: [String.t()]}

  @typedoc "Append operation - insert after a line (or at EOF if pos is nil)"
  @type append_edit :: %{op: :append, pos: line_tag() | nil, lines: [String.t()]}

  @typedoc "Prepend operation - insert before a line (or at BOF if pos is nil)"
  @type prepend_edit :: %{op: :prepend, pos: line_tag() | nil, lines: [String.t()]}

  @typedoc "Any hashline edit operation"
  @type edit :: replace_edit() | append_edit() | prepend_edit()

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

  @doc """
  Compute a short hexadecimal hash of a single line.

  Uses `:erlang.phash2/2` on a whitespace-normalized line, truncated to 2
  hex characters. The line input should not include a trailing newline.

  For lines with no significant characters (Unicode letters or numbers),
  the line number is mixed into the hash input to improve collision
  resistance for punctuation-only or empty lines.

  ## Examples

      iex> compute_line_hash(1, "hello world")
      "a1"  # actual hash will vary

      iex> compute_line_hash(1, "  hello  world  ")
      "a1"  # same hash after whitespace normalization
  """
  @spec compute_line_hash(pos_integer(), String.t()) :: String.t()
  def compute_line_hash(line_number, line) do
    normalized = normalize_line(line)

    hash_input =
      if has_significant_chars?(normalized) do
        normalized
      else
        "#{line_number}:#{normalized}"
      end

    hash_input
    |> :erlang.phash2(256)
    |> format_hash()
  end

  # Check if a string contains any Unicode letters or numbers
  defp has_significant_chars?(str) do
    Regex.match?(~r/[\p{L}\p{N}]/u, str)
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
    hash = compute_line_hash(line, content)
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
    actual_hash = compute_line_hash(line, actual_line)

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
      edits = [%{op: :replace, pos: %{line: 2, hash: "XX"}, lines: ["new line2"]}]
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

        {result_lines, first_changed, noop_edits} =
          apply_sorted_edits(sorted_edits, file_lines, original_file_lines, nil, [])

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
  # Replace single line
  defp validate_edit(%{op: :replace, pos: pos} = edit, file_lines) do
    case Map.get(edit, :end) do
      nil ->
        validate_edit_ref(pos, file_lines)

      end_tag ->
        if pos.line > end_tag.line do
          raise ArgumentError,
                "Range start line #{pos.line} must be <= end line #{end_tag.line}"
        end

        start_valid = validate_edit_ref(pos, file_lines)
        end_valid = validate_edit_ref(end_tag, file_lines)

        case {start_valid, end_valid} do
          {:ok, :ok} -> :ok
          {{:mismatch, m1}, {:mismatch, m2}} -> {:mismatch, m1 ++ m2}
          {:ok, {:mismatch, m}} -> {:mismatch, m}
          {{:mismatch, m}, :ok} -> {:mismatch, m}
        end
    end
  end

  defp validate_edit(%{op: :append, lines: lines, pos: pos}, file_lines) do
    if Enum.empty?(lines) do
      raise ArgumentError, "Append edit requires non-empty lines"
    end

    if pos do
      validate_edit_ref(pos, file_lines)
    else
      :ok
    end
  end

  defp validate_edit(%{op: :prepend, lines: lines, pos: pos}, file_lines) do
    if Enum.empty?(lines) do
      raise ArgumentError, "Prepend edit requires non-empty lines"
    end

    if pos do
      validate_edit_ref(pos, file_lines)
    else
      :ok
    end
  end

  defp validate_edit_ref(tag, file_lines) do
    if tag.line < 1 or tag.line > length(file_lines) do
      raise ArgumentError, "Line #{tag.line} does not exist (file has #{length(file_lines)} lines)"
    end

    actual_line = Enum.at(file_lines, tag.line - 1)
    actual_hash = compute_line_hash(tag.line, actual_line)

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

  defp edit_line_range(%{op: :replace, pos: pos} = edit) do
    case Map.get(edit, :end) do
      nil -> "#{pos.line}"
      end_tag -> "#{pos.line}-#{end_tag.line}"
    end
  end

  defp edit_line_range(%{op: :append, pos: nil}), do: "eof"
  defp edit_line_range(%{op: :append, pos: pos}), do: "#{pos.line}"
  defp edit_line_range(%{op: :prepend, pos: nil}), do: "bof"
  defp edit_line_range(%{op: :prepend, pos: pos}), do: "#{pos.line}"

  defp edit_content_hash(%{lines: lines}) do
    :erlang.phash2(lines)
    |> Integer.to_string(16)
  end

  @doc """
  Sort edits for bottom-up application.

  Returns edits sorted by their effective line position in descending order,
  so earlier splices don't invalidate later line numbers.
  """
  @spec sort_edits([edit()], [String.t()]) :: [edit()]
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

  defp edit_sort_key(%{op: :replace, pos: pos} = edit, _file_lines) do
    case Map.get(edit, :end) do
      nil -> {pos.line, 0}
      end_tag -> {end_tag.line, 0}
    end
  end

  defp edit_sort_key(%{op: :append, pos: nil}, file_lines),
    do: {length(file_lines) + 1, 1}

  defp edit_sort_key(%{op: :append, pos: pos}, _file_lines), do: {pos.line, 1}

  defp edit_sort_key(%{op: :prepend, pos: nil}, _file_lines), do: {0, 2}
  defp edit_sort_key(%{op: :prepend, pos: pos}, _file_lines), do: {pos.line, 2}

  # Apply sorted edits to file lines
  defp apply_sorted_edits([], file_lines, _original_lines, first_changed, noop_edits),
    do: {file_lines, first_changed, noop_edits}

  defp apply_sorted_edits([edit | rest], file_lines, original_lines, first_changed, noop_edits) do
    {new_lines, new_first, new_noop} =
      apply_single_edit(edit, file_lines, original_lines, first_changed, noop_edits)

    apply_sorted_edits(rest, new_lines, original_lines, new_first, new_noop)
  end

  # Replace single line
  defp apply_single_edit(%{op: :replace, pos: pos, lines: lines} = edit, file_lines, original_lines, first_changed, noop_edits)
       when not is_map_key(edit, :end) do
    orig_lines = [Enum.at(original_lines, pos.line - 1)]

    if lines_equal?(orig_lines, lines) do
      noop = %{
        edit_index: pos.line,
        loc: "#{pos.line}##{pos.hash}",
        current_content: Enum.join(orig_lines, "\n")
      }

      {file_lines, first_changed, [noop | noop_edits]}
    else
      idx = pos.line - 1

      new_lines =
        case lines do
          [] ->
            List.delete_at(file_lines, idx)

          [single_line] ->
            List.replace_at(file_lines, idx, single_line)

          _multiple_lines ->
            {before, after_parts} = Enum.split(file_lines, idx)
            {_removed, after_rest} = Enum.split(after_parts, 1)
            before ++ lines ++ after_rest
        end

      {new_lines, min_line(first_changed, pos.line), noop_edits}
    end
  end

  # Replace range
  defp apply_single_edit(%{op: :replace, pos: pos, end: end_tag, lines: lines}, file_lines, original_lines, first_changed, noop_edits) do
    count = end_tag.line - pos.line + 1
    orig_lines = Enum.slice(original_lines, pos.line - 1, count)

    if lines_equal?(orig_lines, lines) do
      noop = %{
        edit_index: pos.line,
        loc: "#{pos.line}##{pos.hash}",
        current_content: Enum.join(orig_lines, "\n")
      }

      {file_lines, first_changed, [noop | noop_edits]}
    else
      {before, after_parts} = Enum.split(file_lines, pos.line - 1)
      {_removed, after_rest} = Enum.split(after_parts, count)
      new_lines = before ++ lines ++ after_rest
      {new_lines, min_line(first_changed, pos.line), noop_edits}
    end
  end

  # Append at EOF
  defp apply_single_edit(%{op: :append, pos: nil, lines: lines}, file_lines, _original_lines, first_changed, noop_edits) do
    if length(file_lines) == 1 and hd(file_lines) == "" do
      # Empty file case
      {lines, min_line(first_changed, 1), noop_edits}
    else
      new_lines = file_lines ++ lines
      changed_line = length(file_lines) - length(lines) + 1
      {new_lines, min_line(first_changed, changed_line), noop_edits}
    end
  end

  # Append after a line
  defp apply_single_edit(%{op: :append, pos: pos, lines: lines}, file_lines, _original_lines, first_changed, noop_edits) do
    {before, rest} = Enum.split(file_lines, pos.line)
    new_lines = before ++ lines ++ rest
    {new_lines, min_line(first_changed, pos.line + 1), noop_edits}
  end

  # Prepend at BOF
  defp apply_single_edit(%{op: :prepend, pos: nil, lines: lines}, file_lines, _original_lines, first_changed, noop_edits) do
    if length(file_lines) == 1 and hd(file_lines) == "" do
      {lines, min_line(first_changed, 1), noop_edits}
    else
      new_lines = lines ++ file_lines
      {new_lines, min_line(first_changed, 1), noop_edits}
    end
  end

  # Prepend before a line
  defp apply_single_edit(%{op: :prepend, pos: pos, lines: lines}, file_lines, _original_lines, first_changed, noop_edits) do
    {before, rest} = Enum.split(file_lines, pos.line - 1)
    new_lines = before ++ lines ++ rest
    {new_lines, min_line(first_changed, pos.line), noop_edits}
  end

  defp lines_equal?(a, b) when length(a) != length(b), do: false

  defp lines_equal?(a, b) do
    Enum.zip(a, b)
    |> Enum.all?(fn {x, y} -> x == y end)
  end

  defp min_line(nil, b), do: b
  defp min_line(a, b) when a < b, do: a
  defp min_line(_a, b), do: b

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
        hash = compute_line_hash(line_num, content)
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
        actual = Hashline.compute_line_hash(m.line, Enum.at(file_lines, m.line - 1))
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
