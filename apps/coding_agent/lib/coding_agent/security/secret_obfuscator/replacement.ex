defmodule CodingAgent.Security.SecretObfuscator.Replacement do
  @moduledoc false
  # One-way replacements for `mode: replace` secrets. A default replacement is
  # deterministic and same-length, and for regex entries it must not be matched
  # again by the same regex in place (otherwise a later pass would re-redact it
  # or oscillate back toward the original value).

  import Bitwise

  @replacement_chars ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
  @nonmatching_chars @replacement_chars ++ ~c"!#$%&()*+,-./:;<=>?@[]^_{|}~"
  @whitespace_chars ~c" \t"
  @golden 0x9E3779B97F4A7C15
  @rematch_backscan 512

  @doc "Deterministic same-length replacement, prefixed with the fixed `Z`/`ZZ` sentinel."
  @spec deterministic(String.t()) :: String.t()
  def deterministic(""), do: ""

  def deterministic(secret) do
    len = text_length(secret)
    <<hash::unsigned-big-64, _::binary>> = :crypto.hash(:sha256, secret)
    prefix = if len == 1, do: ~c"Z", else: ~c"ZZ"

    {chars, _} =
      Enum.reduce(length(prefix)..(len - 1)//1, {Enum.reverse(prefix), hash}, fn i, {acc, h} ->
        h = bxor(h, (i + 1) * @golden)
        {[Enum.at(@replacement_chars, rem(h, 62)) | acc], h}
      end)

    chars |> Enum.reverse() |> List.to_string()
  end

  @doc "Force a whole configured value's replacement to differ from the value itself."
  @spec ensure_distinct(String.t(), String.t()) :: String.t()
  def ensure_distinct(replacement, secret) when replacement != secret or replacement == "",
    do: replacement

  def ensure_distinct(<<"A", rest::binary>>, _secret), do: "B" <> rest
  def ensure_distinct(<<_, rest::binary>>, _secret), do: "A" <> rest

  @doc "Key-derived run of replacement chars that depends only on key and length."
  @spec keyed_run(String.t(), non_neg_integer()) :: String.t()
  def keyed_run(_key, length) when length <= 0, do: ""

  def keyed_run(key, length) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.flat_map(fn block ->
      :crypto.mac(:hmac, :sha256, key, "replace-chunk\0#{length}\0#{block}")
      |> :binary.bin_to_list()
      |> Enum.map(&Enum.at(@replacement_chars, rem(&1, 62)))
    end)
    |> Enum.take(length)
    |> List.to_string()
  end

  @doc """
  Replacement for a default replace-mode regex match at byte span
  `start..start+len` of `text`. `key_fun` resolves the placeholder key for the
  pathological match-everything fallback.
  """
  @spec for_regex_match(String.t(), Regex.t(), String.t(), non_neg_integer(), (-> String.t())) ::
          String.t()
  def for_regex_match(value, regex, text, start, key_fun) do
    candidate = deterministic(value)
    ctx = {text, start, start + byte_size(value)}

    if candidate == value or rematches_in_context?(candidate, regex, ctx) do
      find_non_matching(value, regex, ctx) || keyed_fallback(value, key_fun)
    else
      candidate
    end
  end

  defp keyed_fallback(value, key_fun) do
    case text_length(value) do
      len when len <= 2 -> keyed_run(key_fun.(), len)
      len -> "ZZ" <> keyed_run(key_fun.(), len - 2)
    end
  end

  @doc """
  Whether a default replace regex can never redact a 1–2 char match to a value it
  does not match again. Such entries are rejected at load time.
  """
  @spec unresolvable_short_match?(Regex.t()) :: boolean()
  def unresolvable_short_match?(regex) do
    Enum.any?([1, 2], fn len ->
      probe = String.duplicate(<<0>>, len)
      find_non_matching(probe, regex, {probe, 0, len}) == nil
    end)
  end

  # Bounded search over same-length candidates the regex does not match in place:
  # single-position substitutions against an `AAAA…` baseline, then full-width
  # runs of one char, then whitespace markers.
  defp find_non_matching(value, regex, ctx) do
    len = text_length(value)
    baseline = List.duplicate(hd(@nonmatching_chars), len)

    substitute = fn position, ch ->
      baseline |> List.replace_at(position, ch) |> List.to_string()
    end

    single_position =
      Stream.flat_map(0..(len - 1)//1, fn position ->
        Stream.map(@nonmatching_chars, &substitute.(position, &1))
      end)

    full_width = Stream.map(@nonmatching_chars, &String.duplicate(<<&1>>, len))

    whitespace =
      Stream.flat_map(@whitespace_chars, fn ws ->
        Stream.concat(
          [String.duplicate(<<ws>>, len)],
          Stream.map(0..(len - 1)//1, &substitute.(&1, ws))
        )
      end)

    Stream.concat([single_position, full_width, whitespace])
    |> Enum.find(fn candidate ->
      candidate != value and not rematches_in_context?(candidate, regex, ctx)
    end)
  end

  # Substitute `candidate` for the span in the full text and check whether any
  # match overlaps it. Lookbehind/lookahead evaluate against the full context.
  defp rematches_in_context?(candidate, regex, {text, start, stop}) do
    probe =
      binary_part(text, 0, start) <> candidate <> binary_part(text, stop, byte_size(text) - stop)

    span_end = start + byte_size(candidate)
    scan_overlap?(regex, probe, max(0, start - @rematch_backscan), start, span_end)
  end

  defp scan_overlap?(regex, probe, offset, start, span_end) when offset <= byte_size(probe) do
    case Regex.run(regex, probe, offset: offset, return: :index) do
      [{ms, _ml} | _] when ms >= span_end -> false
      [{ms, ml} | _] when ms + ml > start -> true
      [{ms, 0} | _] -> scan_overlap?(regex, probe, ms + 1, start, span_end)
      [{ms, ml} | _] -> scan_overlap?(regex, probe, ms + ml, start, span_end)
      _ -> false
    end
  end

  defp scan_overlap?(_regex, _probe, _offset, _start, _span_end), do: false

  @doc "Character length for valid UTF-8, byte length otherwise."
  def text_length(text) do
    if String.valid?(text), do: String.length(text), else: byte_size(text)
  end
end
