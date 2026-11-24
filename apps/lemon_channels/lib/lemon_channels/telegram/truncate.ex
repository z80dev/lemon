defmodule LemonChannels.Telegram.Truncate do
  @moduledoc """
  Truncation and splitting logic for Telegram messages.

  Telegram rejects a message whose text exceeds 4096 UTF-16 code units, and the
  rejection is terminal. Outbound text is Markdown source that
  `LemonChannels.Telegram.Formatter` renders into plain text plus entities just
  before sending (or sends verbatim when Markdown is disabled), so a message
  fits only when both its source and its rendered text are within the limit.
  Every size here is measured that way; rendering can grow text (table
  padding), so source length alone is not a bound.

  ## Splitting Algorithm

  1. If the text fits in one message, return it as-is.
  2. Otherwise split the Markdown source into blocks: fenced code blocks,
     tables (consecutive pipe rows, with their header and separator rows) and
     individual text lines.
  3. Pack whole blocks greedily into messages, breaking only between lines and
     never inside a code fence or table row.
  4. A block that cannot fit in a message of its own is divided: a code fence
     into several fences carrying the original opening line and a closing
     fence; a table into several tables that each repeat its header rows, so
     every message keeps aligned columns; a text line at the last whitespace
     that fits, else hard. Only a single line larger than a whole message is
     split inside a line.
  5. Resume lines go on the **last** message.

  `truncate_for_telegram/1` keeps status messages in one message, retaining
  trailing resume lines and an ellipsis when content is omitted.
  """

  alias LemonChannels.Telegram.Formatter
  alias LemonCore.ResumeToken

  @telegram_max_length 4096
  @ellipsis "..."

  @fence_open ~r/^(\s*)(`{3,}|~{3,})/
  @table_separator ~r/^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/

  @doc """
  Split text into one or more messages that each fit within Telegram's limit.

  Every returned message renders (and, unrendered, measures) to at most 4096
  UTF-16 code units. Code fences and table rows are never split while they can
  fit in a message; resume lines are preserved on the last message.

  ## Returns

  A non-empty list of strings.
  """
  @spec split_messages(String.t() | nil) :: [String.t()]
  def split_messages(text) when is_binary(text) do
    if fits?(text), do: [text], else: do_split(text)
  end

  def split_messages(text), do: [to_string(text)]

  @doc """
  Truncate text to fit within Telegram's message limit while preserving resume lines.

  Resume lines at the end of the message are preserved even if truncation is
  needed; omitted content is marked with an ellipsis.

  ## Returns

  The (possibly truncated) text, which renders to at most 4096 UTF-16 code units.

  ## Examples

      iex> short_text = "Hello world"
      iex> Truncate.truncate_for_telegram(short_text)
      "Hello world"

      iex> long_text = String.duplicate("x", 5000) <> "\\nlemon resume abc123"
      iex> result = Truncate.truncate_for_telegram(long_text)
      iex> String.length(result) <= 4096
      true
      iex> String.ends_with?(result, "lemon resume abc123")
      true

  """
  @spec truncate_for_telegram(String.t()) :: String.t()
  def truncate_for_telegram(text) when is_binary(text) do
    if fits?(text), do: text, else: do_truncate(text)
  end

  def truncate_for_telegram(text), do: text

  @doc """
  Returns the Telegram message length limit, in UTF-16 code units.
  """
  @spec max_length() :: pos_integer()
  def max_length, do: @telegram_max_length

  # A message fits when both its Markdown source (sent verbatim when Markdown
  # is off or renders empty) and its rendered text are within the limit. The
  # source is checked first, so oversized text is never rendered.
  defp fits?(text) do
    within_limit?(text) and
      text |> Formatter.prepare_for_telegram() |> elem(0) |> within_limit?()
  end

  defp within_limit?(text),
    do: bounded_utf16_length(text, @telegram_max_length) <= @telegram_max_length

  # -- splitting ---------------------------------------------------------------

  defp do_split(text) do
    {content, resume_lines} = extract_resume(text)

    content
    |> pack(&fits?/1, :infinity)
    |> append_resume(Enum.join(resume_lines, "\n"))
    |> case do
      [] -> [""]
      chunks -> chunks
    end
  end

  defp append_resume(chunks, ""), do: chunks
  defp append_resume([], resume), do: pack(resume, &fits?/1, :infinity)

  defp append_resume(chunks, resume) do
    {init, [last]} = Enum.split(chunks, -1)
    combined = last <> "\n" <> resume

    if fits?(combined),
      do: init ++ [combined],
      else: chunks ++ pack(resume, &fits?/1, :infinity)
  end

  defp do_truncate(text) do
    {content, resume_lines} = extract_resume(text)

    tail =
      case resume_lines do
        [] -> @ellipsis
        _ -> @ellipsis <> "\n" <> Enum.join(resume_lines, "\n")
      end

    if fits?(tail) do
      first_with_tail(content, tail)
    else
      # Resume lines alone exceed the limit: truncate everything plainly.
      first_with_tail(text, @ellipsis)
    end
  end

  defp first_with_tail(content, tail) do
    case pack(content, &fits?(with_tail(&1, tail)), 1) do
      [first | _] -> with_tail(first, tail)
      [] -> String.trim_leading(tail)
    end
  end

  # A tail after a closing fence or a table row goes on its own line so the
  # block stays intact.
  defp with_tail("", tail), do: tail

  defp with_tail(chunk, tail) do
    last_line = chunk |> String.split("\n") |> List.last()

    if Regex.match?(@fence_open, last_line) or table_line?(last_line),
      do: chunk <> "\n" <> tail,
      else: chunk <> tail
  end

  # Packs `content` into at most `limit` messages, each accepted by `fits`.
  defp pack(content, fits, limit) do
    content
    |> String.split("\n")
    |> parse_blocks([])
    |> pack_units(fits, limit, [])
  end

  defp pack_units([], _fits, _limit, acc), do: Enum.reverse(acc)
  defp pack_units(_units, _fits, limit, acc) when length(acc) == limit, do: Enum.reverse(acc)

  defp pack_units(units, fits, limit, acc) do
    cap = source_cap(units, &unit_source/1)

    case max_prefix(cap, &fits.(units_chunk(Enum.take(units, &1)))) do
      0 ->
        [unit | rest] = units
        pack_units(split_unit(unit, fits) ++ rest, fits, limit, acc)

      count ->
        {taken, rest} = Enum.split(units, count)

        acc =
          case units_chunk(taken) do
            "" -> acc
            chunk -> [chunk | acc]
          end

        pack_units(rest, fits, limit, acc)
    end
  end

  defp units_chunk(units) do
    units
    |> Enum.map_join("\n", &unit_source/1)
    |> String.trim_leading("\n")
    |> String.trim_trailing()
  end

  defp unit_source({:line, line}), do: line
  defp unit_source({:piece, piece}), do: piece

  defp unit_source({:fence, open, body, close}),
    do: Enum.join([open | body] ++ List.wrap(close), "\n")

  defp unit_source({:table, header, rows}), do: Enum.join(header ++ rows, "\n")

  # Divides a unit too large for one message: returns the units that replace
  # it, the first being a `{:piece, _}` that fits on its own and the rest the
  # unsplit remainder (split lazily, so truncation stops after one message).
  defp split_unit({kind, line}, fits) when kind in [:line, :piece] do
    case first_part(line, fits, true) do
      {first, ""} -> [{:piece, first}]
      {first, rest} -> [{:piece, first}, {:line, rest}]
      # Not even one code point fits beside a truncation tail: drop the line.
      :error -> []
    end
  end

  defp split_unit({:fence, open, body, close} = fence, fits) do
    close = close || fence_close(open)
    wrap = fn lines -> Enum.join([open | lines] ++ [close], "\n") end
    rest_fence = fn rest -> if rest == [], do: [], else: [{:fence, open, rest, close}] end

    case {max_prefix(source_cap(body, & &1), &fits.(wrap.(Enum.take(body, &1)))), body} do
      {0, [line | rest]} ->
        # One code line larger than a message: split the line, keep the fence.
        case first_part(line, &fits.(wrap.([&1])), false) do
          {first, ""} -> [{:piece, wrap.([first])} | rest_fence.(rest)]
          {first, left} -> [{:piece, wrap.([first])} | rest_fence.([left | rest])]
          :error -> as_lines(fence)
        end

      {0, []} ->
        as_lines(fence)

      {count, _} ->
        {taken, rest} = Enum.split(body, count)
        [{:piece, wrap.(taken)} | rest_fence.(rest)]
    end
  end

  defp split_unit({:table, header, rows} = table, fits) do
    wrap = fn lines -> Enum.join(header ++ lines, "\n") end
    rest_table = fn rest -> if rest == [], do: [], else: [{:table, header, rest}] end

    if rows == [] or (header != [] and not fits.(wrap.([]))) do
      as_lines(table)
    else
      case max_prefix(source_cap(rows, & &1), &fits.(wrap.(Enum.take(rows, &1)))) do
        # A single row larger than a message: only that row loses its table
        # shape; the remaining rows keep the header.
        0 ->
          [{:line, hd(rows)} | rest_table.(tl(rows))]

        count ->
          rows
          |> Enum.split(count)
          |> then(fn {taken, rest} -> [{:piece, wrap.(taken)} | rest_table.(rest)] end)
      end
    end
  end

  defp as_lines(unit), do: unit |> unit_source() |> String.split("\n") |> Enum.map(&{:line, &1})

  # The longest leading part of `string` accepted by `fits`, preferring the last
  # whitespace when `words?`, and the remainder. `:error` when not even one
  # code point fits.
  defp first_part("", _fits, _words?), do: :error

  defp first_part(string, fits, words?) do
    # A fitting part has at most @telegram_max_length graphemes, so only that
    # window is examined however long the line is.
    window = String.slice(string, 0, @telegram_max_length)
    graphemes = String.graphemes(window)

    case max_prefix(source_cap(graphemes, & &1, 0), &fits.(Enum.join(Enum.take(graphemes, &1)))) do
      0 ->
        # One grapheme larger than a message: fall back to code points.
        codepoints = graphemes |> hd() |> String.codepoints()

        case max_prefix(
               source_cap(codepoints, & &1, 0),
               &fits.(Enum.join(Enum.take(codepoints, &1)))
             ) do
          0 -> :error
          count -> split_after(string, Enum.join(Enum.take(codepoints, count)), false)
        end

      count when count == length(graphemes) and window == string ->
        {string, ""}

      count ->
        taken = graphemes |> Enum.take(word_break(graphemes, count, words?)) |> Enum.join()
        split_after(string, taken, words?)
    end
  end

  defp split_after(string, taken, trim?) do
    size = byte_size(taken)
    rest = binary_part(string, size, byte_size(string) - size)
    {taken, if(trim?, do: String.trim_leading(rest), else: rest)}
  end

  defp word_break(_graphemes, count, false), do: count

  defp word_break(graphemes, count, true) do
    graphemes
    |> Enum.take(count)
    |> Enum.with_index()
    |> Enum.reduce(count, fn {grapheme, index}, best ->
      if index > 0 and whitespace?(grapheme), do: index, else: best
    end)
  end

  defp whitespace?(grapheme), do: String.trim(grapheme) == ""

  # Largest n in 0..cap accepted by `probe`, by binary search (rendered size
  # grows with n in practice); 0 when none. Rendering is not strictly
  # monotone, so a result of 0 is rechecked against n = 1 to guarantee
  # progress whenever a single item fits.
  defp max_prefix(0, _probe), do: 0

  defp max_prefix(cap, probe) do
    cond do
      probe.(cap) -> cap
      (found = bsearch(0, cap - 1, probe)) > 0 -> found
      probe.(1) -> 1
      true -> 0
    end
  end

  defp bsearch(low, high, _probe) when low >= high, do: low

  defp bsearch(low, high, probe) do
    mid = div(low + high + 1, 2)
    if probe.(mid), do: bsearch(mid, high, probe), else: bsearch(low, mid - 1, probe)
  end

  # How many leading items can fit by source length alone (joined with a
  # one-unit separator). The source must fit too, so this bounds every search
  # and keeps each probe at most one message long.
  defp source_cap(items, to_source, separator \\ 1) do
    items
    |> Enum.reduce_while({0, -separator}, fn item, {count, size} ->
      budget = @telegram_max_length - size - separator
      size = size + separator + bounded_utf16_length(to_source.(item), budget)

      if size <= @telegram_max_length,
        do: {:cont, {count + 1, size}},
        else: {:halt, {count, size}}
    end)
    |> elem(0)
  end

  # UTF-16 length of `text`, or `budget + 1` once it exceeds `budget`, so a
  # long remainder is never scanned past one message.
  defp bounded_utf16_length(text, budget), do: bounded_utf16_length(text, budget, 0)

  defp bounded_utf16_length(_text, budget, acc) when acc > budget, do: budget + 1
  defp bounded_utf16_length(<<>>, _budget, acc), do: acc

  defp bounded_utf16_length(<<codepoint::utf8, rest::binary>>, budget, acc),
    do: bounded_utf16_length(rest, budget, acc + if(codepoint > 0xFFFF, do: 2, else: 1))

  # Invalid UTF-8 bytes are counted as one unit each rather than raising.
  defp bounded_utf16_length(<<_byte, rest::binary>>, budget, acc),
    do: bounded_utf16_length(rest, budget, acc + 1)

  # -- Markdown blocks -----------------------------------------------------------

  defp parse_blocks([], acc), do: Enum.reverse(acc)

  defp parse_blocks([line | rest] = lines, acc) do
    cond do
      match = Regex.run(@fence_open, line) ->
        [_, _indent, marker] = match
        {body, close, rest} = take_fence(rest, marker, [])
        parse_blocks(rest, [{:fence, line, body, close} | acc])

      table_start?(line, rest) ->
        {table, rest} = Enum.split_while(lines, &table_line?/1)

        {header, rows} =
          case table do
            [_header, separator | _] ->
              if separator?(separator), do: Enum.split(table, 2), else: {[], table}

            _ ->
              {[], table}
          end

        parse_blocks(rest, [{:table, header, rows} | acc])

      true ->
        parse_blocks(rest, [{:line, line} | acc])
    end
  end

  defp take_fence([], _marker, body), do: {Enum.reverse(body), nil, []}

  defp take_fence([line | rest], marker, body) do
    if fence_close?(line, marker),
      do: {Enum.reverse(body), line, rest},
      else: take_fence(rest, marker, [line | body])
  end

  defp fence_close?(line, marker) do
    trimmed = String.trim(line)
    char = String.first(marker)

    String.length(trimmed) >= String.length(marker) and
      trimmed == String.duplicate(char, String.length(trimmed))
  end

  defp fence_close(open) do
    [_, indent, marker] = Regex.run(@fence_open, open)
    indent <> marker
  end

  defp table_start?(line, [next | _]),
    do: table_line?(line) and (pipe_row?(line) or separator?(next))

  defp table_start?(line, []), do: table_line?(line) and pipe_row?(line)

  defp pipe_row?(line), do: String.starts_with?(String.trim_leading(line), "|")

  defp table_line?(line), do: String.trim(line) != "" and String.contains?(line, "|")
  defp separator?(line), do: String.contains?(line, "-") and Regex.match?(@table_separator, line)

  # -- resume lines -------------------------------------------------------------

  # Extract resume lines from the end of text, returning {remaining_content, resume_lines}
  defp extract_resume(text) do
    lines = String.split(text, "\n")
    {content_lines, resume_lines} = split_trailing_resume_lines(lines)

    case resume_lines do
      [] ->
        case extract_trailing_resume_line(text) do
          nil ->
            {text, []}

          resume_line ->
            {strip_trailing_line(text, resume_line), [resume_line]}
        end

      _ ->
        {Enum.join(content_lines, "\n"), resume_lines}
    end
  end

  # Split lines into content and trailing resume lines
  defp split_trailing_resume_lines(lines) do
    {resume_rev, content_rev} = split_resume_lines(Enum.reverse(lines), [])
    {Enum.reverse(content_rev), resume_rev}
  end

  defp split_resume_lines([], resume_acc), do: {resume_acc, []}

  defp split_resume_lines([line | rest], resume_acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" && resume_acc != [] ->
        split_resume_lines(rest, [line | resume_acc])

      resume_line?(line) ->
        split_resume_lines(rest, [line | resume_acc])

      true ->
        {resume_acc, [line | rest]}
    end
  end

  # Top-level channel resumes are native-only. Delegated vendor resume metadata
  # must not be pinned into outbound conversation text.
  defp resume_line?(line) when is_binary(line) do
    line
    |> String.trim()
    |> ResumeToken.is_resume_line("lemon")
  end

  # `resume_line` is the *trimmed* last line, so the text has to lose its
  # trailing whitespace before the suffix matches — otherwise the line stays in
  # the content and is re-appended, and the reader sees it twice.
  defp strip_trailing_line(text, resume_line) do
    text
    |> String.trim_trailing()
    |> String.replace_suffix(resume_line, "")
    |> String.trim_trailing("\n")
  end

  defp extract_trailing_resume_line(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> case do
      [last | _] -> if resume_line?(last), do: String.trim(last), else: nil
      [] -> nil
    end
  end
end
