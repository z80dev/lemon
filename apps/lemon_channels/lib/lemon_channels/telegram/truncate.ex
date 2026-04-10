defmodule LemonChannels.Telegram.Truncate do
  @moduledoc """
  Truncation and splitting logic for Telegram messages.

  Telegram has a message length limit of 4096 characters. When a message
  exceeds this limit, we split it into multiple messages with smart
  break-point selection.

  ## Splitting Algorithm

  1. If text fits in one message, return it as-is
  2. If we need to split:
     - Find the first newline (`\\n`) within 80% of the limit
     - If no newline, find a word boundary (space) within the last 5% of the limit
     - If no word boundary, hard-split at 99% of the limit
  3. Preserve resume lines on the **last** chunk

  ## Legacy Truncation

  `truncate_for_telegram/1` still exists for simple truncation use-cases
  such as status messages. New outbound text flows should prefer
  `split_messages/1`.
  """

  @telegram_max_length 4096

  # Split thresholds as percentages of max_length
  @newline_target_pct 0.80
  @word_search_start_pct 0.95
  @hard_split_pct 0.99

  @doc """
  Split text into one or more chunks that each fit within Telegram's message limit.

  Uses smart break-point selection: prefers newlines within 80% of the limit,
  falls back to word boundaries, and finally hard-splits.

  Resume lines are preserved on the last chunk.

  ## Returns

  A non-empty list of strings, each with `String.length/1 <= 4096`.
  """
  @spec split_messages(String.t()) :: [String.t()]
  def split_messages(text) when is_binary(text) do
    if String.length(text) <= @telegram_max_length do
      [text]
    else
      do_split(text)
    end
  end

  def split_messages(text), do: [to_string(text)]

  defp do_split(text) do
    # Extract resume lines — they go on the last chunk only
    {content, resume_lines} = extract_resume(text)
    resume_text = Enum.join(resume_lines, "\n")

    chunks = split_content_loop(content, [])
    # Trim trailing empty chunks that can arise from trailing newlines
    chunks = trim_trailing_empty(chunks)

    # Append resume lines to the last chunk
    chunks = append_resume_to_last(chunks, resume_text)

    # Safety: if any chunk still exceeds the limit (resume lines too long),
    # fall back to hard truncation per chunk
    Enum.map(chunks, &hard_truncate/1)
  end

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
            content = text |> String.replace_suffix(resume_line, "") |> String.trim_trailing("\n")

            {content, [resume_line]}
        end

      _ ->
        {Enum.join(content_lines, "\n"), resume_lines}
    end
  end

  defp split_content_loop("", acc), do: Enum.reverse(acc)

  defp split_content_loop(remaining, acc) do
    if String.length(remaining) <= @telegram_max_length do
      Enum.reverse([remaining | acc])
    else
      limit = @telegram_max_length

      # Strategy 1: find a newline within 80% of the limit
      newline_target = trunc(limit * @newline_target_pct)

      case find_break_before(remaining, newline_target, "\n") do
        pos when is_integer(pos) and pos > 0 ->
          {chunk, rest} = String.split_at(remaining, pos + 1)
          split_content_loop(rest, [String.trim_trailing(chunk) | acc])

        nil ->
          # Strategy 2: find a space within the last 5% (95%-100% of limit)
          word_search_start = trunc(limit * @word_search_start_pct)

          case find_break_before(remaining, limit, " ", word_search_start) do
            pos when is_integer(pos) and pos > 0 ->
              {chunk, rest} = String.split_at(remaining, pos + 1)
              split_content_loop(rest, [chunk | acc])

            nil ->
              # Strategy 3: hard split at 99% of limit
              hard_pos = trunc(limit * @hard_split_pct)
              hard_pos = min(hard_pos, String.length(remaining))
              {chunk, rest} = String.split_at(remaining, hard_pos)
              split_content_loop(rest, [chunk | acc])
          end
      end
    end
  end

  # Find the last occurrence of `separator` in text[0..max_pos], scanning backward.
  # Returns the **grapheme** position of the separator, or nil.
  #
  # NOTE: `:binary.matches/2` returns byte offsets, so we convert to grapheme
  # offsets to be safe with multibyte characters (emoji, CJK, etc.).
  defp find_break_before(text, max_pos, separator) do
    find_break_before(text, max_pos, separator, 0)
  end

  defp find_break_before(text, max_pos, separator, min_pos) do
    # Take prefix up to max_pos (grapheme-safe via String.slice)
    prefix = String.slice(text, 0, min(max_pos, String.length(text)))

    # Use :binary.matches to find the last occurrence (byte offsets)
    case :binary.matches(prefix, separator) do
      [] ->
        nil

      matches ->
        # matches are sorted ascending by byte offset; take the last one
        {byte_pos, _len} = List.last(matches)

        # Convert byte offset to grapheme index
        # grapheme_index = number of graphemes before byte_pos
        grapheme_pos = count_graphemes_before(prefix, byte_pos)

        if grapheme_pos >= min_pos, do: grapheme_pos, else: nil
    end
  end

  # Count the number of graphemes in binary before the given byte offset.
  # This is the grapheme index corresponding to that byte position.
  defp count_graphemes_before(binary, byte_pos) do
    prefix = binary_part(binary, 0, byte_pos)
    String.length(prefix)
  end

  defp trim_trailing_empty(chunks) do
    chunks
    |> Enum.reverse()
    |> Enum.drop_while(fn chunk -> chunk == "" end)
    |> Enum.reverse()
    |> case do
      [] -> [""]
      non_empty -> non_empty
    end
  end

  defp append_resume_to_last([], _resume_text), do: []
  defp append_resume_to_last(chunks, ""), do: chunks

  defp append_resume_to_last(chunks, resume_text) do
    {init, [last]} = Enum.split(chunks, -1)

    # If last chunk + resume exceeds limit, hard-truncate the content
    combined = last <> "\n" <> resume_text

    if String.length(combined) <= @telegram_max_length do
      init ++ [combined]
    else
      # Truncate content to make room for resume
      available = @telegram_max_length - String.length(resume_text) - 1

      truncated_last =
        if available > 0 do
          String.slice(last, 0, available)
        else
          ""
        end

      init ++ [truncated_last <> "\n" <> resume_text]
    end
  end

  defp hard_truncate(text) do
    if String.length(text) <= @telegram_max_length do
      text
    else
      String.slice(text, 0, @telegram_max_length)
    end
  end

  # ---------------------------------------------------------------------------
  # Legacy truncation API (preserved for backward-compat)
  # ---------------------------------------------------------------------------

  @ellipsis "..."

  @doc """
  Truncate text to fit within Telegram's message limit while preserving resume lines.

  Resume lines at the end of the message are preserved even if truncation is needed.

  ## Returns

  The (possibly truncated) text that fits within Telegram's 4096 character limit.

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
    if String.length(text) <= @telegram_max_length do
      text
    else
      do_truncate(text)
    end
  end

  def truncate_for_telegram(text), do: text

  defp do_truncate(text) do
    lines = String.split(text, "\n")
    {content_lines, resume_lines} = split_trailing_resume_lines(lines)

    {content_lines, resume_lines} =
      case resume_lines do
        [] ->
          case extract_trailing_resume_line(text) do
            nil ->
              {content_lines, resume_lines}

            resume_line ->
              content_text =
                text
                |> String.replace_suffix(resume_line, "")
                |> String.trim_trailing("\n")

              content_lines =
                case content_text do
                  "" -> []
                  _ -> String.split(content_text, "\n")
                end

              {content_lines, [resume_line]}
          end

        _ ->
          {content_lines, resume_lines}
      end

    # Calculate space budget
    resume_text = Enum.join(resume_lines, "\n")
    resume_length = String.length(resume_text)

    # Reserve space for: ellipsis + newline (if we have content) + resume lines
    ellipsis_with_sep = @ellipsis <> if(resume_lines != [], do: "\n", else: "")
    ellipsis_len = String.length(ellipsis_with_sep)

    # Space available for content
    available_for_content = @telegram_max_length - resume_length - ellipsis_len

    # If resume lines alone exceed the limit, truncate them too
    if available_for_content < 0 do
      truncate_plain(text)
    else
      truncated_content = truncate_content(content_lines, available_for_content)

      cond do
        # Content fits without truncation
        truncated_content == Enum.join(content_lines, "\n") && resume_lines == [] ->
          text

        truncated_content == Enum.join(content_lines, "\n") ->
          # No content truncation needed, just rebuild
          if resume_lines == [] do
            truncated_content
          else
            truncated_content <> "\n" <> resume_text
          end

        resume_lines == [] ->
          # Truncated, no resume lines
          truncated_content <> @ellipsis

        true ->
          # Truncated with resume lines
          truncated_content <> @ellipsis <> "\n" <> resume_text
      end
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

  defp resume_line?(line) when is_binary(line) do
    line = String.trim(String.downcase(line))

    String.starts_with?(line, "codex resume ") ||
      String.starts_with?(line, "lemon resume ") ||
      String.starts_with?(line, "claude --resume ") ||
      Regex.match?(~r/^[a-z0-9_-]+\s+resume\s+/i, line)
  end

  defp extract_trailing_resume_line(text) when is_binary(text) do
    regex =
      ~r/(?:^|\n)(`?(?:codex|lemon)\s+resume\s+[a-zA-Z0-9_-]+`?|`?claude\s+--resume\s+[a-zA-Z0-9_-]+`?)\s*$/i

    case Regex.run(regex, text) do
      [_, line] -> line
      _ -> nil
    end
  end

  # Truncate content lines to fit within the budget
  defp truncate_content([], _budget), do: ""

  defp truncate_content(lines, budget) do
    full_content = Enum.join(lines, "\n")

    if String.length(full_content) <= budget do
      full_content
    else
      # Binary search for the right amount of content
      truncate_to_length(full_content, budget)
    end
  end

  # Truncate a string to fit within a character budget, trying to break at word boundaries
  defp truncate_to_length(_text, budget) when budget <= 0, do: ""

  defp truncate_to_length(text, budget) do
    if String.length(text) <= budget do
      text
    else
      # Take up to budget characters
      truncated = String.slice(text, 0, budget)

      # Try to find a good break point (newline or space)
      case find_break_point(truncated) do
        nil ->
          # No good break point, just use the hard cutoff
          truncated

        pos ->
          String.slice(truncated, 0, pos)
      end
    end
  end

  # Find the last newline or space in the string for a cleaner break
  defp find_break_point(text) do
    len = String.length(text)

    # Only look in the last 100 characters for a break point
    search_start = max(0, len - 100)
    search_text = String.slice(text, search_start, len - search_start)

    # Prefer newline, then space
    case :binary.match(String.reverse(search_text), "\n") do
      {pos, _} ->
        search_start + String.length(search_text) - pos - 1

      :nomatch ->
        case :binary.match(String.reverse(search_text), " ") do
          {pos, _} ->
            search_start + String.length(search_text) - pos - 1

          :nomatch ->
            nil
        end
    end
  end

  # Plain truncation without resume line preservation
  defp truncate_plain(text) do
    budget = @telegram_max_length - String.length(@ellipsis)
    truncate_to_length(text, budget) <> @ellipsis
  end

  @doc """
  Returns the Telegram message length limit.
  """
  @spec max_length() :: pos_integer()
  def max_length, do: @telegram_max_length
end
