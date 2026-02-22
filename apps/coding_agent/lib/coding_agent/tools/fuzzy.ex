defmodule CodingAgent.Tools.Fuzzy do
  @moduledoc """
  Fuzzy matching utilities for the edit tool.

  Provides both character-level and line-level fuzzy matching with progressive
  fallback strategies for finding text in files.

  Ported from Oh-My-Pi's fuzzy.ts
  """

  # ═══════════════════════════════════════════════════════════════════════════
  # Constants
  # ═══════════════════════════════════════════════════════════════════════════

  @default_fuzzy_threshold 0.95
  @sequence_fuzzy_threshold 0.92
  @fallback_threshold 0.8
  @context_fuzzy_threshold 0.8
  @partial_match_min_length 6
  @partial_match_min_ratio 0.3
  @occurrence_preview_context 5
  @occurrence_preview_max_len 80

  @typedoc "Fuzzy match result with location and confidence"
  @type fuzzy_match :: %{
          actual_text: String.t(),
          start_index: non_neg_integer(),
          start_line: pos_integer(),
          confidence: float()
        }

  @typedoc "Match outcome from find_match"
  @type match_outcome :: %{
          optional(:match) => fuzzy_match(),
          optional(:closest) => fuzzy_match(),
          optional(:occurrences) => pos_integer(),
          optional(:occurrence_lines) => [pos_integer()],
          optional(:occurrence_previews) => [String.t()],
          optional(:fuzzy_matches) => pos_integer(),
          optional(:dominant_fuzzy) => boolean()
        }

  @typedoc "Sequence search result"
  @type sequence_search_result :: %{
          optional(:index) => non_neg_integer(),
          optional(:strategy) => String.t(),
          optional(:match_count) => pos_integer(),
          optional(:match_indices) => [non_neg_integer()],
          confidence: float()
        }

  @typedoc "Context line search result"
  @type context_line_result :: %{
          optional(:index) => non_neg_integer(),
          optional(:strategy) => String.t(),
          optional(:match_count) => pos_integer(),
          optional(:match_indices) => [non_neg_integer()],
          confidence: float()
        }

  # ═══════════════════════════════════════════════════════════════════════════
  # Core Algorithms
  # ═══════════════════════════════════════════════════════════════════════════

  @doc """
  Compute Levenshtein distance between two strings.

  ## Examples

      iex> Fuzzy.levenshtein_distance("kitten", "sitting")
      3

      iex> Fuzzy.levenshtein_distance("hello", "hello")
      0
  """
  @spec levenshtein_distance(String.t(), String.t()) :: non_neg_integer()
  def levenshtein_distance(a, b) when a == b, do: 0

  def levenshtein_distance(a, b) do
    a_len = String.length(a)
    b_len = String.length(b)

    cond do
      a_len == 0 -> b_len
      b_len == 0 -> a_len
      true -> do_levenshtein(a, b, a_len, b_len)
    end
  end

  defp do_levenshtein(a, b, a_len, b_len) do
    a_chars = String.to_charlist(a)
    b_chars = String.to_charlist(b)

    prev = Enum.to_list(0..b_len)
    curr = List.duplicate(0, b_len + 1)

    {prev, _} =
      Enum.reduce(1..a_len, {prev, curr}, fn i, {prev_row, curr_row} ->
        curr_row = List.replace_at(curr_row, 0, i)
        a_code = Enum.at(a_chars, i - 1)

        curr_row =
          Enum.reduce(1..b_len, curr_row, fn j, row ->
            b_code = Enum.at(b_chars, j - 1)
            cost = if a_code == b_code, do: 0, else: 1

            deletion = Enum.at(prev_row, j) + 1
            insertion = Enum.at(row, j - 1) + 1
            substitution = Enum.at(prev_row, j - 1) + cost

            List.replace_at(row, j, min(deletion, min(insertion, substitution)))
          end)

        {curr_row, prev_row}
      end)

    Enum.at(prev, b_len)
  end

  @doc """
  Compute similarity score between two strings (0 to 1).

  ## Examples

      iex> Fuzzy.similarity("hello", "hallo")
      0.8

      iex> Fuzzy.similarity("same", "same")
      1.0
  """
  @spec similarity(String.t(), String.t()) :: float()
  def similarity(a, b) do
    a_len = String.length(a)
    b_len = String.length(b)

    cond do
      a_len == 0 and b_len == 0 -> 1.0
      max(a_len, b_len) == 0 -> 1.0
      true ->
        distance = levenshtein_distance(a, b)
        1.0 - distance / max(a_len, b_len)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Normalization
  # ═══════════════════════════════════════════════════════════════════════════

  @doc """
  Normalize text for fuzzy matching by:
  - Converting to lowercase
  - Normalizing unicode
  - Removing extra whitespace
  """
  @spec normalize_for_fuzzy(String.t()) :: String.t()
  def normalize_for_fuzzy(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[^\x00-\x7F]/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @doc """
  Count leading whitespace characters in a string.
  """
  @spec count_leading_whitespace(String.t()) :: non_neg_integer()
  def count_leading_whitespace(line) do
    case Regex.run(~r/^\s*/, line) do
      [match] -> String.length(match)
      _ -> 0
    end
  end

  @doc """
  Normalize unicode punctuation.
  """
  @spec normalize_unicode(String.t()) :: String.t()
  def normalize_unicode(text) do
    text
    # Smart quotes to ASCII
    |> String.replace("'", "'")
    |> String.replace("'", "'")
    |> String.replace("\"", "\"")
    |> String.replace("\"", "\"")
    # Dashes to hyphen
    |> String.replace("—", "-")
    |> String.replace("–", "-")
    # Then normalize remaining unicode
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[^\x00-\x7F]/u, "")
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Line-Based Utilities
  # ═══════════════════════════════════════════════════════════════════════════

  @doc """
  Compute relative indent depths for lines.
  Returns a list of indent levels (0 = minimum indent).
  """
  @spec compute_relative_indent_depths([String.t()]) :: [non_neg_integer()]
  def compute_relative_indent_depths(lines) do
    indents = Enum.map(lines, &count_leading_whitespace/1)

    non_empty_indents =
      lines
      |> Enum.zip(indents)
      |> Enum.filter(fn {line, _} -> String.trim(line) != "" end)
      |> Enum.map(fn {_, indent} -> indent end)

    min_indent = if non_empty_indents == [], do: 0, else: Enum.min(non_empty_indents)

    indent_steps =
      non_empty_indents
      |> Enum.map(&(&1 - min_indent))
      |> Enum.filter(&(&1 > 0))

    indent_unit = if indent_steps == [], do: 1, else: Enum.min(indent_steps)

    Enum.map(Enum.zip(lines, indents), fn {line, indent} ->
      if String.trim(line) == "" do
        0
      else
        round((indent - min_indent) / indent_unit)
      end
    end)
  end

  @doc """
  Normalize lines for matching, optionally including indent depth.
  """
  @spec normalize_lines([String.t()], boolean()) :: [String.t()]
  def normalize_lines(lines, include_depth \\ true) do
    indent_depths = if include_depth, do: compute_relative_indent_depths(lines), else: nil

    Enum.map(Enum.with_index(lines), fn {line, index} ->
      trimmed = String.trim(line)
      prefix = if indent_depths, do: "#{Enum.at(indent_depths, index)}|", else: "|"
      if trimmed == "", do: prefix, else: "#{prefix}#{normalize_for_fuzzy(trimmed)}"
    end)
  end

  @doc """
  Compute character offsets for each line in content.
  """
  @spec compute_line_offsets([String.t()]) :: [non_neg_integer()]
  def compute_line_offsets(lines) do
    {offsets, _} =
      Enum.reduce(lines, {[], 0}, fn line, {acc, offset} ->
        {[offset | acc], offset + String.length(line) + 1}
      end)

    Enum.reverse(offsets)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Character-Level Fuzzy Match
  # ═══════════════════════════════════════════════════════════════════════════

  @doc """
  Find a match for target text within content.
  Used primarily for replace-mode edits.

  ## Options
    - `:allow_fuzzy` - Whether to allow fuzzy matching (default: true)
    - `:threshold` - Minimum similarity threshold (default: 0.95)

  ## Returns
    - `%{match: fuzzy_match}` - Unique match found
    - `%{occurrences: n, occurrence_lines: [...], occurrence_previews: [...]}` - Multiple exact matches
    - `%{closest: fuzzy_match, fuzzy_matches: n}` - Best fuzzy match(es)
    - `%{}` - No match found
  """
  @spec find_match(String.t(), String.t(), keyword()) :: match_outcome()
  def find_match(content, target, opts \\ [])
  def find_match(_content, "", _opts), do: %{}

  def find_match(content, target, opts) do
    allow_fuzzy = Keyword.get(opts, :allow_fuzzy, true)
    threshold = Keyword.get(opts, :threshold, @default_fuzzy_threshold)

    # Try exact match first
    case :binary.match(content, target) do
      :nomatch ->
        try_fuzzy_match(content, target, allow_fuzzy, threshold)

      {_index, _length} ->
        occurrences = count_occurrences(content, target)

        if occurrences > 1 do
          build_occurrence_result(content, target, occurrences)
        else
          index = :binary.match(content, target) |> elem(0)
          start_line = content |> String.slice(0, index) |> String.split("\n") |> length()

          %{
            match: %{
              actual_text: target,
              start_index: index,
              start_line: start_line,
              confidence: 1.0
            }
          }
        end
    end
  end

  defp count_occurrences(content, target) do
    content
    |> String.split(target)
    |> length()
    |> Kernel.-(1)
  end

  defp build_occurrence_result(content, target, occurrences) do
    content_lines = String.split(content, "\n")

    {lines, previews} =
      Enum.reduce(0..min(occurrences - 1, 4), {[], []}, fn i, {lines_acc, previews_acc} ->
        search_start = if i == 0, do: 0, else: find_nth_occurrence(content, target, i) + 1
        idx = :binary.match(String.slice(content, search_start, byte_size(content) - search_start), target)

        if idx == :nomatch do
          {lines_acc, previews_acc}
        else
          {found_index, _} = idx
          actual_index = search_start + found_index
          line_number = content |> String.slice(0, actual_index) |> String.split("\n") |> length()

          start_line = max(0, line_number - 1 - @occurrence_preview_context)
          end_line = min(length(content_lines), line_number + @occurrence_preview_context)

          preview_lines = Enum.slice(content_lines, start_line, end_line - start_line)

          preview =
            preview_lines
            |> Enum.with_index()
            |> Enum.map(fn {line, idx} ->
              num = start_line + idx + 1
              display = if String.length(line) > @occurrence_preview_max_len,
                do: String.slice(line, 0, @occurrence_preview_max_len - 1) <> "…",
                else: line
              "  #{num} | #{display}"
            end)
            |> Enum.join("\n")

          {[line_number | lines_acc], [preview | previews_acc]}
        end
      end)

    %{
      occurrences: occurrences,
      occurrence_lines: Enum.reverse(lines),
      occurrence_previews: Enum.reverse(previews)
    }
  end

  defp find_nth_occurrence(content, target, n) do
    Enum.reduce(0..n-1, 0, fn _, acc ->
      case :binary.match(String.slice(content, acc, byte_size(content) - acc), target) do
        :nomatch -> acc
        {idx, len} -> acc + idx + len
      end
    end)
  end

  defp try_fuzzy_match(_content, _target, false, _threshold), do: %{}

  defp try_fuzzy_match(content, target, true, threshold) do
    content_lines = String.split(content, "\n")
    target_lines = String.split(target, "\n")

    if length(target_lines) > length(content_lines) do
      %{}
    else
      do_fuzzy_match(content, content_lines, target_lines, threshold)
    end
  end

  defp do_fuzzy_match(_content, content_lines, target_lines, threshold) do
    offsets = compute_line_offsets(content_lines)

    result = find_best_fuzzy_match_core(content_lines, target_lines, offsets, threshold, true)

    # Retry without indent depth if match is close but below threshold
    result =
      if result.best && result.best.confidence < threshold && result.best.confidence >= @fallback_threshold do
        no_depth_result = find_best_fuzzy_match_core(content_lines, target_lines, offsets, threshold, false)

        if no_depth_result.best && no_depth_result.best.confidence > result.best.confidence do
          no_depth_result
        else
          result
        end
      else
        result
      end

    cond do
      !result.best ->
        %{}

      result.best.confidence >= threshold && result.above_threshold_count == 1 ->
        %{match: result.best, closest: result.best}

      result.best.confidence >= threshold && result.above_threshold_count > 1 ->
        dominant_delta = 0.08
        dominant_min = 0.97

        if result.best.confidence >= dominant_min &&
             result.best.confidence - result.second_best_score >= dominant_delta do
          %{
            match: result.best,
            closest: result.best,
            fuzzy_matches: result.above_threshold_count,
            dominant_fuzzy: true
          }
        else
          %{closest: result.best, fuzzy_matches: result.above_threshold_count}
        end

      true ->
        %{closest: result.best, fuzzy_matches: result.above_threshold_count}
    end
  end

  defp find_best_fuzzy_match_core(content_lines, target_lines, offsets, threshold, include_depth) do
    target_normalized = normalize_lines(target_lines, include_depth)

    max_start = length(content_lines) - length(target_lines)

    Enum.reduce(0..max_start, %{best: nil, best_score: -1, second_best_score: -1, above_threshold_count: 0}, fn start, acc ->
      window_lines = Enum.slice(content_lines, start, length(target_lines))
      window_normalized = normalize_lines(window_lines, include_depth)

      score =
        Enum.zip(target_normalized, window_normalized)
        |> Enum.map(fn {t, w} -> similarity(t, w) end)
        |> Enum.sum()
        |> Kernel./(length(target_lines))

      above_threshold_count = if score >= threshold, do: acc.above_threshold_count + 1, else: acc.above_threshold_count

      cond do
        score > acc.best_score ->
          best = %{
            actual_text: Enum.join(window_lines, "\n"),
            start_index: Enum.at(offsets, start),
            start_line: start + 1,
            confidence: score
          }

          %{acc | best: best, best_score: score, second_best_score: acc.best_score, above_threshold_count: above_threshold_count}

        score > acc.second_best_score ->
          %{acc | second_best_score: score, above_threshold_count: above_threshold_count}

        true ->
          %{acc | above_threshold_count: above_threshold_count}
      end
    end)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Line-Based Sequence Match
  # ═══════════════════════════════════════════════════════════════════════════

  @doc """
  Find a sequence of pattern lines within content lines.

  Attempts matches with decreasing strictness:
  1. Exact match
  2. Trailing whitespace ignored
  3. All whitespace trimmed
  4. Comment-prefix normalized
  5. Unicode punctuation normalized
  6. Prefix match (pattern is prefix of line)
  7. Substring match (pattern is substring of line)
  8. Fuzzy similarity match
  9. Character-based fuzzy matching

  ## Options
    - `:allow_fuzzy` - Whether to allow fuzzy matching (default: true)
    - `:eof` - If true, prefer matching at end of file first (default: false)

  ## Returns
    `%{index: line_index, confidence: score, strategy: "exact" | "trim" | ...}`
    or `%{index: nil, confidence: 0}` if no match found
  """
  @spec seek_sequence([String.t()], [String.t()], non_neg_integer(), keyword()) :: sequence_search_result()
  def seek_sequence(lines, pattern, start \\ 0, opts \\ []) do
    allow_fuzzy = Keyword.get(opts, :allow_fuzzy, true)
    eof = Keyword.get(opts, :eof, false)

    # Empty pattern matches immediately
    if pattern == [] do
      %{index: start, confidence: 1.0, strategy: "exact"}
    else
      do_seek_sequence(lines, pattern, start, eof, allow_fuzzy)
    end
  end

  defp do_seek_sequence(lines, pattern, start, eof, allow_fuzzy) do
    if length(pattern) > length(lines) do
      %{index: nil, confidence: 0}
    else
      max_start = length(lines) - length(pattern)
      search_start = if eof && length(lines) >= length(pattern), do: max_start, else: start

      # Run exact passes
      case run_exact_passes(lines, pattern, search_start, max_start, allow_fuzzy) do
        nil ->
          if eof && search_start > start do
            case run_exact_passes(lines, pattern, start, max_start, allow_fuzzy) do
              nil -> try_fuzzy_sequence_match(lines, pattern, start, search_start, eof, allow_fuzzy)
              result -> result
            end
          else
            try_fuzzy_sequence_match(lines, pattern, start, search_start, eof, allow_fuzzy)
          end

        result ->
          result
      end
    end
  end

  defp run_exact_passes(lines, pattern, from, to, allow_fuzzy) do
    # Pass 1: Exact match
    result =
      Enum.find_value(from..to, fn i ->
        if matches_at?(lines, pattern, i, &(&1 == &2)), do: %{index: i, confidence: 1.0, strategy: "exact"}
      end)

    if result, do: result, else: run_trim_passes(lines, pattern, from, to, allow_fuzzy)
  end

  defp run_trim_passes(lines, pattern, from, to, allow_fuzzy) do
    # Pass 2: Trailing whitespace stripped
    result =
      Enum.find_value(from..to, fn i ->
        if matches_at?(lines, pattern, i, &(String.trim_trailing(&1) == String.trim_trailing(&2))),
          do: %{index: i, confidence: 0.99, strategy: "trim-trailing"}
      end)

    if result, do: result, else: run_trim_all_pass(lines, pattern, from, to, allow_fuzzy)
  end

  defp run_trim_all_pass(lines, pattern, from, to, allow_fuzzy) do
    # Pass 3: Both leading and trailing whitespace stripped
    result =
      Enum.find_value(from..to, fn i ->
        if matches_at?(lines, pattern, i, &(String.trim(&1) == String.trim(&2))),
          do: %{index: i, confidence: 0.98, strategy: "trim"}
      end)

    if result, do: result, else: run_comment_prefix_pass(lines, pattern, from, to, allow_fuzzy)
  end

  defp run_comment_prefix_pass(lines, pattern, from, to, allow_fuzzy) do
    # Pass 4: Comment-prefix normalized match
    result =
      Enum.find_value(from..to, fn i ->
        if matches_at?(lines, pattern, i, &(strip_comment_prefix(&1) == strip_comment_prefix(&2))),
          do: %{index: i, confidence: 0.975, strategy: "comment-prefix"}
      end)

    if result, do: result, else: run_unicode_pass(lines, pattern, from, to, allow_fuzzy)
  end

  defp run_unicode_pass(lines, pattern, from, to, allow_fuzzy) do
    # Pass 5: Normalize unicode punctuation
    result =
      Enum.find_value(from..to, fn i ->
        if matches_at?(lines, pattern, i, &(normalize_unicode(&1) == normalize_unicode(&2))),
          do: %{index: i, confidence: 0.97, strategy: "unicode"}
      end)

    if result || !allow_fuzzy, do: result, else: run_prefix_pass(lines, pattern, from, to)
  end

  defp run_prefix_pass(lines, pattern, from, to) do
    # Pass 6: Partial line prefix match
    matches =
      Enum.reduce(from..to, {nil, 0, []}, fn i, {first, count, indices} = acc ->
        if matches_at?(lines, pattern, i, &line_starts_with_pattern?/2) do
          new_first = first || i
          new_count = count + 1
          new_indices = if length(indices) < 5, do: [i | indices], else: indices
          {new_first, new_count, new_indices}
        else
          acc
        end
      end)

    case matches do
      {first, count, _} when count > 0 ->
        %{index: first, confidence: 0.965, match_count: count, match_indices: Enum.take(matches |> elem(2), 5), strategy: "prefix"}

      _ ->
        run_substring_pass(lines, pattern, from, to)
    end
  end

  defp run_substring_pass(lines, pattern, from, to) do
    # Pass 7: Partial line substring match
    matches =
      Enum.reduce(from..to, {nil, 0, []}, fn i, {first, count, indices} = acc ->
        if matches_at?(lines, pattern, i, &line_includes_pattern?/2) do
          new_first = first || i
          new_count = count + 1
          new_indices = if length(indices) < 5, do: [i | indices], else: indices
          {new_first, new_count, new_indices}
        else
          acc
        end
      end)

    case matches do
      {first, count, indices} when count > 0 ->
        %{index: first, confidence: 0.94, match_count: count, match_indices: Enum.reverse(indices), strategy: "substring"}

      _ ->
        nil
    end
  end

  defp try_fuzzy_sequence_match(lines, pattern, start, search_start, eof, allow_fuzzy) do
    if !allow_fuzzy do
      %{index: nil, confidence: 0}
    else
      do_fuzzy_sequence_match(lines, pattern, start, search_start, eof)
    end
  end

  defp do_fuzzy_sequence_match(lines, pattern, start, search_start, eof) do
    max_start = length(lines) - length(pattern)

    # Pass 8: Fuzzy matching
    result =
      Enum.reduce(search_start..max_start, %{best_index: nil, best_score: 0, second_best_score: 0, match_count: 0, match_indices: []}, fn i, acc ->
        score = fuzzy_score_at(lines, pattern, i)

        above_threshold = score >= @sequence_fuzzy_threshold
        new_count = if above_threshold, do: acc.match_count + 1, else: acc.match_count
        new_indices = if above_threshold && length(acc.match_indices) < 5, do: [i | acc.match_indices], else: acc.match_indices

        cond do
          score > acc.best_score ->
            %{acc | best_index: i, best_score: score, second_best_score: acc.best_score, match_count: new_count, match_indices: new_indices}

          score > acc.second_best_score ->
            %{acc | second_best_score: score, match_count: new_count, match_indices: new_indices}

          true ->
            %{acc | match_count: new_count, match_indices: new_indices}
        end
      end)

    # Also search from start if eof mode started from end
    result =
      if eof && search_start > start do
        Enum.reduce(start..(search_start - 1), result, fn i, acc ->
          score = fuzzy_score_at(lines, pattern, i)

          above_threshold = score >= @sequence_fuzzy_threshold
          new_count = if above_threshold, do: acc.match_count + 1, else: acc.match_count
          new_indices = if above_threshold && length(acc.match_indices) < 5, do: [i | acc.match_indices], else: acc.match_indices

          cond do
            score > acc.best_score ->
              %{acc | best_index: i, best_score: score, second_best_score: acc.best_score, match_count: new_count, match_indices: new_indices}

            score > acc.second_best_score ->
              %{acc | second_best_score: score, match_count: new_count, match_indices: new_indices}

            true ->
              %{acc | match_count: new_count, match_indices: new_indices}
          end
        end)
      else
        result
      end

    if result.best_index != nil && result.best_score >= @sequence_fuzzy_threshold do
      dominant_delta = 0.08
      dominant_min = 0.97

      if result.match_count > 1 && result.best_score >= dominant_min &&
           result.best_score - result.second_best_score >= dominant_delta do
        %{
          index: result.best_index,
          confidence: result.best_score,
          match_count: 1,
          match_indices: Enum.reverse(result.match_indices),
          strategy: "fuzzy-dominant"
        }
      else
        %{
          index: result.best_index,
          confidence: result.best_score,
          match_count: result.match_count,
          match_indices: Enum.reverse(result.match_indices),
          strategy: "fuzzy"
        }
      end
    else
      # Pass 9: Character-based fuzzy matching via find_match
      character_match_fallback(lines, pattern, start, result.best_score, result.match_count)
    end
  end

  defp character_match_fallback(lines, pattern, start, best_score, match_count) do
    pattern_text = Enum.join(pattern, "\n")
    content_text = lines |> Enum.drop(start) |> Enum.join("\n")

    case find_match(content_text, pattern_text, allow_fuzzy: true, threshold: 0.92) do
      %{match: match} ->
        matched_content = String.slice(content_text, 0, match.start_index)
        line_index = start + (matched_content |> String.split("\n") |> length()) - 1

        %{
          index: line_index,
          confidence: match.confidence,
          match_count: match_count || 1,
          strategy: "character"
        }

      _ ->
        %{index: nil, confidence: best_score, match_count: match_count}
    end
  end

  defp matches_at?(lines, pattern, i, compare_fn) do
    Enum.all?(Enum.with_index(pattern), fn {p, j} ->
      compare_fn.(Enum.at(lines, i + j), p)
    end)
  end

  defp line_starts_with_pattern?(line, pattern) do
    line_norm = normalize_for_fuzzy(line)
    pattern_norm = normalize_for_fuzzy(pattern)

    if pattern_norm == "", do: line_norm == "", else: String.starts_with?(line_norm, pattern_norm)
  end

  defp line_includes_pattern?(line, pattern) do
    line_norm = normalize_for_fuzzy(line)
    pattern_norm = normalize_for_fuzzy(pattern)

    cond do
      pattern_norm == "" -> line_norm == ""
      String.length(pattern_norm) < @partial_match_min_length -> false
      !String.contains?(line_norm, pattern_norm) -> false
      true -> String.length(pattern_norm) / max(1, String.length(line_norm)) >= @partial_match_min_ratio
    end
  end

  defp fuzzy_score_at(lines, pattern, i) do
    scores =
      Enum.map(Enum.with_index(pattern), fn {p, j} ->
        line_norm = normalize_for_fuzzy(Enum.at(lines, i + j))
        pattern_norm = normalize_for_fuzzy(p)
        similarity(line_norm, pattern_norm)
      end)

    Enum.sum(scores) / length(pattern)
  end

  defp strip_comment_prefix(line) do
    trimmed = String.trim_leading(line)

    cond do
      String.starts_with?(trimmed, "/*") -> String.trim_leading(String.slice(trimmed, 2..-1//1))
      String.starts_with?(trimmed, "*/") -> String.trim_leading(String.slice(trimmed, 2..-1//1))
      String.starts_with?(trimmed, "//") -> String.trim_leading(String.slice(trimmed, 2..-1//1))
      String.starts_with?(trimmed, "*") -> String.trim_leading(String.slice(trimmed, 1..-1//1))
      String.starts_with?(trimmed, "#") -> String.trim_leading(String.slice(trimmed, 1..-1//1))
      String.starts_with?(trimmed, ";") -> String.trim_leading(String.slice(trimmed, 1..-1//1))
      String.match?(trimmed, ~r/^\/\s/) -> String.trim_leading(String.slice(trimmed, 1..-1//1))
      true -> trimmed
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Context Line Search
  # ═══════════════════════════════════════════════════════════════════════════

  @doc """
  Find a context line in the file using progressive matching strategies.

  ## Options
    - `:allow_fuzzy` - Whether to allow fuzzy matching (default: true)
    - `:skip_function_fallback` - Skip function name fallback (default: false)

  ## Returns
    `%{index: line_index, confidence: score, strategy: "exact" | ...}`
    or `%{index: nil, confidence: 0}` if no match found
  """
  @spec find_context_line([String.t()], String.t(), non_neg_integer(), keyword()) :: context_line_result()
  def find_context_line(lines, context, start_from \\ 0, opts \\ []) do
    allow_fuzzy = Keyword.get(opts, :allow_fuzzy, true)
    skip_function_fallback = Keyword.get(opts, :skip_function_fallback, false)
    trimmed_context = String.trim(context)

    # Pass 1: Exact line match
    result =
      Enum.reduce(start_from..(length(lines) - 1), {nil, 0, []}, fn i, {first, count, indices} = acc ->
        if Enum.at(lines, i) == context do
          new_first = first || i
          new_count = count + 1
          new_indices = if length(indices) < 5, do: [i | indices], else: indices
          {new_first, new_count, new_indices}
        else
          acc
        end
      end)

    case result do
      {first, count, indices} when count > 0 ->
        %{index: first, confidence: 1.0, match_count: count, match_indices: Enum.reverse(indices), strategy: "exact"}

      _ ->
        find_context_line_trimmed(lines, trimmed_context, start_from, allow_fuzzy, skip_function_fallback)
    end
  end

  defp find_context_line_trimmed(lines, trimmed_context, start_from, allow_fuzzy, skip_function_fallback) do
    # Pass 2: Trimmed match
    result =
      Enum.reduce(start_from..(length(lines) - 1), {nil, 0, []}, fn i, {first, count, indices} = acc ->
        if String.trim(Enum.at(lines, i)) == trimmed_context do
          new_first = first || i
          new_count = count + 1
          new_indices = if length(indices) < 5, do: [i | indices], else: indices
          {new_first, new_count, new_indices}
        else
          acc
        end
      end)

    case result do
      {first, count, indices} when count > 0 ->
        %{index: first, confidence: 0.99, match_count: count, match_indices: Enum.reverse(indices), strategy: "trim"}

      _ ->
        find_context_line_unicode(lines, trimmed_context, start_from, allow_fuzzy, skip_function_fallback)
    end
  end

  defp find_context_line_unicode(lines, trimmed_context, start_from, allow_fuzzy, skip_function_fallback) do
    # Pass 3: Unicode normalization match
    normalized_context = normalize_unicode(trimmed_context)

    result =
      Enum.reduce(start_from..(length(lines) - 1), {nil, 0, []}, fn i, {first, count, indices} = acc ->
        if normalize_unicode(Enum.at(lines, i)) == normalized_context do
          new_first = first || i
          new_count = count + 1
          new_indices = if length(indices) < 5, do: [i | indices], else: indices
          {new_first, new_count, new_indices}
        else
          acc
        end
      end)

    case result do
      {first, count, indices} when count > 0 ->
        %{index: first, confidence: 0.98, match_count: count, match_indices: Enum.reverse(indices), strategy: "unicode"}

      _ ->
        if !allow_fuzzy do
          %{index: nil, confidence: 0}
        else
          find_context_line_prefix(lines, trimmed_context, start_from, skip_function_fallback)
        end
    end
  end

  defp find_context_line_prefix(lines, trimmed_context, start_from, skip_function_fallback) do
    # Pass 4: Prefix match
    context_norm = normalize_for_fuzzy(trimmed_context)

    if context_norm == "" do
      find_context_line_fuzzy(lines, trimmed_context, start_from, skip_function_fallback)
    else
      result =
        Enum.reduce(start_from..(length(lines) - 1), {nil, 0, []}, fn i, {first, count, indices} = acc ->
          line_norm = normalize_for_fuzzy(Enum.at(lines, i))

          if String.starts_with?(line_norm, context_norm) do
            new_first = first || i
            new_count = count + 1
            new_indices = if length(indices) < 5, do: [i | indices], else: indices
            {new_first, new_count, new_indices}
          else
            acc
          end
        end)

      case result do
        {first, count, indices} when count > 0 ->
          %{index: first, confidence: 0.96, match_count: count, match_indices: Enum.reverse(indices), strategy: "prefix"}

        _ ->
          find_context_line_substring(lines, trimmed_context, start_from, skip_function_fallback)
      end
    end
  end

  defp find_context_line_substring(lines, trimmed_context, start_from, skip_function_fallback) do
    # Pass 5: Substring match
    context_norm = normalize_for_fuzzy(trimmed_context)

    if String.length(context_norm) < @partial_match_min_length do
      find_context_line_fuzzy(lines, trimmed_context, start_from, skip_function_fallback)
    else
      all_matches =
        Enum.reduce(start_from..(length(lines) - 1), [], fn i, acc ->
          line_norm = normalize_for_fuzzy(Enum.at(lines, i))

          if String.contains?(line_norm, context_norm) do
            ratio = String.length(context_norm) / max(1, String.length(line_norm))
            [%{index: i, ratio: ratio} | acc]
          else
            acc
          end
        end)
        |> Enum.reverse()

      match_indices = all_matches |> Enum.take(5) |> Enum.map(& &1.index)

      cond do
        length(all_matches) == 1 ->
          %{index: hd(all_matches).index, confidence: 0.94, match_count: 1, match_indices: match_indices, strategy: "substring"}

        length(all_matches) > 1 ->
          # Filter by ratio to disambiguate
          filtered = Enum.filter(all_matches, &(&1.ratio >= @partial_match_min_ratio))

          if filtered != [] do
            %{index: hd(filtered).index, confidence: 0.94, match_count: length(filtered), match_indices: match_indices, strategy: "substring"}
          else
            %{index: hd(all_matches).index, confidence: 0.94, match_count: length(all_matches), match_indices: match_indices, strategy: "substring"}
          end

        true ->
          find_context_line_fuzzy(lines, trimmed_context, start_from, skip_function_fallback)
      end
    end
  end

  defp find_context_line_fuzzy(lines, trimmed_context, start_from, skip_function_fallback) do
    # Pass 6: Fuzzy match using similarity
    context_norm = normalize_for_fuzzy(trimmed_context)

    result =
      Enum.reduce(start_from..(length(lines) - 1), %{best_index: nil, best_score: 0, match_count: 0, match_indices: []}, fn i, acc ->
        line_norm = normalize_for_fuzzy(Enum.at(lines, i))
        score = similarity(line_norm, context_norm)

        above_threshold = score >= @context_fuzzy_threshold
        new_count = if above_threshold, do: acc.match_count + 1, else: acc.match_count
        new_indices = if above_threshold && length(acc.match_indices) < 5, do: [i | acc.match_indices], else: acc.match_indices

        if score > acc.best_score do
          %{acc | best_index: i, best_score: score, match_count: new_count, match_indices: new_indices}
        else
          %{acc | match_count: new_count, match_indices: new_indices}
        end
      end)

    cond do
      result.best_index != nil && result.best_score >= @context_fuzzy_threshold ->
        %{index: result.best_index, confidence: result.best_score, match_count: result.match_count, match_indices: Enum.reverse(result.match_indices), strategy: "fuzzy"}

      !skip_function_fallback && String.ends_with?(trimmed_context, "()") ->
        # Function fallback: try with and without parentheses
        with_paren = String.replace(trimmed_context, ~r/\(\)\s*$/, "(")
        without_paren = String.replace(trimmed_context, ~r/\(\)\s*$/, "")

        paren_result = find_context_line(lines, with_paren, start_from, allow_fuzzy: true, skip_function_fallback: true)

        if paren_result.index != nil || (paren_result.match_count || 0) > 0 do
          paren_result
        else
          find_context_line(lines, without_paren, start_from, allow_fuzzy: true, skip_function_fallback: true)
        end

      true ->
        %{index: nil, confidence: result.best_score}
    end
  end

  @doc """
  Find the closest sequence match without requiring a threshold.
  Returns the best match even if it's below the fuzzy threshold.
  """
  @spec find_closest_sequence_match([String.t()], [String.t()], keyword()) :: %{
          index: non_neg_integer() | nil,
          confidence: float(),
          strategy: String.t()
        }
  def find_closest_sequence_match(lines, pattern, opts \\ []) do
    start = Keyword.get(opts, :start, 0)
    eof = Keyword.get(opts, :eof, false)

    cond do
      pattern == [] ->
        %{index: start, confidence: 1.0, strategy: "exact"}

      length(pattern) > length(lines) ->
        %{index: nil, confidence: 0, strategy: "fuzzy"}

      true ->
        max_start = length(lines) - length(pattern)
        search_start = if eof && length(lines) >= length(pattern), do: max_start, else: start

        {best_index, best_score} =
          Enum.reduce(search_start..max_start, {nil, 0}, fn i, {best_idx, best_scr} ->
            score = fuzzy_score_at(lines, pattern, i)

            if score > best_scr do
              {i, score}
            else
              {best_idx, best_scr}
            end
          end)

        # Also search from start if eof mode
        {best_index, best_score} =
          if eof && search_start > start do
            Enum.reduce(start..(search_start - 1), {best_index, best_score}, fn i, {best_idx, best_scr} ->
              score = fuzzy_score_at(lines, pattern, i)

              if score > best_scr do
                {i, score}
              else
                {best_idx, best_scr}
              end
            end)
          else
            {best_index, best_score}
          end

        %{index: best_index, confidence: best_score, strategy: "fuzzy"}
    end
  end
end
